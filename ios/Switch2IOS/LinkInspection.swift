import Foundation

/// Copied numeric inventory only. No names, pointers, bases, selected providers or
/// executable addresses. Validation states never imply an executable image.
struct LinkInspectionReport: Equatable, Sendable {
    struct Module: Equatable, Identifiable, Sendable {
        let id: Int
        let format: UInt32
        let targets: UInt32
        let inventory: UInt32
        let policy: UInt32
        let gnuHash: UInt32
        let originalWarnings: UInt32
        let relaCount: Int
        let jmprelCount: Int
        let symbolCount: Int
        let dependencyCount: Int
        let unknownTagCount: Int
    }
    let modules: [Module]
    let format: UInt32
    let targets: UInt32
    let inventory: UInt32
    let policy: UInt32
    let moduleCount: Int
    let relocationCount: Int
    let candidateCount: Int
    let symbolCount: Int
    let sourceModuleBytes: Int
    let ownedBytes: Int
    let temporaryBytes: Int
    let reservedReportBytes: Int
    let otherLiveBytes: Int
    let creationPeakBytes: Int
    let nameWork: Int
}

struct LinkInspectionSession: Equatable, Sendable {
    let sourceToken: UUID
    let token: UUID
    let report: LinkInspectionReport
}

enum LinkInspectionError: LocalizedError {
    case staleSource, resourceLimit, native(String)
    var errorDescription: String? {
        switch self {
        case .staleSource: return "源诊断对象已关闭或替换，请重新加载模块。"
        case .resourceLimit: return "批量链接清单超出 96 MiB 合计预算。源模块及已持有布局模型保留；可显式关闭布局模型后重试。"
        case .native(let detail): return "只读链接清单失败：\(detail)。源模块及已持有布局模型保留；不推测或放宽链接策略。"
        }
    }
}

/// C charges all source modules and (moduleCount + 1) report reservations itself.
/// otherLive charges ONLY existing loaded reports and retained prepared storage
/// plus its report. The old link report is explicitly released before replacement.
struct LinkInspectionBudget: Equatable {
    let otherLive: Int
    let maximumPeak: Int
    let reportReservation: Int

    static func calculate(sourceOwned: Int, sourceReport: Int, moduleCount: Int,
                          preparedOwned: Int, preparedReport: Int, limit: Int) throws -> Self {
        guard (1...16).contains(moduleCount), limit > 0,
              limit <= InputWorkQueue.maximumWorkingBytes else { throw LinkInspectionError.resourceLimit }
        let reservation = (moduleCount + 1) * 4096
        var remaining = limit
        // Subtract only after checking: hostile Int.max/negative inputs cannot overflow.
        for amount in [sourceOwned, sourceReport, preparedOwned, preparedReport, reservation] {
            guard amount >= 0, amount <= remaining else { throw LinkInspectionError.resourceLimit }
            remaining -= amount
        }
        guard remaining > 0 else { throw LinkInspectionError.resourceLimit }
        return Self(otherLive: sourceReport + preparedOwned + preparedReport,
                    maximumPeak: limit, reportReservation: reservation)
    }
}
