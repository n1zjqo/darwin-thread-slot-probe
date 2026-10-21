import Foundation
import CryptoKit
import XCTest
@testable import Switch2IOS

final class PreparedInspectionTests: XCTestCase {
    private var folder: URL!
    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try FileManager.default.removeItem(at: folder) }

    private func write(_ bytes: Data, name: String = "main") throws {
        try bytes.write(to: folder.appendingPathComponent(name))
    }
    private func load(_ queue: InputWorkQueue) async throws -> LoadedInspectionSession {
        let inventory = try await queue.inventory(folder: folder)
        return try await queue.loadForInspection(folder: folder, inventory: inventory)
    }

    func testExplicitBaseParserRejectsAmbiguousOrUnalignedInputs() throws {
        XCTAssertEqual(try PreparedModelBase.parse("0x0"), 0)
        XCTAssertEqual(try PreparedModelBase.parse("0x100000000"), 0x100000000)
        XCTAssertEqual(try PreparedModelBase.parse("0xFFFFFFFFFFFFF000"), 0xfffffffffffff000)
        for text in ["", "0x", "1000", "0X1000", "+0x1000", "-0x1000", " 0x1000", "0x1000\n",
                     "0x1_000", "0x1001", "0x10000000000000000", "0x１２３", "0xgggg", String(repeating: "a", count: 4096)] {
            XCTAssertThrowsError(try PreparedModelBase.parse(text), text)
        }
    }

    func testBudgetChargesAllSourcesBothReportsAndRejectsOverflow() throws {
        let budget = try PreparedInspectionBudget.calculate(sourceOwned: 1000, sourceReport: 8192,
                                                            selectedOwned: 400, limit: 20000)
        XCTAssertEqual(budget.otherLive, 600 + 8192 + 4096)
        XCTAssertEqual(budget.maximumOwned, 20000 - 1000 - 8192 - 4096)
        XCTAssertEqual(budget.maximumPeak, 20000)
        for (owned, report, selected, limit) in [(Int.max, 0, 0, 20000), (1, Int.max, 1, 20000),
            (1000, 8192, 1001, 20000), (-1, 0, 0, 20000), (1000, 8192, 400, 13288),
            (1, 1, 1, InputWorkQueue.maximumWorkingBytes + 1)] {
            XCTAssertThrowsError(try PreparedInspectionBudget.calculate(sourceOwned: owned, sourceReport: report,
                                                                         selectedOwned: selected, limit: limit))
        }
    }

    func testActualOwnedSourcePreparesAndCopiedReportSurvivesClose() async throws {
        try write(PreparedNSOFixture.make())
        let queue = InputWorkQueue(), source = try await load(queue)
        let model = try await queue.prepare(sourceToken: source.token, moduleName: "main", guestBase: 0x100000000)
        let report = model.report
        XCTAssertEqual(report.relocationCount, 1)
        XCTAssertEqual(report.relativeCount, 1)
        XCTAssertEqual(report.absoluteCount, 0)
        XCTAssertFalse(report.hasInitializer)
        XCTAssertEqual(report.imageBytes, 0x100 + 0x180 + 0x40 + 0x20)
        XCTAssertGreaterThan(report.temporaryBytes, 0)
        XCTAssertEqual(report.creationPeakBytes, source.report.ownedBytes + source.report.reservedReportBytes
                       + report.reservedReportBytes + report.ownedBytes + report.temporaryBytes)
        await queue.closePrepared(sourceToken: source.token, token: model.token)
        let retained = await queue.retainedToken(), prepared = await queue.retainedPreparedSession()
        XCTAssertEqual(retained, source.token)
        XCTAssertNil(prepared)
        XCTAssertEqual(report, model.report)
        await queue.close(token: source.token)
        XCTAssertEqual(report.guestBase, 0x100000000)
    }

    func testReplacementOldCloseAndStaleSourceCannotMutateNewModel() async throws {
        try write(PreparedNSOFixture.make())
        let queue = InputWorkQueue(), oldSource = try await load(queue)
        let old = try await queue.prepare(sourceToken: oldSource.token, moduleName: "main", guestBase: 0x1000)
        let replacement = try await queue.prepare(sourceToken: oldSource.token, moduleName: "main", guestBase: 0x2000)
        await queue.closePrepared(sourceToken: oldSource.token, token: old.token)
        var current = await queue.retainedPreparedSession()
        XCTAssertEqual(current, replacement)
        let newSource = try await load(queue)
        let newest = try await queue.prepare(sourceToken: newSource.token, moduleName: "main", guestBase: 0x3000)
        do {
            _ = try await queue.prepare(sourceToken: oldSource.token, moduleName: "main", guestBase: 0x4000)
            XCTFail("Different source token must reject before replacing any model")
        } catch PreparedInspectionError.staleSource { }
        await queue.closePrepared(sourceToken: oldSource.token, token: newest.token)
        await queue.close(token: oldSource.token)
        current = await queue.retainedPreparedSession()
        XCTAssertEqual(current, newest)
        await queue.close(token: newSource.token)
    }

    func testRejectedMetadataRelocationsAndMissingHashesPreserveSource() async throws {
        for kind in [PreparedNSOFixture.Kind.dependency, .unknownTag, .unsupportedRelocation, .unhashed] {
            try write(PreparedNSOFixture.make(kind))
            let queue = InputWorkQueue(), source = try await load(queue)
            do {
                _ = try await queue.prepare(sourceToken: source.token, moduleName: "main", guestBase: 0x1000)
                XCTFail("Unsupported fixture must reject: \(kind)")
            } catch is PreparedInspectionError { }
            let retained = await queue.retainedToken(), prepared = await queue.retainedPreparedSession()
            XCTAssertEqual(retained, source.token)
            XCTAssertNil(prepared)
            await queue.close(token: source.token)
        }
    }

    func testAggregateBudgetFailurePreservesAllLoadedSources() async throws {
        let bytes = PreparedNSOFixture.make()
        try write(bytes); try write(bytes, name: "sdk")
        let normal = InputWorkQueue(), sizing = try await load(normal)
        // Exactly enough for all source objects + source reports + the last input.
        // Not enough for the additional model report and prepared storage/temporary plan.
        let limit = sizing.report.ownedBytes + sizing.report.reservedReportBytes + bytes.count
        await normal.close(token: sizing.token)
        let bounded = InputWorkQueue(maximumWorkingBytes: limit), source = try await load(bounded)
        XCTAssertEqual(source.report.modules.count, 2)
        do {
            _ = try await bounded.prepare(sourceToken: source.token, moduleName: "main", guestBase: 0x1000)
            XCTFail("Preparation must include every retained source and both report reserves")
        } catch PreparedInspectionError.resourceLimit { }
        let retained = await bounded.retainedToken(), prepared = await bounded.retainedPreparedSession()
        XCTAssertEqual(retained, source.token)
        XCTAssertNil(prepared)
        await bounded.close(token: source.token)
    }

    func testCancelledQueuedPreparationDoesNotReleaseCurrentModel() async throws {
        try write(PreparedNSOFixture.make())
        let queue = InputWorkQueue(), source = try await load(queue), gate = PreparedTestGate()
        let old = Task {
            await gate.wait()
            return try await queue.prepare(sourceToken: source.token, moduleName: "main", guestBase: 0x1000)
        }
        await gate.waitUntilStarted()
        old.cancel()
        let newer = try await queue.prepare(sourceToken: source.token, moduleName: "main", guestBase: 0x2000)
        await gate.release()
        do { _ = try await old.value; XCTFail("Cancelled old request must not mutate actor state") }
        catch is CancellationError { }
        let current = await queue.retainedPreparedSession()
        XCTAssertEqual(current, newer)
        await queue.close(token: source.token)
    }

    func testInvalidSelectionLeavesModelButFailedExplicitReplacementRemovesOldOnly() async throws {
        try write(PreparedNSOFixture.make())
        let queue = InputWorkQueue(), source = try await load(queue)
        let model = try await queue.prepare(sourceToken: source.token, moduleName: "main", guestBase: 0x1000)
        for (name, base) in [("not-a-module", UInt64(0x2000)), ("main", UInt64(1))] {
            do { _ = try await queue.prepare(sourceToken: source.token, moduleName: name, guestBase: base); XCTFail() }
            catch is PreparedInspectionError { }
            let current = await queue.retainedPreparedSession()
            XCTAssertEqual(current, model)
        }
        // Aligned UInt64 base, but segment end overflows. This is an explicit valid
        // replacement request: old model is released, native rejects, source survives.
        do {
            _ = try await queue.prepare(sourceToken: source.token, moduleName: "main", guestBase: 0xfffffffffffff000)
            XCTFail("Overflowing layout must not prepare")
        } catch is PreparedInspectionError { }
        let current = await queue.retainedPreparedSession(), retained = await queue.retainedToken()
        XCTAssertNil(current)
        XCTAssertEqual(retained, source.token)
        await queue.close(token: source.token)
    }

    func testSourceCloseAndInventoryValidationLoadCascadeModelCleanup() async throws {
        try write(PreparedNSOFixture.make())
        let queue = InputWorkQueue()
        for kind in 0..<4 {
            let source = try await load(queue)
            _ = try await queue.prepare(sourceToken: source.token, moduleName: "main", guestBase: 0x1000)
            if kind == 0 { await queue.close(token: source.token) }
            else if kind == 1 { _ = try await queue.inventory(folder: folder) }
            else {
                let inventory = try InputInventoryReader.read(folder: folder)
                if kind == 2 { _ = try await queue.validate(folder: folder, inventory: inventory) }
                else { _ = try await queue.loadForInspection(folder: folder, inventory: inventory) }
            }
            let current = await queue.retainedPreparedSession()
            XCTAssertNil(current)
        }
    }
}

