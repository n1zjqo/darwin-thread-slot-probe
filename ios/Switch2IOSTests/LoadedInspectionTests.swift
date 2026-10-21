import Foundation
import XCTest
@testable import Switch2IOS

final class LoadedInspectionTests: XCTestCase {
    private var folder: URL!
    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try FileManager.default.removeItem(at: folder) }

    private func module(_ name: String = "main", badHash: Bool = false) throws {
        var bytes = Data(repeating: 0, count: 256)
        bytes.replaceSubrange(0..<4, with: [0x4e, 0x53, 0x4f, 0x30])
        if badHash { bytes[12] = 8 }
        try bytes.write(to: folder.appendingPathComponent(name))
    }

    func testOwnedSessionClosesButCopiedReportSurvives() async throws {
        try module()
        let queue = InputWorkQueue()
        let inventory = try await queue.inventory(folder: folder)
        let session = try await queue.loadForInspection(folder: folder, inventory: inventory)
        let report = session.report
        let retained = await queue.retainedToken()
        XCTAssertEqual(retained, session.token)
        XCTAssertEqual(report.modules.map(\.name), ["main"])
        XCTAssertGreaterThan(report.ownedBytes, 0)
        XCTAssertEqual(report.modules[0].verifiedHashSegments, 0)
        XCTAssertFalse(report.modules[0].importsComplete)
        XCTAssertNotEqual(report.modules[0].warnings, 0)
        await queue.close(token: session.token)
        await queue.close(token: session.token)
        let closed = await queue.retainedToken()
        XCTAssertNil(closed)
        XCTAssertEqual(report, session.report) // Only value fields, no dangling native name.
    }

    func testOldTokenCannotCloseReplacement() async throws {
        try module()
        let queue = InputWorkQueue()
        let inventory = try await queue.inventory(folder: folder)
        let old = try await queue.loadForInspection(folder: folder, inventory: inventory)
        let newer = try await queue.loadForInspection(folder: folder, inventory: inventory)
        XCTAssertNotEqual(old.token, newer.token)
        await queue.close(token: old.token)
        let retained = await queue.retainedToken()
        XCTAssertEqual(retained, newer.token)
        await queue.close(token: newer.token)
    }

    func testFailureInLaterModulePublishesNoPartialSession() async throws {
        try module("rtld")
        try module("main", badHash: true)
        let queue = InputWorkQueue()
        let inventory = try await queue.inventory(folder: folder)
        do {
            _ = try await queue.loadForInspection(folder: folder, inventory: inventory)
            XCTFail("Bad required hash must reject the entire batch")
        } catch { }
        let retained = await queue.retainedToken()
        XCTAssertNil(retained)
    }

    func testInputChangeRejectsLoad() async throws {
        try module()
        let queue = InputWorkQueue()
        let inventory = try await queue.inventory(folder: folder)
        try Data().write(to: folder.appendingPathComponent("main"))
        do {
            _ = try await queue.loadForInspection(folder: folder, inventory: inventory)
            XCTFail("Changed input must fail")
        } catch { }
        let retained = await queue.retainedToken()
        XCTAssertNil(retained)
    }

    func testBudgetIncludesInputAndReportBeforeHugeDecode() async throws {
        // A tiny NSO declares a 96 MiB compressed text segment. Budget admission
        // must reject before allocation/decode, since input/metadata/report also live.
        var bytes = Data(repeating: 0, count: 257)
        bytes.replaceSubrange(0..<4, with: [0x4e, 0x53, 0x4f, 0x30])
        func put(_ offset: Int, _ value: UInt32) {
            for i in 0..<4 { bytes[offset + i] = UInt8(truncatingIfNeeded: value >> (i * 8)) }
        }
        put(12, 1); put(16, 256); put(24, UInt32(InputWorkQueue.maximumWorkingBytes))
        put(36, UInt32(InputWorkQueue.maximumWorkingBytes))
        put(52, UInt32(InputWorkQueue.maximumWorkingBytes)); put(96, 1)
        try bytes.write(to: folder.appendingPathComponent("main"))
        let queue = InputWorkQueue()
        let inventory = try await queue.inventory(folder: folder)
        do {
            _ = try await queue.loadForInspection(folder: folder, inventory: inventory)
            XCTFail("Budget must reject before huge decode")
        } catch LoadedInspectionError.resourceLimit(_) { }
        catch { XCTFail("Expected resource-limit error, got \(error)") }
        let retained = await queue.retainedToken()
        XCTAssertNil(retained)
    }

    func testCancelledQueuedOperationsDoNotReleaseNewSession() async throws {
        try module()
        let queue = InputWorkQueue()
        let inventory = try await queue.inventory(folder: folder)
        let location = folder!
        // Gate each old request before actor entry, cancel it, publish a new session,
        // then let the old request enter. No scheduler timing assumption is needed.
        for kind in 0..<3 {
            let gate = InspectionTestGate()
            let old = Task {
                await gate.wait()
                if kind == 0 { _ = try await queue.inventory(folder: location) }
                else if kind == 1 { _ = try await queue.validate(folder: location, inventory: inventory) }
                else { _ = try await queue.loadForInspection(folder: location, inventory: inventory) }
            }
            await gate.waitUntilStarted()
            old.cancel()
            let newer = try await queue.loadForInspection(folder: location, inventory: inventory)
            await gate.release()
            do { try await old.value; XCTFail("Cancelled old job must not start") }
            catch is CancellationError { }
            catch { XCTFail("Unexpected error: \(error)") }
            let retained = await queue.retainedToken()
            XCTAssertEqual(retained, newer.token)
            await queue.close(token: newer.token)
        }
    }
}

