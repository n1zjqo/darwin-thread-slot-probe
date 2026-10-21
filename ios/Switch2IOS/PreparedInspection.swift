import Foundation

/// Numeric layout-model diagnostics, never host addresses or borrowed native storage.
struct PreparedInspectionReport: Equatable, Sendable {
    let moduleName: String
    let guestBase: UInt64
    let imageBytes: Int
    let ownedBytes: Int
    let temporaryBytes: Int
    let creationPeakBytes: Int
    let reservedReportBytes: Int
    let relocationCount: Int
    let relativeCount: Int
    let absoluteCount: Int
    let hasInitializer: Bool // Recorded only; never invoked.
}

struct PreparedInspectionSession: Equatable, Sendable {
    let sourceToken: UUID
    let token: UUID
    let report: PreparedInspectionReport
}

enum PreparedInspectionError: LocalizedError {
    case invalidBase, staleSource, unknownModule, resourceLimit, native(String)
    var errorDescription: String? {
        switch self {
        case .invalidBase: return "请输入 0x 开头、1–16 位 ASCII 十六进制且按 4096 字节对齐的虚拟基址。它仅是布局模型参数，不是真实游戏地址。"
        case .staleSource: return "源诊断对象已关闭或替换，请重新加载并选择模块。"
        case .unknownModule: return "所选模块不在当前已持有的诊断对象中。"
        case .resourceLimit: return "准备布局模型超出预算：所有源对象、模型、临时重定位计划和报告预留合计最多 96 MiB。源诊断对象仍保留。"
        case .native(let detail): return "布局模型准备失败：\(detail)。源诊断对象仍保留；不支持的元数据、依赖和导入不会被猜测补全。"
        }
    }
}

/// Require an explicit representation; no whitespace, signs, separators or implicit base.
enum PreparedModelBase {
    static func parse(_ text: String) throws -> UInt64 {
        guard (3...18).contains(text.utf8.count) else { throw PreparedInspectionError.invalidBase }
        let bytes = Array(text.utf8) // Bounded before copying even a hostile paste.
        guard bytes[0] == 48, bytes[1] == 120,
              bytes.dropFirst(2).allSatisfy({ (48...57).contains($0) || (65...70).contains($0) || (97...102).contains($0) }),
              let value = UInt64(text.dropFirst(2), radix: 16), value % 4096 == 0 else {
            throw PreparedInspectionError.invalidBase
        }
        return value
    }
}

/// Checked aggregate admission arithmetic. The selected source is counted by C;
/// otherLive includes all other source modules and both bounded report reserves.
struct PreparedInspectionBudget: Equatable {
    static let reportReservation = 4096
    let otherLive: Int
    let maximumOwned: Int
    let maximumPeak: Int

    static func calculate(sourceOwned: Int, sourceReport: Int, selectedOwned: Int,
                          limit: Int) throws -> Self {
        guard sourceOwned >= 0, sourceReport >= 0, selectedOwned >= 0,
              selectedOwned <= sourceOwned, limit > 0,
              limit <= InputWorkQueue.maximumWorkingBytes,
              sourceOwned <= limit, sourceReport <= limit - sourceOwned,
              reportReservation <= limit - sourceOwned - sourceReport else {
            throw PreparedInspectionError.resourceLimit
        }
        let remaining = limit - sourceOwned - sourceReport - reportReservation
        guard remaining > 0 else { throw PreparedInspectionError.resourceLimit }
        return Self(otherLive: sourceOwned - selectedOwned + sourceReport + reportReservation,
                    maximumOwned: remaining, maximumPeak: limit)
    }
}