/// Wholly synthetic NSO: zero text, MOD0, bounded dynamic inventory, one RELATIVE
/// record and zero data/BSS. No instructions, game bytes, keys or guest execution.
private enum PreparedNSOFixture {
    enum Kind { case good, dependency, unknownTag, unsupportedRelocation, unhashed }
    static func make(_ kind: Kind = .good) -> Data {
        func put(_ bytes: inout Data, _ offset: Int, _ value: UInt64, _ width: Int = 4) {
            for i in 0..<width { bytes[offset + i] = UInt8(truncatingIfNeeded: value >> (8 * i)) }
        }
        var text = Data(repeating: 0, count: 0x100)
        put(&text, 4, 0x40)
        text.replaceSubrange(0x40..<0x44, with: Array("MOD0".utf8))
        put(&text, 0x44, 0x2000 - 0x40)
        put(&text, 0x48, 0x4040 - 0x40); put(&text, 0x4c, 0x4060 - 0x40)
        var ro = Data(repeating: 0, count: 0x180)
        ro.replaceSubrange(0x100..<0x107, with: [0, 109, 111, 100, 101, 108, 0])
        // dynsym[0] is the null symbol at 0x2110; SYSV hash bounds one symbol.
        put(&ro, 0x130, 1); put(&ro, 0x134, 1)
        put(&ro, 0x150, 0x4000, 8)
        put(&ro, 0x158, kind == .unsupportedRelocation ? 999 : 1027, 8)
        put(&ro, 0x160, 0x1234, 8)
        var tags: [(UInt64, UInt64)] = [(5, 0x2100), (10, 7), (6, 0x2110), (11, 24),
                                      (4, 0x2130), (14, 1), (7, 0x2150), (8, 24), (9, 24)]
        if kind == .dependency { tags.append((1, 1)) }
        if kind == .unknownTag { tags.append((0x60000000, 0)) }
        for (i, tag) in tags.enumerated() { put(&ro, i * 16, tag.0, 8); put(&ro, i * 16 + 8, tag.1, 8) }
        let parts = [text, ro, Data(repeating: 0, count: 0x40)]
        var bytes = Data(repeating: 0, count: 256)
        bytes.replaceSubrange(0..<4, with: Array("NSO0".utf8))
        put(&bytes, 12, kind == .unhashed ? 0 : 0x38); put(&bytes, 0x3c, 0x20)
        put(&bytes, 0x90, 0x100); put(&bytes, 0x94, 7)
        put(&bytes, 0x98, 0x110); put(&bytes, 0x9c, 24)
        for (i, part) in parts.enumerated() {
            put(&bytes, 0x10 + i * 16, UInt64(bytes.count))
            put(&bytes, 0x14 + i * 16, UInt64(i * 0x2000))
            put(&bytes, 0x18 + i * 16, UInt64(part.count))
            put(&bytes, 0x60 + i * 4, UInt64(part.count))
            bytes.replaceSubrange((0xa0 + i * 32)..<(0xc0 + i * 32), with: Array(SHA256.hash(data: part)))
            bytes.append(part)
        }
        return bytes
    }
}

