import SwiftUI
import UniformTypeIdentifiers

@MainActor
struct ContentView: View {
    @EnvironmentObject private var session: SessionModel
    @State private var showsImporter = false

    var body: some View {
        NavigationView {
            List {
                Section(header: Text("运行状态")) {
                    Label("尚不能运行游戏", systemImage: "exclamationmark.triangle")
                        .foregroundColor(.orange)
                    Text("此开发应用可检查已提取的输入文件，但不能运行《圣兽之王》或任何 Switch 游戏。尚未接入 CPU 执行、图形、音频或游戏系统服务。")
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
    }
}
