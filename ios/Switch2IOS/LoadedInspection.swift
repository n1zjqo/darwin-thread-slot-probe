import Foundation
import Darwin

/// Value-only report: no native pointers, borrowed names, or executable addresses.
struct LoadedInspectionReport: Equatable, Sendable {
    struct Module: Equatable, Identifiable, Sendable {
        var id: String { name }
        let name: String
        let decodedBytes: UInt64
        let ownedBytes: Int
        let verifiedHashSegments: Int
        let dependencyCount: Int
        let symbolCount: Int
        let importCount: Int
        let exportCount: Int
        let warnings: UInt32
        let dependenciesComplete: Bool
        let importsComplete: Bool
    }
    let modules: [Module]
    let ownedBytes: Int
    let reservedReportBytes: Int
}

struct LoadedInspectionSession: Equatable, Sendable {
    let token: UUID
    let report: LoadedInspectionReport
}

enum LoadedInspectionError: LocalizedError {
    case invalidInventory, resourceLimit(String), native(String, String)
    var errorDescription: String? {
        switch self {
        case .invalidInventory: return "输入清单无效，请重新选择已提取的 ExeFS 文件夹。"
        case .resourceLimit(let name): return "\(name) 超出加载诊断预算：单文件最多 64 MiB；全部驻留模块、当前输入及报告预留合计最多 96 MiB。"
        case .native(let name, let detail): return "\(name) 加载诊断失败：\(detail)"
        }
    }
}

/// An actor-owned, non-Sendable RAII owner. No handle leaves InputWorkQueue.
/// The native object has no OS-thread affinity; all access is externally serialized.
private final class InspectionModuleOwner {
    var handle: OpaquePointer?
    init(_ handle: OpaquePointer) { self.handle = handle }
    deinit { s2i_module_destroy(&handle) }
}

private final class InspectionBatchOwner {
    let token = UUID()
    let modules: [InspectionModuleOwner]
    let report: LoadedInspectionReport
    init(modules: [InspectionModuleOwner], report: LoadedInspectionReport) {
        self.modules = modules
        self.report = report
    }
}

private final class PreparedImageOwner {
    var handle: OpaquePointer?
    let session: PreparedInspectionSession
    init(_ handle: OpaquePointer, session: PreparedInspectionSession) {
        self.handle = handle
        self.session = session
    }
    deinit { s2i_prepared_destroy(&handle) }
}