private actor PreparedTestGate {
    private var blocked: CheckedContinuation<Void, Never>?
    private var started: CheckedContinuation<Void, Never>?
    func wait() async { await withCheckedContinuation { blocked = $0; started?.resume(); started = nil } }
    func waitUntilStarted() async { if blocked != nil { return }; await withCheckedContinuation { started = $0 } }
    func release() { blocked?.resume(); blocked = nil }
}

@MainActor
final class PreparedInspectionSessionModelTests: XCTestCase {
    private func inventory() -> InputInventory {
        .init(folderName: "synthetic", modules: [.init(name: "main", byteCount: 960)], hasNPDM: false, warnings: [])
    }
    private func source() -> LoadedInspectionSession {
        let module = LoadedInspectionReport.Module(name: "main", decodedBytes: 704, ownedBytes: 1024,
            verifiedHashSegments: 3, dependencyCount: 0, symbolCount: 1, importCount: 0, exportCount: 0,
            warnings: 0, dependenciesComplete: true, importsComplete: true)
        return .init(token: UUID(), report: .init(modules: [module], ownedBytes: 1024, reservedReportBytes: 4096))
    }
    private func prepared(_ source: UUID, base: UInt64 = 0x1000) -> PreparedInspectionSession {
        .init(sourceToken: source, token: UUID(), report: .init(moduleName: "main", guestBase: base,
            imageBytes: 736, ownedBytes: 1000, temporaryBytes: 32, creationPeakBytes: 10248,
            reservedReportBytes: 4096, relocationCount: 1, relativeCount: 1, absoluteCount: 0, hasInitializer: false))
    }

