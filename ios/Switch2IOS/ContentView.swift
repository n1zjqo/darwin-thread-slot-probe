import SwiftUI
import UniformTypeIdentifiers

@MainActor
struct ContentView: View {
    @EnvironmentObject private var session: SessionModel
    @State private var showsImporter = false
    @State private var selectedModule = ""
    @State private var modelBaseText = ""

    private func inventoryState(_ value: UInt32) -> String {
        value == 1 ? "已验证（限定范围）" : "不完整"
    }

    var body: some View {
        NavigationView {
            List {
                Section(header: Text("运行状态")) {
                    Label("尚不能运行游戏", systemImage: "exclamationmark.triangle")
                        .foregroundColor(.orange)
                    Text("此开发应用可检查已提取的输入文件，但不能运行任何 Switch 游戏。尚未接入 CPU 执行、图形、音频或游戏系统服务。")
                        .font(.footnote)
                    Text(session.isForeground ? "应用在前台" : "应用不在前台")
                        .font(.caption).foregroundColor(.secondary)
                }
                Section(header: Text("本地输入")) {
                    Text("请选择你有权使用的已提取 ExeFS 文件夹。文件只在本设备上读取，不复制到持久存储，不上传。不接受压缩包、加密游戏容器或密钥。")
                        .font(.footnote)
                    Button { showsImporter = true } label: { Label("选择已提取文件夹", systemImage: "folder") }
                        .disabled(session.isImporting || session.isValidating || session.isLoading)
                    if session.isImporting {
                        ProgressView("正在检查文件头…")
                        Button("取消检查") { session.cancelImport() }
                    }
                    if let error = session.errorMessage {
                        Text(error).foregroundColor(.red).accessibilityLabel("检查错误：\(error)")
                    }
                }
                if let inventory = session.inventory {
                    Section(header: Text("输入文件清单")) {
                        Text(inventory.folderName).font(.headline)
                        Text("main.npdm：\(inventory.hasNPDM ? "存在（未校验）" : "缺失")")
                        ForEach(inventory.modules) { module in
                            HStack {
                                Text(module.name)
                                Spacer()
                                Text(ByteCountFormatter.string(fromByteCount: module.byteCount, countStyle: .file))
                                    .foregroundColor(.secondary)
                            }
                        }
                        ForEach(inventory.warnings, id: \.self) { Text($0).font(.footnote).foregroundColor(.secondary) }
                        Button("清除清单", role: .destructive) { session.clear() }
                    }
                    Section(header: Text("持有模块并检查动态清单（不执行）")) {
                        Text("加载全部清单模块的三个解码段，并持有原生只读检查对象。报告依赖、符号与缺失元数据；不解析服务、不重定位、不启动游戏。")
                            .font(.footnote)
                        Text("单文件最多 64 MiB。全部驻留对象、当前输入及每模块 4 KiB 报告/管理预留合计最多 96 MiB；此预算不是进程总内存上限。关闭、清除、切换输入或进入后台会释放对象。")
                            .font(.caption).foregroundColor(.secondary)
                        if session.isLoading {
                            ProgressView("正在加载诊断对象…")
                            Text("取消会立即撤销结果；当前同步原生调用返回后释放资源。")
                                .font(.caption)
                            Button("取消加载") { session.cancelImport() }
                        } else {
                            Button("加载模块用于诊断") { session.loadForInspection() }
                                .disabled(session.isImporting || session.isValidating)
                        }
                        if let report = session.loadedInspection {
                            Label("诊断对象已持有；游戏仍不可运行", systemImage: "doc.text.magnifyingglass")
                            Text("原生请求内存 \(ByteCountFormatter.string(fromByteCount: Int64(report.ownedBytes), countStyle: .memory))；报告/管理预算预留 \(ByteCountFormatter.string(fromByteCount: Int64(report.reservedReportBytes), countStyle: .memory))")
                                .font(.caption)
                            ForEach(report.modules) { module in
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(module.name).font(.headline)
                                    Text("依赖 \(module.dependencyCount)；符号 \(module.symbolCount)；导入 \(module.importCount)；导出 \(module.exportCount)")
                                    Text("依赖清单：\(module.dependenciesComplete ? "已解析" : "不完整")；导入清单：\(module.importsComplete ? "已解析" : "不完整")；元数据警告标记：\(module.warnings)")
                                    Text("按文件标记验证 SHA-256：\(module.verifiedHashSegments)/3 段。清单完整也不证明链接兼容或游戏身份。")
                                }.font(.footnote)
                            }
                            Button("关闭诊断对象") { session.closeLoadedInspection() }
                        }
                    }
                    if session.loadedInspection != nil {
                        Section(header: Text("批量只读链接清单（不执行）")) {
                            Text("检查全部已持有模块的重定位记录、候选定义数量及格式状态。不输入基址、不选择提供者、不绑定符号、不写入重定位，也不调用初始化函数。")
                                .font(.footnote)
                            Text("每次检查替换旧链接报告；已持有布局模型保留并计入同一 96 MiB 预算。预算不足会拒绝，不会静默关闭模型。原生计划在报告复制后立即销毁。")
                                .font(.caption).foregroundColor(.secondary)
                            if session.isLinking {
                                ProgressView("正在生成只读链接清单…")
                                Text("取消会撤销结果；同步原生检查返回后释放计划。")
                                    .font(.caption)
                                Button("取消链接清单（保留源及模型）") { session.cancelLinkInventory() }
                            } else {
                                Button("检查全部模块的链接清单") { session.inspectBatchLinks() }
                            }
                            if let report = session.linkInspection {
                                Label("策略延后（POLICY DEFERRED）／不可执行", systemImage: "exclamationmark.triangle")
                                    .foregroundColor(.orange)
                                Text("格式：\(inventoryState(report.format))；目标范围：\(inventoryState(report.targets))；清单：\(inventoryState(report.inventory))。三项完整也不表示链接已解决。")
                                    .font(.footnote)
                                Text("模块 \(report.moduleCount)；重定位 \(report.relocationCount)；符号 \(report.symbolCount)；同名候选定义 \(report.candidateCount)。候选不等于可用或选中的提供者。")
                                    .font(.footnote)
                                ForEach(report.modules) { module in
                                    Text("模块序号 \(module.id)：RELA \(module.relaCount)，JMPREL \(module.jmprelCount)，符号 \(module.symbolCount)，依赖 \(module.dependencyCount)，未知标签 \(module.unknownTagCount)。格式 \(inventoryState(module.format))；目标 \(inventoryState(module.targets))；清单 \(inventoryState(module.inventory))；GNU 状态 \(module.gnuHash)；原始警告 \(module.originalWarnings)（未清除）。")
                                        .font(.caption)
                                }
                                Text("检查时合计请求峰值 \(report.creationPeakBytes) 字节；源模块 \(report.sourceModuleBytes)；其他驻留 \(report.otherLiveBytes)；计划 \(report.ownedBytes)；临时 \(report.temporaryBytes)；链接报告预留 \(report.reservedReportBytes)。计划和临时内存现已释放，仅保留数值报告。")
                                    .font(.caption)
                                Text("名称比较工作量 \(report.nameWork) 字节。预算是请求字节与报告预留，不是进程 RSS 上限；报告不认证输入或平台 ABI。")
                                    .font(.caption).foregroundColor(.secondary)
                                Button("关闭链接报告（保留源及模型）") { session.cancelLinkInventory() }
                            }
                        }
                    }
                    if let source = session.loadedInspection {
                        Section(header: Text("单模块布局模型（私有数据，不执行）")) {
                            Text("从已持有模块复制三个稀疏段、补零 BSS，并仅处理受支持的本地重定位。未知元数据、依赖及导入会拒绝；这不是完整链接器，也不会调用初始化函数。")
                                .font(.footnote)
                            Picker("源模块", selection: $selectedModule) {
                                Text("请选择模块").tag("")
                                ForEach(source.modules) { Text($0.name).tag($0.name) }
                            }.disabled(session.isPreparing)
                            TextField("虚拟基址：0x + 十六进制数", text: $modelBaseText)
                                .textInputAutocapitalization(.never).disableAutocorrection(true)
                                .disabled(session.isPreparing)
                            Text("必须显式填写并按 4096 字节对齐。此数仅是布局模型参数，不是真实游戏基址、主机地址或可调用入口。")
                                .font(.caption).foregroundColor(.secondary)
                            Text("每次准备先释放旧模型，源诊断对象保留；准备失败不会恢复旧模型。全部源对象、新模型、临时计划及报告预留（包括已持有链接报告）共享 96 MiB 预算，并非进程 RSS 上限。")
                                .font(.caption).foregroundColor(.secondary)
                            if session.isPreparing {
                                ProgressView("正在准备私有布局数据…")
                                Button("取消准备（保留源对象）") { session.cancelPreparation() }
                            } else {
                                Button("准备布局模型（替换旧模型）") {
                                    session.prepareSelectedModule(selectedModule, baseText: modelBaseText)
                                }.disabled(selectedModule.isEmpty)
                            }
                            if let report = session.preparedInspection {
                                Text("\(report.moduleName)：虚拟基址 0x\(String(report.guestBase, radix: 16))")
                                    .font(.footnote)
                                Text("模型数据 \(report.imageBytes) 字节；原生持有 \(report.ownedBytes) 字节；创建期间临时计划 \(report.temporaryBytes) 字节（现已释放）；合计创建峰值 \(report.creationPeakBytes) 字节。")
                                    .font(.caption)
                                Text("重定位 \(report.relocationCount)：RELATIVE \(report.relativeCount)，ABS64 \(report.absoluteCount)。初始化记录：\(report.hasInitializer ? "存在，仅记录，未调用" : "无")。仍不可运行游戏。")
                                    .font(.footnote)
                                Button("关闭布局模型（保留源对象）") { session.cancelPreparation() }
                            }
                        }
                    }
                    Section(header: Text("段内容校验（不执行代码）")) {
                        Text("手动开始后，逐模块解压并校验 NSO 文件头要求的 SHA-256。未启用哈希的段不会被标记为已校验哈希。单文件最多 64 MiB，文件与一个解压段合计最多 96 MiB。校验成功也不证明游戏身份或可运行性。")
                            .font(.footnote)
                        if session.isValidating {
                            ProgressView("正在解压与校验…")
                            Text("取消在当前读取或原生段校验结束后释放资源；不会应用已取消的结果。")
                                .font(.caption).foregroundColor(.secondary)
                            Button("取消内容校验") { session.cancelImport() }
                        } else {
                            Button("开始解压与哈希校验") { session.validatePayloads() }
                                .disabled(session.isImporting || session.isLoading)
                        }
                        if let report = session.validation {
                            Label("段内容校验完成；游戏仍不可运行", systemImage: "checkmark.circle")
                            ForEach(report.modules) { module in
                                Text("\(module.name)：解压 \(ByteCountFormatter.string(fromByteCount: Int64(module.decodedBytes), countStyle: .file))；已校验哈希 \(module.verifiedHashSegments)/3 段")
                                    .font(.footnote)
                            }
                            Text("剩余段未要求 SHA-256，未验证其哈希。未验证 NPDM 权限、游戏身份、动态链接或执行兼容性。")
                                .font(.footnote).foregroundColor(.secondary)
                        }
                    }
                }
                Section(header: Text("当前构建范围")) {
                    Text("原生 iOS 开发应用 • 只读输入检查 • 不代表可玩的游戏或可交付游戏 IPA")
                        .font(.footnote).foregroundColor(.secondary)
                }
            }
            .navigationTitle("Switch2IOS 实验室")
            .fileImporter(isPresented: $showsImporter, allowedContentTypes: [.folder], allowsMultipleSelection: false) { result in
                switch result {
                case .success(let urls): if let url = urls.first { session.importFolder(url) }
                case .failure(let error): session.reportPickerError(error)
                }
            }
        }
        .navigationViewStyle(.stack)
        .onChange(of: session.loadedInspection) { _ in
            selectedModule = ""
            modelBaseText = ""
        }
    }
}