@MainActor
final class LoadedInspectionSessionModelTests: XCTestCase {
    private func inventory() -> InputInventory {
        .init(folderName: "test", modules: [.init(name: "main", byteCount: 256)], hasNPDM: false, warnings: [])
    }
    private func session(_ token: UUID = UUID(), ownedBytes: Int = 1) -> LoadedInspectionSession {
        .init(token: token, report: .init(modules: [], ownedBytes: ownedBytes, reservedReportBytes: 4096))
    }

    func testCancelledSuccessfulLoadClosesUnpublishedToken() async {
        let gate = InspectionTestGate()
        let ledger = ClosedInspectionTokens()
        let result = session()
        let input = inventory()
        let model = SessionModel(inventoryLoader: { _ in input }, inspectionLoader: { _, _ in
            await gate.wait(); return result // Deliberately ignores cancellation to exercise the race.
        }, inspectionCloser: { await ledger.close($0) })
        await model.importFolder(URL(fileURLWithPath: "/owned-input")).value
        let operation = model.loadForInspection()!
        await gate.waitUntilStarted()
        model.cancelImport()
        await gate.release()
        await operation.value
        let closed = await ledger.tokens()
        XCTAssertEqual(closed, [result.token])
        XCTAssertNil(model.loadedInspection)
        XCTAssertFalse(model.isLoading)
    }

    func testLateOldResultDoesNotReplaceNewerReport() async {
        let gate = InspectionTestGate()
        let ledger = ClosedInspectionTokens()
        let oldResult = session(ownedBytes: 1), newResult = session(ownedBytes: 2)
        let input = inventory()
        let model = SessionModel(inventoryLoader: { url in
            if url.lastPathComponent == "new" {
                let closed = await ledger.tokens()
                XCTAssertEqual(closed, [oldResult.token])
            }
            await ledger.enterInventory(url.lastPathComponent)
            return input
        }, inspectionLoader: { url, _ in
            if url.lastPathComponent == "old" { await gate.wait(); return oldResult }
            let closed = await ledger.tokens()
            XCTAssertEqual(closed, [oldResult.token])
            return newResult
        }, inspectionCloser: { await ledger.close($0) })
        await model.importFolder(URL(fileURLWithPath: "/old")).value
        let old = model.loadForInspection()!
        await gate.waitUntilStarted()
        let replacement = model.importFolder(URL(fileURLWithPath: "/new"))
        let entered = await ledger.inventoryEntries()
        XCTAssertEqual(entered, ["old"])
        XCTAssertNil(model.loadedInspection)
        await gate.release()
        await old.value; await replacement.value
        await model.loadForInspection()!.value
        XCTAssertEqual(model.loadedInspection, newResult.report)
        let closed = await ledger.tokens()
        XCTAssertEqual(closed, [oldResult.token])
        await model.closeLoadedInspection()?.value
    }

    func testClearAndBackgroundCloseAcceptedTokens() async {
        for background in [false, true] {
            let ledger = ClosedInspectionTokens()
            let result = session(), input = inventory()
            let model = SessionModel(inventoryLoader: { _ in input }, inspectionLoader: { _, _ in result },
                                     inspectionCloser: { await ledger.close($0) })
            await model.importFolder(URL(fileURLWithPath: "/input")).value
            await model.loadForInspection()!.value
            XCTAssertNotNil(model.loadedInspection)
            if background { model.transition(to: .background) } else { model.clear() }
            await ledger.waitForClose(result.token)
            XCTAssertNil(model.loadedInspection)
            XCTAssertFalse(model.isLoading)
            let closed = await ledger.tokens()
            XCTAssertEqual(closed, [result.token])
        }
    }
}

private actor InspectionTestGate {
    private var blocked: CheckedContinuation<Void, Never>?
    private var started: CheckedContinuation<Void, Never>?
    func wait() async {
        await withCheckedContinuation { continuation in
            blocked = continuation
            started?.resume(); started = nil
        }
    }
    func waitUntilStarted() async {
        if blocked != nil { return }
        await withCheckedContinuation { started = $0 }
    }
    func release() { blocked?.resume(); blocked = nil }
}

private actor ClosedInspectionTokens {
    private var closed: [UUID] = []
    private var entered: [String] = []
    func enterInventory(_ name: String) { entered.append(name) }
    func inventoryEntries() -> [String] { entered }
    private var waiters: [UUID: CheckedContinuation<Void, Never>] = [:]
    func close(_ token: UUID) { closed.append(token); waiters.removeValue(forKey: token)?.resume() }
    func tokens() -> [UUID] { closed }
    func waitForClose(_ token: UUID) async {
        if closed.contains(token) { return }
        await withCheckedContinuation { waiters[token] = $0 }
    }
}