    func testCancelPreparationCleansLateSuccessButPreservesSource() async {
        let gate = PreparedTestGate(), ledger = PreparedCloseLedger()
        let input = inventory(), source = source(), result = prepared(source.token)
        let model = SessionModel(inventoryLoader: { _ in input }, inspectionLoader: { _, _ in source },
            inspectionCloser: { await ledger.source($0) },
            preparationLoader: { _, _, _ in await gate.wait(); return result },
            preparationCloser: { await ledger.prepared($0, $1) })
        await model.importFolder(URL(fileURLWithPath: "/synthetic")).value
        await model.loadForInspection()!.value
        let operation = model.prepareSelectedModule("main", baseText: "0x1000")!
        await gate.waitUntilStarted()
        model.cancelPreparation()
        await gate.release(); await operation.value
        XCTAssertEqual(model.loadedInspection, source.report)
        XCTAssertNil(model.preparedInspection)
        XCTAssertFalse(model.isPreparing)
        let events = await ledger.events()
        XCTAssertEqual(events, [.prepared(source.token, result.token)])
        await model.closeLoadedInspection()?.value
    }

    func testLateOldModelCannotReplaceNewModelForSameSource() async {
        let gate = PreparedTestGate(), ledger = PreparedCloseLedger()
        let input = inventory(), source = source()
        let oldResult = prepared(source.token), newResult = prepared(source.token, base: 0x2000)
        let model = SessionModel(inventoryLoader: { _ in input }, inspectionLoader: { _, _ in source },
            inspectionCloser: { await ledger.source($0) }, preparationLoader: { _, _, base in
                await ledger.enterLoader(base)
                if base == 0x1000 { await gate.wait(); return oldResult }
                let closed = await ledger.events()
                XCTAssertTrue(closed.contains(.prepared(source.token, oldResult.token)))
                return newResult
            }, preparationCloser: { await ledger.prepared($0, $1) })
        await model.importFolder(URL(fileURLWithPath: "/synthetic")).value
        await model.loadForInspection()!.value
        let old = model.prepareSelectedModule("main", baseText: "0x1000")!
        await gate.waitUntilStarted()
        let newer = model.prepareSelectedModule("main", baseText: "0x2000")!
        let entered = await ledger.loaderEntries()
        XCTAssertEqual(entered, [0x1000])
        XCTAssertNil(model.preparedInspection)
        await gate.release(); await old.value; await newer.value
        XCTAssertEqual(model.preparedInspection, newResult.report)
        XCTAssertEqual(model.loadedInspection, source.report)
        let events = await ledger.events()
        XCTAssertEqual(events, [.prepared(source.token, oldResult.token)])
        await model.closeLoadedInspection()?.value
    }

