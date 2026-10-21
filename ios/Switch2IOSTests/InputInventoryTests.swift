import Foundation
import XCTest
@testable import Switch2IOS

final class InputInventoryTests: XCTestCase {
    private var folder: URL!
    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try FileManager.default.removeItem(at: folder) }

    private func writeModule(at root: URL? = nil) throws {
        // Synthetic uncompressed NSO with empty segments; never game data.
        var bytes = Data(repeating: 0, count: 256)
        bytes.replaceSubrange(0..<4, with: [0x4e, 0x53, 0x4f, 0x30])
        try bytes.write(to: (root ?? folder).appendingPathComponent("main"))
    }

    func testSyntheticHeaderInventory() throws {
        try writeModule()
        let result = try InputInventoryReader.read(folder: folder)
        XCTAssertEqual(result.modules.map(\.name), ["main"])
        XCTAssertEqual(result.modules.first?.byteCount, 256)
        XCTAssertFalse(result.hasNPDM)
        XCTAssertFalse(result.warnings.isEmpty)
    }
    func testNestedExeFSInventory() throws {
        let nested = folder.appendingPathComponent("exefs", isDirectory: true)
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        try writeModule(at: nested)
        try Data().write(to: nested.appendingPathComponent("main.npdm"))
        let result = try InputInventoryReader.read(folder: folder)
        XCTAssertTrue(result.hasNPDM) // Presence only, deliberately not NPDM validation.
        XCTAssertEqual(result.modules.count, 1)
    }
    func testPayloadValidationWithoutHashDoesNotClaimHashes() throws {
        try writeModule()
        let input = try InputInventoryReader.read(folder: folder)
        let report = try PayloadValidator.validate(folder: folder, inventory: input)
        XCTAssertEqual(report.modules.count, 1)
        XCTAssertEqual(report.modules[0].verifiedHashSegments, 0)
    }
    func testPayloadHashMismatchIsRejected() throws {
        try writeModule()
        let url = folder.appendingPathComponent("main")
        var bytes = try Data(contentsOf: url)
        bytes[12] = 8 // Require text hash. All-zero digest is not SHA-256 of empty text.
        try bytes.write(to: url)
        let input = try InputInventoryReader.read(folder: folder)
        XCTAssertThrowsError(try PayloadValidator.validate(folder: folder, inventory: input))
    }
    func testPayloadHashFlagIsActuallyVerified() throws {
        try writeModule()
        let url = folder.appendingPathComponent("main")
        var bytes = try Data(contentsOf: url)
        bytes[12] = 8
        let digest: [UInt8] = [0xe3,0xb0,0xc4,0x42,0x98,0xfc,0x1c,0x14,0x9a,0xfb,0xf4,0xc8,0x99,0x6f,0xb9,0x24,
                              0x27,0xae,0x41,0xe4,0x64,0x9b,0x93,0x4c,0xa4,0x95,0x99,0x1b,0x78,0x52,0xb8,0x55]
        bytes.replaceSubrange(160..<192, with: digest)
        try bytes.write(to: url)
        let input = try InputInventoryReader.read(folder: folder)
        let report = try PayloadValidator.validate(folder: folder, inventory: input)
        XCTAssertEqual(report.modules[0].verifiedHashSegments, 1)
    }
    func testChangedModuleSizeIsRejected() throws {
        try writeModule()
        let input = try InputInventoryReader.read(folder: folder)
        try Data().write(to: folder.appendingPathComponent("main"))
        XCTAssertThrowsError(try PayloadValidator.validate(folder: folder, inventory: input))
    }
    func testPayloadFileMemoryBudget() throws {
        try writeModule()
        let handle = try FileHandle(forWritingTo: folder.appendingPathComponent("main"))
        try handle.truncate(atOffset: UInt64(PayloadValidator.maximumFileBytes + 1))
        try handle.close()
        let input = try InputInventoryReader.read(folder: folder)
        XCTAssertThrowsError(try PayloadValidator.validate(folder: folder, inventory: input))
    }
    func testMissingMainFails() { XCTAssertThrowsError(try InputInventoryReader.read(folder: folder)) }
    func testInvalidMagicFails() throws {
        try Data(repeating: 0, count: 256).write(to: folder.appendingPathComponent("main"))
        XCTAssertThrowsError(try InputInventoryReader.read(folder: folder))
    }
    func testTruncatedHeaderFails() throws {
        try Data([0x4e, 0x53, 0x4f, 0x30]).write(to: folder.appendingPathComponent("main"))
        XCTAssertThrowsError(try InputInventoryReader.read(folder: folder))
    }
    func testSymbolicModuleFails() throws {
        let target = folder.appendingPathComponent("other")
        try Data(repeating: 0, count: 256).write(to: target)
        try FileManager.default.createSymbolicLink(at: folder.appendingPathComponent("main"), withDestinationURL: target)
        XCTAssertThrowsError(try InputInventoryReader.read(folder: folder))
    }
    func testSymbolicExeFSFails() throws {
        let nested = folder.appendingPathComponent("other", isDirectory: true)
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: folder.appendingPathComponent("exefs"), withDestinationURL: nested)
        XCTAssertThrowsError(try InputInventoryReader.read(folder: folder))
    }
    func testEntryBudgetFails() throws {
        for index in 0..<129 { try Data().write(to: folder.appendingPathComponent("entry\(index)")) }
        XCTAssertThrowsError(try InputInventoryReader.read(folder: folder))
    }
}

