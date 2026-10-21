import Foundation
import Darwin

struct PayloadValidationReport: Equatable, Sendable {
    struct Module: Equatable, Identifiable, Sendable {
        var id: String { name }
        let name: String
        let decodedBytes: UInt64
        let verifiedHashSegments: Int
    }
    let modules: [Module]
}

enum PayloadValidationError: LocalizedError {
    case changedInputs, resourceLimit(String), native(String, String)
    var errorDescription: String? {
        switch self {
        case .changedInputs: return "输入文件列表或大小已变化，请重新选择文件夹。"
        case .resourceLimit(let name): return "\(name) 超出当前 iOS 校验内存预算：单文件最多 64 MiB，文件与一个解压段合计最多 96 MiB。"
        case .native(let name, let reason): return "\(name) 内容校验失败：\(reason)"
        }
    }
}

struct PayloadValidator {
    static let maximumFileBytes = 64 * 1024 * 1024
    static let maximumWorkingBytes = 96 * 1024 * 1024

    static func validate(folder: URL, inventory: InputInventory) throws -> PayloadValidationReport {
        let access = folder.startAccessingSecurityScopedResource()
        defer { if access { folder.stopAccessingSecurityScopedResource() } }
        let current = try InputInventoryReader.read(folder: folder)
        guard current.modules == inventory.modules else { throw PayloadValidationError.changedInputs }
        return try withExeFSDescriptor(folder: folder) { rootFD in
            var results: [PayloadValidationReport.Module] = []
            for module in inventory.modules {
                try Task.checkCancellation()
                // This helper scope releases the module and segment buffers before the next module.
                results.append(try validateModule(module, rootFD: rootFD))
            }
            try Task.checkCancellation()
            return PayloadValidationReport(modules: results)
        }
    }

    private static func validateModule(_ module: InputInventory.Module, rootFD: Int32) throws -> PayloadValidationReport.Module {
        let descriptor = openat(rootFD, module.name, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
        guard descriptor >= 0 else { throw InventoryError.unsafeEntry(module.name) }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? handle.close() }
        var info = stat()
        guard fstat(descriptor, &info) == 0,
              (info.st_mode & mode_t(S_IFMT)) == mode_t(S_IFREG), info.st_size == module.byteCount else {
            throw PayloadValidationError.changedInputs
        }
        guard info.st_size >= 256, info.st_size <= Int64(maximumFileBytes) else {
            throw PayloadValidationError.resourceLimit(module.name)
        }
        let count = Int(info.st_size)
        // A one-byte EOF probe detects files growing while being inspected.
        let bytes = try readExactBytes(descriptor: descriptor, count: count, requireEOF: true)
        try Task.checkCancellation()
        var plan = s2i_nso_plan()
        let status = bytes.withUnsafeBytes { raw in
            s2i_nso_inspect(raw.bindMemory(to: UInt8.self).baseAddress, bytes.count, &plan)
        }
        guard status == S2I_NSO_OK else {
            throw PayloadValidationError.native(module.name, nativeStatusDescription(status))
        }
        let segments = [plan.segments.0, plan.segments.1, plan.segments.2]
        var verified = 0
        for (index, segment) in segments.enumerated() {
            try Task.checkCancellation()
            let size = Int(segment.memory_size)
            guard size <= maximumWorkingBytes - bytes.count else {
                throw PayloadValidationError.resourceLimit(module.name)
            }
            // One destination segment exists at a time. The native function checks exact
            // LZ4 output length and any SHA-256 flag actually present in this NSO header.
            try validateSegment(bytes, index: index, size: size, name: module.name)
            if segment.hash_required != 0 { verified += 1 }
        }
        try Task.checkCancellation()
        return .init(name: module.name, decodedBytes: plan.decoded_size, verifiedHashSegments: verified)
    }

    private static func validateSegment(_ bytes: Data, index: Int, size: Int, name: String) throws {
        var output = Data(count: size)
        let status = bytes.withUnsafeBytes { input in
            output.withUnsafeMutableBytes { destination in
                s2i_nso_decode_segment(input.bindMemory(to: UInt8.self).baseAddress, bytes.count,
                                       UInt32(index), destination.bindMemory(to: UInt8.self).baseAddress, size)
            }
        }
        guard status == S2I_NSO_OK else { throw PayloadValidationError.native(name, nativeStatusDescription(status)) }
    }
}

/// Anchor directory reads to descriptors so a renamed/replaced exefs path cannot
/// redirect subsequent module opens. Only names from the fixed module allowlist enter openat.
func withExeFSDescriptor<T>(folder: URL, operation: (Int32) throws -> T) throws -> T {
    let rootFD = folder.withUnsafeFileSystemRepresentation { path -> Int32 in
        guard let path = path else { return -1 }
        return open(path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
    }
    guard rootFD >= 0 else { throw InventoryError.notDirectory }
    defer { close(rootFD) }
    let exefsFD = openat(rootFD, "exefs", O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
    if exefsFD >= 0 {
        defer { close(exefsFD) }
        return try operation(exefsFD)
    }
    guard errno == ENOENT else { throw InventoryError.unsafeEntry("exefs") }
    return try operation(rootFD)
}

func nativeStatusDescription(_ status: s2i_nso_status) -> String {
    switch status {
    case S2I_NSO_INVALID_ARGUMENT: return "参数无效或缓冲区重叠"
    case S2I_NSO_TRUNCATED: return "文件截断或数据超出文件范围"
    case S2I_NSO_UNSUPPORTED_FORMAT: return "不支持的 NSO 格式、版本或标记（不支持 ZBIC）"
    case S2I_NSO_RESOURCE_LIMIT: return "超出资源限制"
    case S2I_NSO_INVALID_RANGE: return "段、模块名称或表范围无效"
    case S2I_NSO_OVERLAP: return "数据范围重叠或顺序错误"
    case S2I_NSO_INVALID_LZ4: return "LZ4 数据损坏或解压长度不匹配"
    case S2I_NSO_HASH_MISMATCH: return "解压段 SHA-256 不匹配"
    case S2I_NSO_BUFFER_TOO_SMALL: return "目标缓冲区不足"
    case S2I_NSO_UNSUPPORTED_DYNAMIC_METADATA: return "MOD0 动态元数据需要尚未实现的链接器"
    default: return String(cString: s2i_nso_status_string(status))
    }
}

/// Reads directly into one preallocated buffer, tolerating short reads and EINTR.
/// Chunk boundaries also provide cancellation points without temporary payload copies.
func readExactBytes(descriptor: Int32, count: Int, requireEOF: Bool = false) throws -> Data {
    var data = Data(count: count)
    try data.withUnsafeMutableBytes { (buffer: UnsafeMutableRawBufferPointer) in
        var offset = 0
        while offset < count {
            try Task.checkCancellation()
            let amount = Darwin.read(descriptor, buffer.baseAddress!.advanced(by: offset), min(count - offset, 1024 * 1024))
            if amount < 0 {
                if errno == EINTR { continue }
                throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
            }
            guard amount > 0 else { throw PayloadValidationError.changedInputs }
            offset += amount
        }
    }
    if requireEOF {
        var byte: UInt8 = 0
        while true {
            try Task.checkCancellation()
            let amount = Darwin.read(descriptor, &byte, 1)
            if amount < 0 {
                if errno == EINTR { continue }
                throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
            }
            guard amount == 0 else { throw PayloadValidationError.changedInputs }
            break
        }
    }
    return data
}