    func testSourceReplacementRejectsLateOldModelWithoutTouchingNewReport() async {
        let gate = PreparedTestGate(), ledger = PreparedCloseLedger()
        let input = inventory(), oldSource = source(), newSource = source()
        let oldModel = prepared(oldSource.token), newModel = prepared(newSource.token, base: 0x2000)
        let model = SessionModel(inventoryLoader: { _ in input }, inspectionLoader: { url, _ in
            url.lastPathComponent == "old" ? oldSource : newSource
        }, inspectionCloser: { await ledger.source($0) }, preparationLoader: { token, _, _ in
            await ledger.enterLoader(token == oldSource.token ? 0x1000 : 0x2000)
            if token == oldSource.token { await gate.wait(); return oldModel }
            let closed = await ledger.events()
            XCTAssertTrue(closed.contains(.prepared(oldSource.token, oldModel.token)))
            XCTAssertTrue(closed.contains(.source(oldSource.token)))
            return newModel
        }, preparationCloser: { await ledger.prepared($0, $1) })
        await model.importFolder(URL(fileURLWithPath: "/old")).value
        await model.loadForInspection()!.value
        let old = model.prepareSelectedModule("main", baseText: "0x1000")!
        await gate.waitUntilStarted()
        let replacement = model.importFolder(URL(fileURLWithPath: "/new"))
        let entered = await ledger.loaderEntries()
        XCTAssertEqual(entered, [0x1000])
        XCTAssertNil(model.loadedInspection)
        await gate.release(); await old.value; await replacement.value
        await model.loadForInspection()!.value
        await model.prepareSelectedModule("main", baseText: "0x2000")!.value
        XCTAssertEqual(model.loadedInspection, newSource.report)
        XCTAssertEqual(model.preparedInspection, newModel.report)
        let events = await ledger.events()
        XCTAssertTrue(events.contains(.prepared(oldSource.token, oldModel.token)))
        XCTAssertFalse(events.contains(.source(newSource.token)))
        XCTAssertFalse(events.contains(.prepared(newSource.token, newModel.token)))
        await model.closeLoadedInspection()?.value
    }

    func testFailureAndInvalidInputKeepSourceAndDoNotPretendPrepared() async {
        let input = inventory(), source = source(), ledger = PreparedCloseLedger()
        let model = SessionModel(inventoryLoader: { _ in input }, inspectionLoader: { _, _ in source },
            inspectionCloser: { await ledger.source($0) }, preparationLoader: { _, _, _ in
                throw PreparedInspectionError.resourceLimit
            }, preparationCloser: { await ledger.prepared($0, $1) })
        await model.importFolder(URL(fileURLWithPath: "/synthetic")).value
        await model.loadForInspection()!.value
        XCTAssertNil(model.prepareSelectedModule("main", baseText: "0x1001"))
        XCTAssertNil(model.prepareSelectedModule("unknown", baseText: "0x1000"))
        await model.prepareSelectedModule("main", baseText: "0x1000")!.value
        XCTAssertEqual(model.loadedInspection, source.report)
        XCTAssertNil(model.preparedInspection)
        XCTAssertNotNil(model.errorMessage)
        XCTAssertFalse(model.isPreparing)
        let events = await ledger.events()
        XCTAssertTrue(events.isEmpty)
        await model.closeLoadedInspection()?.value
    }

    func testDeallocatedModelClosesLateUnpublishedPreparation() async {
        let gate = PreparedTestGate(), ledger = PreparedCloseLedger()
        let input = inventory(), source = source(), result = prepared(source.token)
        var model: SessionModel? = SessionModel(inventoryLoader: { _ in input }, inspectionLoader: { _, _ in source },
            inspectionCloser: { await ledger.source($0) },
            preparationLoader: { _, _, _ in await gate.wait(); return result },
            preparationCloser: { await ledger.prepared($0, $1) })
        await model!.importFolder(URL(fileURLWithPath: "/synthetic")).value
        await model!.loadForInspection()!.value
        let operation = model!.prepareSelectedModule("main", baseText: "0x1000")!
        await gate.waitUntilStarted()
        weak var weakModel = model
        model = nil
        XCTAssertNil(weakModel)
        let beforeRelease = await ledger.events()
        XCTAssertTrue(beforeRelease.isEmpty)
        await gate.release(); await operation.value
        await ledger.waitForSource(source.token)
        let events = await ledger.events()
        XCTAssertEqual(events, [.prepared(source.token, result.token), .source(source.token)])
    }