@MainActor
final class SessionModelTests: XCTestCase {
    func testClearResetsState() {
        let model = SessionModel()
        model.reportPickerError(NSError(domain: "test", code: 1))
        XCTAssertNotNil(model.errorMessage)
        model.clear()
        XCTAssertNil(model.errorMessage)
        XCTAssertNil(model.inventory)
        XCTAssertFalse(model.isImporting)
    }
    func testPickerCancellationIsNotError() {
        let model = SessionModel()
        model.reportPickerError(NSError(domain: NSCocoaErrorDomain, code: NSUserCancelledError))
        XCTAssertNil(model.errorMessage)
    }
    func testUnrelatedErrorWithCancellationCodeIsShown() {
        let model = SessionModel()
        model.reportPickerError(NSError(domain: "unrelated", code: NSUserCancelledError))
        XCTAssertNotNil(model.errorMessage)
    }
    func testStaleSuccessfulImportCannotRestoreClearedState() async {
        let gate = InventoryGate()
        let model = SessionModel(inventoryLoader: { _ in try await gate.load() })
        let operation = model.importFolder(URL(fileURLWithPath: "/synthetic"))
        await gate.waitUntilStarted()
        model.clear()
        await gate.finish()
        await operation.value
        XCTAssertNil(model.inventory)
        XCTAssertNil(model.errorMessage)
        XCTAssertFalse(model.isImporting)
    }
    func testReplacedImportCannotOverwriteNewerInput() async {
        let gate = InventoryGate()
        let model = SessionModel(inventoryLoader: { url in
            if url.lastPathComponent == "old" { return try await gate.load() }
            let finished = await gate.hasFinished()
            XCTAssertTrue(finished)
            await gate.enterNewLoader()
            return InputInventory(folderName: "new", modules: [], hasNPDM: false, warnings: [])
        })
        let old = model.importFolder(URL(fileURLWithPath: "/old"))
        await gate.waitUntilStarted()
        let newer = model.importFolder(URL(fileURLWithPath: "/new"))
        let startedNew = await gate.newLoaderEntries()
        XCTAssertEqual(startedNew, 0)
        XCTAssertNil(model.inventory)
        await gate.finish()
        await old.value; await newer.value
        XCTAssertEqual(model.inventory?.folderName, "new")
        XCTAssertFalse(model.isImporting)
    }
    func testBackgroundCancelsPendingImport() {
        let model = SessionModel()
        model.importFolder(URL(fileURLWithPath: "/nonexistent"))
        model.transition(to: .background)
        XCTAssertFalse(model.isImporting)
        XCTAssertFalse(model.isForeground)
    }
}

private actor InventoryGate {
    private var waiting: CheckedContinuation<InputInventory, Error>?
    private var started: CheckedContinuation<Void, Never>?
    private var finished = false
    private var newEntries = 0
    func hasFinished() -> Bool { finished }
    func enterNewLoader() { newEntries += 1 }
    func newLoaderEntries() -> Int { newEntries }
    func load() async throws -> InputInventory {
        try await withCheckedThrowingContinuation { continuation in
            waiting = continuation
            started?.resume()
            started = nil
        }
    }
    func waitUntilStarted() async {
        if waiting != nil { return }
        await withCheckedContinuation { started = $0 }
    }
    func finish() {
        finished = true
        waiting?.resume(returning: InputInventory(folderName: "old", modules: [], hasNPDM: false, warnings: []))
        waiting = nil
    }
}
