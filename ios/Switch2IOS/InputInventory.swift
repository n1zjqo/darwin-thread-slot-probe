import Foundation
import Darwin

/// Read-only inventory. Recognizing an NSO header does not authenticate a title or run code.
struct InputInventory: Equatable, Sendable {
    struct Module: Equatable, Identifiable, Sendable {
        var id: String { name }
        let name: String
        let byteCount: Int64
    }
    let folderName: String
    let modules: [Module]
    let hasNPDM: Bool
    let warnings: [String]
}

enum InventoryError: LocalizedError {
    case notDirectory, invalidLayout, unsafeEntry(String), invalidModule(String), nativeValidation(String, String), tooManyEntries
    var errorDescription: String? {
        switch self {
        case .notDirectory: return "请选择包含已提取 ExeFS 文件的文件夹。"
        case .invalidLayout: return "未找到 main 模块。请选择 ExeFS 文件夹，或包含 exefs 文件夹的上一级目录。"
        case .unsafeEntry(let name): return "条目不安全或无法读取：\(name)。不接受符号链接。"
        case .invalidModule(let name): return "\(name) 不是具有完整文件头的受支持 NSO0 模块。"
        case .nativeValidation(let name, let detail): return "\(name) 原生文件头校验失败：\(detail)。"
        case .tooManyEntries: return "文件夹条目过多，无法安全检查。请只选择已提取的 ExeFS 文件夹。"
        }
    }
}

struct InputInventoryReader {
    static let moduleNames = ["rtld", "main", "subsdk0", "subsdk1", "subsdk2", "subsdk3", "subsdk4", "subsdk5", "subsdk6", "subsdk7", "subsdk8", "subsdk9", "sdk"]

    static func read(folder: URL) throws -> InputInventory {
        let access = folder.startAccessingSecurityScopedResource()
        defer { if access { folder.stopAccessingSecurityScopedResource() } }
        let keys: Set<URLResourceKey> = [.isDirectoryKey, .isSymbolicLinkKey, .isRegularFileKey, .fileSizeKey]
        let folderValues = try folder.resourceValues(forKeys: keys)
        guard folderValues.isDirectory == true, folderValues.isSymbolicLink != true else { throw InventoryError.notDirectory }
        let manager = FileManager.default
        var root = folder
        let nested = folder.appendingPathComponent("exefs", isDirectory: true)
        if manager.fileExists(atPath: nested.path) {
            let values = try nested.resourceValues(forKeys: keys)
            guard values.isDirectory == true, values.isSymbolicLink != true else { throw InventoryError.unsafeEntry("exefs") }
            root = nested
        }
        var enumerationError: Error?
        guard let enumerator = manager.enumerator(at: root, includingPropertiesForKeys: Array(keys),
                options: [.skipsSubdirectoryDescendants], errorHandler: { _, error in
                    enumerationError = error
                    return false
                }) else { throw InventoryError.notDirectory }
        var entries: [URL] = []
        for case let url as URL in enumerator {
            try Task.checkCancellation()
            guard entries.count < 128 else { throw InventoryError.tooManyEntries }
            entries.append(url)
        }
        if let error = enumerationError { throw error }
        let byName = Dictionary(uniqueKeysWithValues: entries.map { ($0.lastPathComponent, $0) })
        guard byName["main"] != nil else { throw InventoryError.invalidLayout }
        return try withExeFSDescriptor(folder: folder) { rootFD in
            var modules: [InputInventory.Module] = []
            for name in moduleNames {
                try Task.checkCancellation()
                guard let url = byName[name] else { continue }
                let values = try url.resourceValues(forKeys: keys)
                guard values.isRegularFile == true, values.isSymbolicLink != true else { throw InventoryError.unsafeEntry(name) }
                // O_NOFOLLOW closes the final-component symlink race between metadata and open.
                let descriptor = openat(rootFD, name, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
                guard descriptor >= 0 else { throw InventoryError.unsafeEntry(name) }
                let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
                defer { try? handle.close() }
                var statInfo = stat()
                guard fstat(descriptor, &statInfo) == 0,
                      (statInfo.st_mode & mode_t(S_IFMT)) == mode_t(S_IFREG), statInfo.st_size >= 0 else {
                    throw InventoryError.unsafeEntry(name)
                }
                let header = try readExactBytes(descriptor: descriptor, count: 256)
                guard header.count == 256 else { throw InventoryError.invalidModule(name) }
                var plan = s2i_nso_plan()
                let status = header.withUnsafeBytes { bytes in
                    s2i_nso_inspect_header(bytes.bindMemory(to: UInt8.self).baseAddress, header.count, UInt64(statInfo.st_size), &plan)
                }
                guard status == S2I_NSO_OK else {
                    throw InventoryError.nativeValidation(name, nativeStatusDescription(status))
                }
                modules.append(.init(name: name, byteCount: Int64(statInfo.st_size)))
            }
            var hasNPDM = false
            if let url = byName["main.npdm"] {
                let values = try url.resourceValues(forKeys: keys)
                guard values.isRegularFile == true, values.isSymbolicLink != true else { throw InventoryError.unsafeEntry("main.npdm") }
                hasNPDM = true
            }
            var warnings = ["此清单仅检查原生文件头结构，不校验段内容、哈希、权限、游戏身份或执行兼容性。"]
            if !hasNPDM { warnings.append("缺少 main.npdm，无法获取进程元数据。") }
            return InputInventory(folderName: folder.lastPathComponent, modules: modules, hasNPDM: hasNPDM, warnings: warnings)
        }
    }
}