    func testWrongSourceProviderCleanupCannotSetErrorOnNewGeneration() async {
        let cleanupGate = PreparedTestGate(), ledger = PreparedCloseLedger()
        let input = inventory(), source = source(), wrongResult = prepared(UUID()), goodResult = prepared(source.token, base: 0x2000)
        let model = SessionModel(inventoryLoader: { _ in input }, inspectionLoader: { _, _ in source },
            inspectionCloser: { await ledger.source($0) }, preparationLoader: { _, _, base in
                await ledger.enterLoader(base)
                if base == 0x1000 { return wrongResult }
                let closed = await ledger.events()
                XCTAssertTrue(closed.contains(.prepared(wrongResult.sourceToken, wrongResult.token)))
                return goodResult
            }, preparationCloser: { source, token in
                if token == wrongResult.token { await cleanupGate.wait() }
                await ledger.prepared(source, token)
            })
        await model.importFolder(URL(fileURLWithPath: "/synthetic")).value
        await model.loadForInspection()!.value
        let old = model.prepareSelectedModule("main", baseText: "0x1000")!
        await cleanupGate.waitUntilStarted()
        let newer = model.prepareSelectedModule("main", baseText: "0x2000")!
        let entered = await ledger.loaderEntries()
        XCTAssertEqual(entered, [0x1000])
        await cleanupGate.release(); await old.value; await newer.value
        XCTAssertEqual(model.preparedInspection, goodResult.report)
        XCTAssertEqual(model.loadedInspection, source.report)
        XCTAssertNil(model.errorMessage)
        let events = await ledger.events()
        XCTAssertEqual(events, [.prepared(wrongResult.sourceToken, wrongResult.token)])
        await model.closeLoadedInspection()?.value
    }

    func testCloseClearAndBackgroundReleaseModelBeforeSource() async {
        for kind in 0..<3 {
            let ledger = PreparedCloseLedger(), input = inventory(), source = source(), result = prepared(source.token)
            let model = SessionModel(inventoryLoader: { _ in input }, inspectionLoader: { _, _ in source },
                inspectionCloser: { await ledger.source($0) }, preparationLoader: { _, _, _ in result },
                preparationCloser: { await ledger.prepared($0, $1) })
            await model.importFolder(URL(fileURLWithPath: "/synthetic")).value
            await model.loadForInspection()!.value
            await model.prepareSelectedModule("main", baseText: "0x1000")!.value
            if kind == 0 { await model.closeLoadedInspection()?.value }
            else if kind == 1 { model.clear() }
            else { model.transition(to: .background) }
            await ledger.waitForSource(source.token)
            XCTAssertNil(model.loadedInspection)
            XCTAssertNil(model.preparedInspection)
            XCTAssertFalse(model.isPreparing)
            let events = await ledger.events()
            XCTAssertEqual(events, [.prepared(source.token, result.token), .source(source.token)])
        }
    }
}

private actor PreparedCloseLedger {
    enum Event: Equatable { case prepared(UUID, UUID), source(UUID) }
    private var closed: [Event] = []
    private var entered: [UInt64] = []
    func enterLoader(_ base: UInt64) { entered.append(base) }
    func loaderEntries() -> [UInt64] { entered }
    private var waiters: [UUID: CheckedContinuation<Void, Never>] = [:]
    func prepared(_ source: UUID, _ model: UUID) { closed.append(.prepared(source, model)) }
    func source(_ token: UUID) { closed.append(.source(token)); waiters.removeValue(forKey: token)?.resume() }
    func events() -> [Event] { closed }
    func waitForSource(_ token: UUID) async {
        if closed.contains(.source(token)) { return }
        await withCheckedContinuation { waiters[token] = $0 }
    }
}