/// Serial ownership, not OS-thread affinity. No tc_bind or TLS association is used.
/// Native load methods are synchronous: no actor reentrancy while handles are accessed.
actor InputWorkQueue {
    static let shared = InputWorkQueue()
    static let maximumFileBytes = 64 * 1024 * 1024
    static let maximumWorkingBytes = 96 * 1024 * 1024
    // Fixed, conservative admission charge for each bounded numeric Swift report,
    // handle/list bookkeeping and fixed allowlisted module name. No arbitrary names
    // or symbol strings are copied. This is not a process RSS/allocator-overhead cap.
    static let reportReservationPerModule = 4096
    private var retained: InspectionBatchOwner?
    private var prepared: PreparedImageOwner?
    // The native plan is transient; only this bounded value report is retained.
    private var linked: LinkInspectionSession?
    private let workingByteLimit: Int

    // A lower limit is useful for deterministic integration tests; callers cannot
    // increase the production ceiling or silently relax native hard limits.
    init(maximumWorkingBytes: Int = InputWorkQueue.maximumWorkingBytes) {
        precondition(maximumWorkingBytes > 0 && maximumWorkingBytes <= Self.maximumWorkingBytes)
        self.workingByteLimit = maximumWorkingBytes
    }

    private func releaseInspection() {
        linked = nil // No native plan can survive the synchronous inventory call.
        prepared = nil // Derived storage is always released before its source batch.
        retained = nil
    }

    func inventory(folder: URL) throws -> InputInventory {
        try Task.checkCancellation()
        releaseInspection()
        return try InputInventoryReader.read(folder: folder)
    }

    func validate(folder: URL, inventory: InputInventory) throws -> PayloadValidationReport {
        try Task.checkCancellation()
        releaseInspection()
        return try PayloadValidator.validate(folder: folder, inventory: inventory)
    }

    /// Replaces any previous session before allocation; failure leaves no retained batch.
    /// A successful result is diagnostic only, even when both completeness flags are true.
    func loadForInspection(folder: URL, inventory: InputInventory) throws -> LoadedInspectionSession {
        try Task.checkCancellation()
        releaseInspection()
        let names = inventory.modules.map(\.name)
        let allowed = Set(InputInventoryReader.moduleNames)
        guard !names.isEmpty, names.count <= allowed.count, Set(names).count == names.count,
              names.contains("main"), names.allSatisfy({ allowed.contains($0) }) else {
            throw LoadedInspectionError.invalidInventory
        }
        let reportReservation = names.count * Self.reportReservationPerModule
        let access = folder.startAccessingSecurityScopedResource()
        defer { if access { folder.stopAccessingSecurityScopedResource() } }
        let current = try InputInventoryReader.read(folder: folder)
        guard current.modules == inventory.modules else { throw PayloadValidationError.changedInputs }
        let batch = try withExeFSDescriptor(folder: folder) { rootFD -> InspectionBatchOwner in
            var owners: [InspectionModuleOwner] = []
            var reports: [LoadedInspectionReport.Module] = []
            var ownedBytes = 0
            for module in inventory.modules {
                try Task.checkCancellation()
                let remaining = workingByteLimit - reportReservation - ownedBytes
                guard remaining > 0 else { throw LoadedInspectionError.resourceLimit(module.name) }
                // Input Data dies on return, before the next module's input is allocated.
                let loaded = try Self.loadModule(module, rootFD: rootFD, remaining: remaining)
                owners.append(loaded.0)
                reports.append(loaded.1)
                ownedBytes += loaded.1.ownedBytes // loadModule proved this fits remaining.
            }
            try Task.checkCancellation()
            return InspectionBatchOwner(modules: owners, report: .init(
                modules: reports, ownedBytes: ownedBytes, reservedReportBytes: reportReservation))
        }
        try Task.checkCancellation()
        retained = batch
        return LoadedInspectionSession(token: batch.token, report: batch.report)
    }

    /// Idempotent and token-specific: stale completion cleanup cannot close a newer batch.
    func close(token: UUID) {
        guard retained?.token == token else { return }
        releaseInspection()
    }

    /// Value-only lifecycle observation used by the app integration tests.
    func retainedToken() -> UUID? { retained?.token }

    /// Explicitly replaces the single old model, but never discards its source.
    /// Stale/cancelled requests and invalid selection/base cannot mutate current state.
    func prepare(sourceToken: UUID, moduleName: String, guestBase: UInt64) throws -> PreparedInspectionSession {
        try Task.checkCancellation()
        guard let source = retained, source.token == sourceToken else { throw PreparedInspectionError.staleSource }
        guard let index = source.report.modules.firstIndex(where: { $0.name == moduleName }),
              let module = source.modules[index].handle else { throw PreparedInspectionError.unknownModule }
        guard guestBase % 4096 == 0 else { throw PreparedInspectionError.invalidBase }
        prepared = nil // Explicit replacement frees the old model before allocating another.
        let budget = try PreparedInspectionBudget.calculate(
            sourceOwned: source.report.ownedBytes,
            sourceReport: source.report.reservedReportBytes + (linked?.report.reservedReportBytes ?? 0),
            selectedOwned: source.report.modules[index].ownedBytes, limit: workingByteLimit)
        var options = s2i_prepared_default_options()
        options.other_live_bytes = budget.otherLive
        options.max_owned_bytes = budget.maximumOwned
        options.max_peak_bytes = budget.maximumPeak
        var native: OpaquePointer?
        var nativeError = s2i_prepared_error()
        defer { s2i_prepared_destroy(&native) }
        // No suspension, borrowed pointer escape, thread-local binding or executable call.
        let status = s2i_prepared_create(module, guestBase, &options, &native, &nativeError)
        guard status == S2I_PREPARED_OK, let pointer = native else {
            if status == S2I_PREPARED_RESOURCE_LIMIT { throw PreparedInspectionError.resourceLimit }
            throw PreparedInspectionError.native(String(cString: s2i_prepared_status_string(status)))
        }
        try Task.checkCancellation()
        var summary = s2i_prepared_summary()
        guard s2i_prepared_get_summary(pointer, &summary) == S2I_PREPARED_OK,
              summary.guest_base == guestBase,
              summary.source_module_bytes == source.report.modules[index].ownedBytes,
              summary.other_live_bytes == budget.otherLive,
              summary.owned_bytes <= budget.maximumOwned,
              summary.creation_peak_bytes <= budget.maximumPeak else {
            throw PreparedInspectionError.native("原生模型摘要或预算不一致")
        }
        let report = PreparedInspectionReport(moduleName: moduleName, guestBase: summary.guest_base,
            imageBytes: summary.image_bytes, ownedBytes: summary.owned_bytes,
            temporaryBytes: summary.temporary_bytes, creationPeakBytes: summary.creation_peak_bytes,
            reservedReportBytes: PreparedInspectionBudget.reportReservation,
            relocationCount: summary.relocation_count, relativeCount: summary.relative_count,
            absoluteCount: summary.absolute_count, hasInitializer: summary.has_initializer != 0)
        let session = PreparedInspectionSession(sourceToken: sourceToken, token: UUID(), report: report)
        try Task.checkCancellation()
        prepared = PreparedImageOwner(pointer, session: session)
        native = nil
        return session
    }

    /// Both tokens are required: an old close must not release any newer model.
    func closePrepared(sourceToken: UUID, token: UUID) {
        guard retained?.token == sourceToken,
              prepared?.session.sourceToken == sourceToken, prepared?.session.token == token else { return }
        prepared = nil
    }

    func retainedPreparedSession() -> PreparedInspectionSession? { prepared?.session }

    /// Explicit read-only inventory over the ENTIRE already-owned module batch.
    /// No await in this method. Every borrowed handle stays local, and defer destroys
    /// the native plan before this call returns, throws, or any source can be replaced.
    /// The prepared image is never silently released to make this operation fit.
    func linkInventory(sourceToken: UUID) throws -> LinkInspectionSession {
        try Task.checkCancellation()
        guard let source = retained, source.token == sourceToken else { throw LinkInspectionError.staleSource }
        linked = nil // Explicit replacement of the old copied inventory report only.
        let budget = try LinkInspectionBudget.calculate(
            sourceOwned: source.report.ownedBytes, sourceReport: source.report.reservedReportBytes,
            moduleCount: source.modules.count, preparedOwned: prepared?.session.report.ownedBytes ?? 0,
            preparedReport: prepared?.session.report.reservedReportBytes ?? 0, limit: workingByteLimit)
        var options = s2i_link_default_options()
        options.other_live_bytes = budget.otherLive
        options.max_peak_bytes = budget.maximumPeak
        let handles = source.modules.map { $0.handle }
        guard handles.allSatisfy({ $0 != nil }) else { throw LinkInspectionError.staleSource }
        var native: OpaquePointer?
        var nativeError = s2i_link_error()
        defer { s2i_link_plan_destroy(&native) }
        let status = handles.withUnsafeBufferPointer {
            s2i_link_plan_create($0.baseAddress, $0.count, &options, &native, &nativeError)
        }
        guard status == S2I_LINK_OK, let pointer = native else {
            if status == S2I_LINK_RESOURCE_LIMIT { throw LinkInspectionError.resourceLimit }
            throw LinkInspectionError.native(String(cString: s2i_link_status_string(status)))
        }
        try Task.checkCancellation()
        var summary = s2i_link_summary()
        guard s2i_link_plan_get_summary(pointer, &summary) == S2I_LINK_OK,
              summary.policy == S2I_LINK_POLICY_DEFERRED,
              summary.module_count == source.modules.count,
              summary.source_module_bytes == source.report.ownedBytes,
              summary.other_live_bytes == budget.otherLive,
              summary.report_bytes == budget.reportReservation,
              summary.owned_bytes <= budget.maximumPeak,
              summary.temporary_bytes <= budget.maximumPeak,
              summary.creation_peak_bytes <= budget.maximumPeak,
              summary.creation_peak_bytes == source.report.ownedBytes + budget.otherLive
                + budget.reportReservation + summary.owned_bytes + summary.temporary_bytes else {
            throw LinkInspectionError.native("原生摘要或预算不一致")
        }
        // Native size_t values are bounded by the API's immutable hard caps.
        var reports: [LinkInspectionReport.Module] = []
        for index in source.modules.indices {
            try Task.checkCancellation()
            var report = s2i_link_module_report()
            guard s2i_link_plan_get_module(pointer, index, &report) == S2I_LINK_OK,
                  report.policy == S2I_LINK_POLICY_DEFERRED,
                  report.original_warnings == source.report.modules[index].warnings else {
                throw LinkInspectionError.native("原始警告或模块报告不一致")
            }
            reports.append(.init(id: index, format: report.format.rawValue,
                targets: report.targets.rawValue, inventory: report.inventory.rawValue,
                policy: report.policy.rawValue, gnuHash: report.gnu_hash.rawValue,
                originalWarnings: report.original_warnings, relaCount: report.rela_count,
                jmprelCount: report.jmprel_count, symbolCount: report.symbol_count,
                dependencyCount: report.dependency_count, unknownTagCount: report.unknown_tag_count))
        }
        let report = LinkInspectionReport(modules: reports, format: summary.format.rawValue,
            targets: summary.targets.rawValue, inventory: summary.inventory.rawValue,
            policy: summary.policy.rawValue, moduleCount: summary.module_count,
            relocationCount: summary.relocation_count, candidateCount: summary.candidate_count,
            symbolCount: summary.symbol_count, sourceModuleBytes: summary.source_module_bytes,
            ownedBytes: summary.owned_bytes, temporaryBytes: summary.temporary_bytes,
            reservedReportBytes: summary.report_bytes, otherLiveBytes: summary.other_live_bytes,
            creationPeakBytes: summary.creation_peak_bytes, nameWork: summary.name_work)
        let session = LinkInspectionSession(sourceToken: sourceToken, token: UUID(), report: report)
        try Task.checkCancellation()
        linked = session
        return session // defer destroys plan; no borrowed object leaves the actor call.
    }

    /// Copied report cleanup is source/token specific, including late cancellation.
    func closeLinkInventory(sourceToken: UUID, token: UUID) {
        guard retained?.token == sourceToken,
              linked?.sourceToken == sourceToken, linked?.token == token else { return }
        linked = nil
    }

    func retainedLinkSession() -> LinkInspectionSession? { linked }

    private static func loadModule(_ module: InputInventory.Module, rootFD: Int32,
                                   remaining: Int) throws -> (InspectionModuleOwner, LoadedInspectionReport.Module) {
        let descriptor = openat(rootFD, module.name, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
        guard descriptor >= 0 else { throw InventoryError.unsafeEntry(module.name) }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? handle.close() }
        var info = stat()
        guard fstat(descriptor, &info) == 0,
              (info.st_mode & mode_t(S_IFMT)) == mode_t(S_IFREG),
              info.st_size == module.byteCount, info.st_size >= 256 else {
            throw PayloadValidationError.changedInputs
        }
        guard info.st_size <= Int64(maximumFileBytes), info.st_size <= Int64(remaining) else {
            throw LoadedInspectionError.resourceLimit(module.name)
        }
        let bytes = try readExactBytes(descriptor: descriptor, count: Int(info.st_size), requireEOF: true)
        try Task.checkCancellation()
        var options = s2i_module_default_options()
        options.max_file_bytes = maximumFileBytes
        options.max_owned_bytes = remaining
        options.max_peak_bytes = remaining
        var native: OpaquePointer?
        var nativeError = s2i_module_error()
        defer { s2i_module_destroy(&native) }
        let status = bytes.withUnsafeBytes { input in
            s2i_module_load(input.bindMemory(to: UInt8.self).baseAddress, bytes.count,
                            &options, &native, &nativeError)
        }
        guard status == S2I_MODULE_OK, let pointer = native else {
            if status == S2I_MODULE_RESOURCE_LIMIT { throw LoadedInspectionError.resourceLimit(module.name) }
            let detail: String
            if status == S2I_MODULE_NSO_ERROR {
                detail = nativeStatusDescription(nativeError.nso_status)
            } else if status == S2I_MODULE_DYNAMIC_ERROR {
                detail = String(cString: s2i_dynamic_status_string(nativeError.dynamic_status))
            } else {
                detail = String(cString: s2i_module_status_string(status))
            }
            throw LoadedInspectionError.native(module.name, detail)
        }
        try Task.checkCancellation()
        var summary = s2i_module_summary()
        guard s2i_module_get_summary(pointer, &summary) == S2I_MODULE_OK,
              summary.owned_bytes <= remaining,
              summary.load_peak_bytes <= remaining else {
            throw LoadedInspectionError.native(module.name, "原生对象摘要或预算不一致")
        }
        let segments = [summary.plan.segments.0, summary.plan.segments.1, summary.plan.segments.2]
        let report = LoadedInspectionReport.Module(
            name: module.name, decodedBytes: summary.plan.decoded_size, ownedBytes: summary.owned_bytes,
            verifiedHashSegments: segments.filter { $0.hash_required != 0 }.count,
            dependencyCount: summary.dependency_count, symbolCount: summary.symbol_count,
            importCount: summary.import_count, exportCount: summary.export_count,
            warnings: summary.warnings, dependenciesComplete: summary.dependencies_complete != 0,
            importsComplete: summary.imports_complete != 0)
        let owner = InspectionModuleOwner(pointer)
        native = nil
        return (owner, report)
    }
}
