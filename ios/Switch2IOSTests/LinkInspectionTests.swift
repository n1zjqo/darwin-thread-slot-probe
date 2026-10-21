import Foundation
import CryptoKit
import XCTest
@testable import Switch2IOS

/// Wholly self-authored data-only inputs. These tests never execute guest code,
/// choose providers, reopen real inputs, or assert that inventory means readiness.
final class LinkInspectionTests: XCTestCase {
    private var folder: URL!

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try FileManager.default.removeItem(at: folder)
    }

    private func write(_ kind: LinkSyntheticNSO.Kind = .relative, name: String = "main") throws {
        try LinkSyntheticNSO.make(kind).write(to: folder.appendingPathComponent(name))
    }

    private func load(_ queue: InputWorkQueue) async throws -> LoadedInspectionSession {
        let inventory = try await queue.inventory(folder: folder)
        return try await queue.loadForInspection(folder: folder, inventory: inventory)
    }

    func testBudgetIncludesPreparedStorageAndReportsWithoutDoubleCountingSources() throws {
        let budget = try LinkInspectionBudget.calculate(sourceOwned: 1000, sourceReport: 8192,
            moduleCount: 2, preparedOwned: 500, preparedReport: 4096, limit: 30000)
        XCTAssertEqual(budget.otherLive, 8192 + 500 + 4096)
        XCTAssertEqual(budget.reportReservation, 3 * 4096)
        XCTAssertEqual(budget.maximumPeak, 30000)
        // C counts source bytes and its own report reserve; otherLive must not.
        XCTAssertEqual(1000 + budget.otherLive + budget.reportReservation, 26076)
        _ = try LinkInspectionBudget.calculate(sourceOwned: 1000, sourceReport: 8192,
            moduleCount: 2, preparedOwned: 500, preparedReport: 4096, limit: 26077)
        XCTAssertThrowsError(try LinkInspectionBudget.calculate(sourceOwned: 1000, sourceReport: 8192,
            moduleCount: 2, preparedOwned: 500, preparedReport: 4096, limit: 26076))
    }

    func testBudgetRejectsNegativeOverflowAndAboveCeilingInputs() throws {
        let cases: [(Int, Int, Int, Int, Int, Int)] = [
            (-1, 0, 1, 0, 0, 20000), (1, -1, 1, 0, 0, 20000),
            (1, 0, 1, -1, 0, 20000), (1, 0, 1, 0, -1, 20000),
            (1, 0, 0, 0, 0, 20000), (1, 0, 17, 0, 0, 20000),
            (1, 0, Int.max, 0, 0, 20000), (Int.max, 0, 1, 0, 0, 20000),
            (1, Int.max, 1, 0, 0, 20000), (1, 0, 1, Int.max, 0, 20000),
            (1, 0, 1, 0, Int.max, 20000), (1, 0, 1, 0, 0, 0),
            (1, 0, 1, 0, 0, -1), (1, 0, 1, 0, 0, InputWorkQueue.maximumWorkingBytes + 1)
        ]
        for (owned, report, count, prepared, preparedReport, limit) in cases {
            XCTAssertThrowsError(try LinkInspectionBudget.calculate(sourceOwned: owned, sourceReport: report,
                moduleCount: count, preparedOwned: prepared, preparedReport: preparedReport, limit: limit))
        }
    }

    func testAllAllowlistedModulesAreIncludedInCallerOrder() async throws {
        for name in InputInventoryReader.moduleNames { try write(name: name) }
        let queue = InputWorkQueue(), source = try await load(queue)
        let result = try await queue.linkInventory(sourceToken: source.token)
        let report = result.report
        XCTAssertEqual(report.moduleCount, InputInventoryReader.moduleNames.count)
        XCTAssertEqual(report.modules.map(\.id), Array(source.report.modules.indices))
        XCTAssertEqual(report.relocationCount, source.report.modules.count)
        XCTAssertEqual(report.symbolCount, source.report.modules.count)
        XCTAssertEqual(report.candidateCount, 0)
        XCTAssertEqual(report.sourceModuleBytes, source.report.ownedBytes)
        XCTAssertEqual(report.otherLiveBytes, source.report.reservedReportBytes)
        XCTAssertEqual(report.reservedReportBytes, (source.report.modules.count + 1) * 4096)
        XCTAssertEqual(report.format, 1)
        XCTAssertEqual(report.targets, 1)
        XCTAssertEqual(report.inventory, 1)
        XCTAssertEqual(report.policy, 0)
        for (index, module) in report.modules.enumerated() {
            XCTAssertEqual(module.originalWarnings, source.report.modules[index].warnings)
            XCTAssertEqual(module.relaCount, 1)
            XCTAssertEqual(module.jmprelCount, 0)
            XCTAssertEqual(module.policy, 0)
        }
        XCTAssertEqual(report.creationPeakBytes, report.sourceModuleBytes + report.otherLiveBytes
                       + report.reservedReportBytes + report.ownedBytes + report.temporaryBytes)
        XCTAssertGreaterThan(report.ownedBytes, 0)
        XCTAssertGreaterThan(report.temporaryBytes, 0)
        await queue.close(token: source.token)
        let closed = await queue.retainedLinkSession()
        XCTAssertNil(closed)
        XCTAssertEqual(report, result.report) // Value copy survives native/source destruction.
    }

    func testGNUValidationPreservesFrozenWarning32AndDefersPolicy() async throws {
        try write(.gnuInventory)
        let queue = InputWorkQueue(), source = try await load(queue)
        XCTAssertEqual(source.report.modules[0].warnings, 32)
        let result = try await queue.linkInventory(sourceToken: source.token)
        let report = result.report, module = try XCTUnwrap(report.modules.first)
        XCTAssertEqual(module.originalWarnings, 32)
        XCTAssertEqual(module.gnuHash, 2)
        XCTAssertEqual(module.format, 1)
        XCTAssertEqual(module.targets, 1)
        XCTAssertEqual(module.inventory, 1)
        XCTAssertEqual(module.policy, 0)
        XCTAssertEqual(module.relaCount, 3)
        XCTAssertEqual(module.jmprelCount, 1)
        XCTAssertEqual(report.relocationCount, 4)
        XCTAssertEqual(report.symbolCount, 3)
        XCTAssertEqual(report.candidateCount, 1) // A unique candidate is still not a selected provider.
        XCTAssertEqual(report.policy, 0)
        let retained = await queue.retainedToken()
        XCTAssertEqual(retained, source.token)
        XCTAssertEqual(source.report.modules[0].warnings, 32)
        // A successful link inventory must not relax the older prepared-image guard.
        do {
            _ = try await queue.prepare(sourceToken: source.token, moduleName: "main", guestBase: 0x1000)
            XCTFail("GNU/import metadata remains unsupported by the prepared-image stage")
        } catch is PreparedInspectionError { }
        let current = await queue.retainedLinkSession(), prepared = await queue.retainedPreparedSession()
        XCTAssertEqual(current, result)
        XCTAssertNil(prepared)
        await queue.close(token: source.token)
    }

    func testUnknownMetadataAndGNUOnlyStayIncompleteWithoutPretendingPolicy() async throws {
        for kind in [LinkSyntheticNSO.Kind.unknownTag, .gnuOnly] {
            try write(kind)
            let queue = InputWorkQueue(), source = try await load(queue)
            let result = try await queue.linkInventory(sourceToken: source.token)
            let module = try XCTUnwrap(result.report.modules.first)
            XCTAssertEqual(result.report.format, 0)
            XCTAssertEqual(result.report.targets, 1)
            XCTAssertEqual(result.report.policy, 0)
            XCTAssertEqual(module.originalWarnings, source.report.modules[0].warnings)
            if kind == .unknownTag { XCTAssertEqual(module.unknownTagCount, 1) }
            else {
                XCTAssertEqual(module.gnuHash, 1)
                XCTAssertEqual(module.inventory, 0)
                XCTAssertEqual(result.report.inventory, 0)
                XCTAssertNotEqual(module.originalWarnings & 32, 0)
            }
            await queue.close(token: source.token)
        }
    }

    func testInventoryUsesAllHeldSourcesWithoutReopeningFiles() async throws {
        try write(.dependency, name: "rtld")
        try write(name: "main")
        try write(.gnuInventory, name: "sdk")
        let queue = InputWorkQueue(), source = try await load(queue)
        // Deliberately replace the backing files after load. This operation must
        // inspect the immutable owned batch, not parse a second copy of any file.
        for name in ["rtld", "main", "sdk"] { try Data().write(to: folder.appendingPathComponent(name)) }
        let result = try await queue.linkInventory(sourceToken: source.token)
        XCTAssertEqual(result.report.moduleCount, 3)
        XCTAssertEqual(result.report.modules.map(\.id), [0, 1, 2])
        XCTAssertEqual(result.report.relocationCount, 6)
        XCTAssertEqual(result.report.symbolCount, 5)
        XCTAssertEqual(result.report.candidateCount, 1)
        XCTAssertEqual(result.report.modules[0].dependencyCount, 1)
        XCTAssertEqual(result.report.modules[2].originalWarnings, 32)
        XCTAssertEqual(result.report.policy, 0)
        await queue.close(token: source.token)
    }

    func testPreparedOwnerSurvivesLinkAndIsChargedWhileOnlyCopiedLinkReportRemains() async throws {
        try write()
        let queue = InputWorkQueue(), source = try await load(queue)
        let prepared = try await queue.prepare(sourceToken: source.token, moduleName: "main", guestBase: 0x1000)
        let link = try await queue.linkInventory(sourceToken: source.token)
        var retainedPrepared = await queue.retainedPreparedSession()
        XCTAssertEqual(retainedPrepared, prepared)
        XCTAssertEqual(link.report.otherLiveBytes, source.report.reservedReportBytes
                       + prepared.report.ownedBytes + prepared.report.reservedReportBytes)
        XCTAssertEqual(link.report.creationPeakBytes, source.report.ownedBytes + link.report.otherLiveBytes
                       + link.report.reservedReportBytes + link.report.ownedBytes + link.report.temporaryBytes)
        let replacement = try await queue.linkInventory(sourceToken: source.token)
        XCTAssertNotEqual(replacement.token, link.token)
        XCTAssertEqual(replacement.report, link.report) // Replacing does not double-charge the old copy.
        await queue.closeLinkInventory(sourceToken: source.token, token: link.token)
        var current = await queue.retainedLinkSession()
        XCTAssertEqual(current, replacement)
        // Preparing after linking charges only the copied link report. A transient
        // native plan cannot remain retained and inflate this preparation peak.
        let next = try await queue.prepare(sourceToken: source.token, moduleName: "main", guestBase: 0x2000)
        XCTAssertEqual(next.report.creationPeakBytes, prepared.report.creationPeakBytes + link.report.reservedReportBytes)
        current = await queue.retainedLinkSession()
        XCTAssertEqual(current, replacement)
        await queue.closeLinkInventory(sourceToken: source.token, token: replacement.token)
        retainedPrepared = await queue.retainedPreparedSession()
        XCTAssertEqual(retainedPrepared, next)
        let retainedSource = await queue.retainedToken()
        XCTAssertEqual(retainedSource, source.token)
        await queue.close(token: source.token)
    }

    func testExactNativePeakSucceedsAndOneByteUnderFailsAtomically() async throws {
        try write()
        let sizing = InputWorkQueue(), measuredSource = try await load(sizing)
        let measured = try await sizing.linkInventory(sourceToken: measuredSource.token)
        let peak = measured.report.creationPeakBytes
        await sizing.close(token: measuredSource.token)
        for limit in [peak, peak - 1] {
            let queue = InputWorkQueue(maximumWorkingBytes: limit), source = try await load(queue)
            if limit == peak {
                let result = try await queue.linkInventory(sourceToken: source.token)
                XCTAssertEqual(result.report.creationPeakBytes, peak)
            } else {
                do {
                    _ = try await queue.linkInventory(sourceToken: source.token)
                    XCTFail("One byte below the complete native ledger must reject")
                } catch LinkInspectionError.resourceLimit { }
                let current = await queue.retainedLinkSession()
                XCTAssertNil(current)
            }
            let retained = await queue.retainedToken()
            XCTAssertEqual(retained, source.token)
            await queue.close(token: source.token)
        }
    }

    func testFailedExplicitReplacementDropsOldLinkButKeepsPreparedAndSource() async throws {
        try write()
        let sizing = InputWorkQueue(), measuredSource = try await load(sizing)
        _ = try await sizing.linkInventory(sourceToken: measuredSource.token)
        let measuredPrepared = try await sizing.prepare(sourceToken: measuredSource.token, moduleName: "main", guestBase: 0x1000)
        let measured = try await sizing.linkInventory(sourceToken: measuredSource.token)
        let limit = measured.report.creationPeakBytes - 1
        XCTAssertLessThanOrEqual(measuredPrepared.report.creationPeakBytes, limit)
        await sizing.close(token: measuredSource.token)
        let queue = InputWorkQueue(maximumWorkingBytes: limit), source = try await load(queue)
        let old = try await queue.linkInventory(sourceToken: source.token)
        let prepared = try await queue.prepare(sourceToken: source.token, moduleName: "main", guestBase: 0x1000)
        do {
            _ = try await queue.linkInventory(sourceToken: source.token)
            XCTFail("The prepared owner/report must remain charged on link replacement")
        } catch LinkInspectionError.resourceLimit { }
        let current = await queue.retainedLinkSession(), heldPrepared = await queue.retainedPreparedSession()
        let retained = await queue.retainedToken()
        XCTAssertNil(current)
        XCTAssertEqual(heldPrepared, prepared)
        XCTAssertEqual(retained, source.token)
        XCTAssertEqual(old.report.policy, 0) // Old value copy remains safe, not actor-retained.
        await queue.close(token: source.token)
    }

    func testUnsupportedRelocationBadGNUAndDuplicateTargetPublishNoPartialLink() async throws {
        for kind in [LinkSyntheticNSO.Kind.unsupportedRelocation, .badGNU, .duplicateTarget] {
            try write()
            try write(kind, name: "sdk")
            let queue = InputWorkQueue(), source = try await load(queue)
            let prepared = try await queue.prepare(sourceToken: source.token, moduleName: "main", guestBase: 0x1000)
            do {
                _ = try await queue.linkInventory(sourceToken: source.token)
                XCTFail("The later malformed module must reject the whole batch: \(kind)")
            } catch LinkInspectionError.native(_) { }
            let current = await queue.retainedLinkSession(), heldPrepared = await queue.retainedPreparedSession()
            let retained = await queue.retainedToken()
            XCTAssertNil(current)
            XCTAssertEqual(heldPrepared, prepared)
            XCTAssertEqual(retained, source.token)
            await queue.close(token: source.token)
        }
    }

    func testStaleSourceAndWrongCloseTokensCannotMutateReplacement() async throws {
        try write()
        let queue = InputWorkQueue(), oldSource = try await load(queue)
        let old = try await queue.linkInventory(sourceToken: oldSource.token)
        let source = try await load(queue)
        let prepared = try await queue.prepare(sourceToken: source.token, moduleName: "main", guestBase: 0x1000)
        let current = try await queue.linkInventory(sourceToken: source.token)
        do {
            _ = try await queue.linkInventory(sourceToken: oldSource.token)
            XCTFail("A stale source request cannot replace a newer link report")
        } catch LinkInspectionError.staleSource { }
        await queue.closeLinkInventory(sourceToken: oldSource.token, token: current.token)
        await queue.closeLinkInventory(sourceToken: source.token, token: old.token)
        await queue.close(token: oldSource.token)
        let heldLink = await queue.retainedLinkSession(), heldPrepared = await queue.retainedPreparedSession()
        XCTAssertEqual(heldLink, current)
        XCTAssertEqual(heldPrepared, prepared)
        await queue.close(token: source.token)
    }

    func testCancelledQueuedLinkRequestCannotDropNewerLinkOrPreparedOwner() async throws {
        try write()
        let queue = InputWorkQueue(), source = try await load(queue), gate = LinkTestGate()
        let old = Task {
            await gate.wait()
            return try await queue.linkInventory(sourceToken: source.token)
        }
        await gate.waitUntilStarted()
        old.cancel()
        let prepared = try await queue.prepare(sourceToken: source.token, moduleName: "main", guestBase: 0x1000)
        let current = try await queue.linkInventory(sourceToken: source.token)
        await gate.release()
        do { _ = try await old.value; XCTFail("Cancellation must be checked before actor state mutation") }
        catch is CancellationError { }
        let heldLink = await queue.retainedLinkSession(), heldPrepared = await queue.retainedPreparedSession()
        XCTAssertEqual(heldLink, current)
        XCTAssertEqual(heldPrepared, prepared)
        await queue.close(token: source.token)
    }

    func testCloseInventoryValidationAndReloadCascadeBothDerivedCleanups() async throws {
        try write()
        let queue = InputWorkQueue()
        for kind in 0..<4 {
            let source = try await load(queue)
            _ = try await queue.prepare(sourceToken: source.token, moduleName: "main", guestBase: 0x1000)
            _ = try await queue.linkInventory(sourceToken: source.token)
            if kind == 0 { await queue.close(token: source.token) }
            else if kind == 1 { _ = try await queue.inventory(folder: folder) }
            else {
                let inventory = try InputInventoryReader.read(folder: folder)
                if kind == 2 { _ = try await queue.validate(folder: folder, inventory: inventory) }
                else { _ = try await queue.loadForInspection(folder: folder, inventory: inventory) }
            }
            let link = await queue.retainedLinkSession(), prepared = await queue.retainedPreparedSession()
            XCTAssertNil(link)
            XCTAssertNil(prepared)
            if let token = await queue.retainedToken() { await queue.close(token: token) }
        }
    }
}

/// NSO envelope and ELF64 metadata assembled directly from zero-filled buffers.
/// Only the format constants and synthetic word "datum" have semantic content.
private enum LinkSyntheticNSO {
    enum Kind { case relative, gnuInventory, gnuOnly, unknownTag, dependency, unsupportedRelocation, badGNU, duplicateTarget }

    static func make(_ kind: Kind = .relative) -> Data {
        func put(_ bytes: inout Data, _ offset: Int, _ value: UInt64, _ width: Int = 4) {
            for i in 0..<width { bytes[offset + i] = UInt8(truncatingIfNeeded: value >> (8 * i)) }
        }
        let hasGNU = kind == .gnuInventory || kind == .gnuOnly || kind == .badGNU
        let symbolCount = hasGNU ? 3 : 1
        var text = Data(repeating: 0, count: 0x100)
        put(&text, 4, 0x40)
        text.replaceSubrange(0x40..<0x44, with: Array("MOD0".utf8))
        put(&text, 0x44, 0x2000 - 0x40)
        put(&text, 0x48, 0x4040 - 0x40)
        put(&text, 0x4c, 0x4060 - 0x40)
        var ro = Data(repeating: 0, count: 0x400)
        let strings: [UInt8] = hasGNU ? [0] + Array("fixture".utf8) + [0] + Array("datum".utf8) + [0]
                                         : [0] + Array("fixture".utf8) + [0]
        ro.replaceSubrange(0x200..<(0x200 + strings.count), with: strings)
        if hasGNU {
            // Null, undefined datum, defined datum. Neither import nor candidate is bound.
            for index in 1...2 {
                let offset = 0x220 + index * 24
                put(&ro, offset, 9)
                put(&ro, offset + 4, 0x11, 1)
                put(&ro, offset + 6, index == 2 ? 1 : 0, 2)
                put(&ro, offset + 8, index == 2 ? 0x4020 : 0, 8)
                put(&ro, offset + 16, index == 2 ? 8 : 0, 8)
            }
        }
        put(&ro, 0x270, 1)
        put(&ro, 0x274, UInt64(symbolCount))
        var tags: [(UInt64, UInt64)] = [(5, 0x2200), (10, UInt64(strings.count)), (6, 0x2220),
            (11, 24), (14, 1)]
        if kind != .gnuOnly { tags.append((4, 0x2270)) }
        if hasGNU {
            var hash: UInt32 = 5381
            for byte in "datum".utf8 { hash = hash &* 33 &+ UInt32(byte) }
            put(&ro, 0x290, 1); put(&ro, 0x294, 1); put(&ro, 0x298, 1); put(&ro, 0x29c, 5)
            let bloom = (UInt64(1) << (hash % 64)) | (UInt64(1) << ((hash >> 5) % 64))
            put(&ro, 0x2a0, bloom, 8); put(&ro, 0x2a8, 1)
            put(&ro, 0x2ac, UInt64(kind == .badGNU ? hash | 1 : hash & ~1))
            put(&ro, 0x2b0, UInt64(hash | 1))
            tags.append((0x6ffffef5, 0x2290))
        }
        var records: [(UInt64, UInt64, UInt64)] = [(0x4000, kind == .unsupportedRelocation ? 999 : 1027, 0x1234)]
        if kind == .duplicateTarget { records.append((0x4000, 1027, 0)) }
        if hasGNU {
            records += [(0x4008, (UInt64(1) << 32) | 257, 7), (0x4010, (UInt64(1) << 32) | 1025, 0)]
        }
        for (index, record) in records.enumerated() {
            let offset = 0x2c0 + index * 24
            put(&ro, offset, record.0, 8); put(&ro, offset + 8, record.1, 8); put(&ro, offset + 16, record.2, 8)
        }
        tags += [(7, 0x22c0), (8, UInt64(records.count * 24)), (9, 24)]
        if hasGNU {
            put(&ro, 0x310, 0x4018, 8)
            put(&ro, 0x318, (UInt64(1) << 32) | 1026, 8)
            put(&ro, 0x320, UInt64(1) << 63, 8)
            tags += [(23, 0x2310), (2, 24), (20, 7)]
        }
        if kind == .unknownTag { tags.append((0x60000000, UInt64.max)) }
        if kind == .dependency { tags.append((1, 1)) }
        for (index, tag) in tags.enumerated() {
            put(&ro, index * 16, tag.0, 8); put(&ro, index * 16 + 8, tag.1, 8)
        }
        let parts = [text, ro, Data(repeating: 0, count: 0x40)]
        var bytes = Data(repeating: 0, count: 256)
        bytes.replaceSubrange(0..<4, with: Array("NSO0".utf8))
        put(&bytes, 12, 0x38); put(&bytes, 0x3c, 0x20)
        put(&bytes, 0x90, 0x200); put(&bytes, 0x94, UInt64(strings.count))
        put(&bytes, 0x98, 0x220); put(&bytes, 0x9c, UInt64(symbolCount * 24))
        for (index, part) in parts.enumerated() {
            put(&bytes, 0x10 + index * 16, UInt64(bytes.count))
            put(&bytes, 0x14 + index * 16, UInt64(index * 0x2000))
            put(&bytes, 0x18 + index * 16, UInt64(part.count))
            put(&bytes, 0x60 + index * 4, UInt64(part.count))
            bytes.replaceSubrange((0xa0 + index * 32)..<(0xc0 + index * 32), with: Array(SHA256.hash(data: part)))
            bytes.append(part)
        }
        return bytes
    }
}

@MainActor
final class LinkInspectionSessionModelTests: XCTestCase {
    private func inventory() -> InputInventory {
        .init(folderName: "synthetic", modules: [.init(name: "main", byteCount: 1600)], hasNPDM: false, warnings: [])
    }

    private func source() -> LoadedInspectionSession {
        let module = LoadedInspectionReport.Module(name: "main", decodedBytes: 1344, ownedBytes: 2048,
            verifiedHashSegments: 3, dependencyCount: 0, symbolCount: 1, importCount: 0, exportCount: 0,
            warnings: 0, dependenciesComplete: true, importsComplete: true)
        return .init(token: UUID(), report: .init(modules: [module], ownedBytes: 2048, reservedReportBytes: 4096))
    }

    private func link(_ source: UUID, relocations: Int = 1) -> LinkInspectionSession {
        let module = LinkInspectionReport.Module(id: 0, format: 1, targets: 1, inventory: 1, policy: 0,
            gnuHash: 0, originalWarnings: 0, relaCount: relocations, jmprelCount: 0,
            symbolCount: 1, dependencyCount: 0, unknownTagCount: 0)
        return .init(sourceToken: source, token: UUID(), report: .init(modules: [module],
            format: 1, targets: 1, inventory: 1, policy: 0, moduleCount: 1, relocationCount: relocations,
            candidateCount: 0, symbolCount: 1, sourceModuleBytes: 2048, ownedBytes: 512,
            temporaryBytes: 8, reservedReportBytes: 8192, otherLiveBytes: 4096,
            creationPeakBytes: 14856, nameWork: 0))
    }

    private func prepared(_ source: UUID, base: UInt64 = 0x1000) -> PreparedInspectionSession {
        .init(sourceToken: source, token: UUID(), report: .init(moduleName: "main", guestBase: base,
            imageBytes: 1376, ownedBytes: 1700, temporaryBytes: 24, creationPeakBytes: 11964,
            reservedReportBytes: 4096, relocationCount: 1, relativeCount: 1, absoluteCount: 0, hasInitializer: false))
    }

    func testExplicitActionRequiredAndLinkCancellationOnlyClosesLink() async {
        let input = inventory(), source = source(), result = link(source.token), prepared = prepared(source.token)
        let ledger = LinkCloseLedger(), calls = LinkCallCounter()
        let model = SessionModel(inventoryLoader: { _ in input }, inspectionLoader: { _, _ in source },
            inspectionCloser: { await ledger.source($0) }, preparationLoader: { _, _, _ in prepared },
            preparationCloser: { await ledger.prepared($0, $1) }, linkInventoryLoader: { token in
                XCTAssertEqual(token, source.token)
                _ = await calls.next()
                return result
            }, linkInventoryCloser: { await ledger.link($0, $1) })
        XCTAssertNil(model.inspectBatchLinks())
        await model.importFolder(URL(fileURLWithPath: "/synthetic")).value
        await model.loadForInspection()!.value
        XCTAssertNil(model.linkInspection)
        XCTAssertFalse(model.isLinking)
        var count = await calls.count()
        XCTAssertEqual(count, 0)
        await model.prepareSelectedModule("main", baseText: "0x1000")!.value
        await model.inspectBatchLinks()!.value
        count = await calls.count()
        XCTAssertEqual(count, 1)
        XCTAssertEqual(model.linkInspection, result.report)
        XCTAssertEqual(model.preparedInspection, prepared.report)
        await model.cancelLinkInventory()?.value
        XCTAssertNil(model.linkInspection)
        XCTAssertFalse(model.isLinking)
        XCTAssertEqual(model.loadedInspection, source.report)
        XCTAssertEqual(model.preparedInspection, prepared.report)
        let events = await ledger.events()
        XCTAssertEqual(events, [.link(source.token, result.token)])
        await model.closeLoadedInspection()?.value
    }

    func testCancelledLateSuccessIsClosedWithoutLosingSourceOrPreparedReport() async {
        let gate = LinkTestGate(), ledger = LinkCloseLedger()
        let input = inventory(), source = source(), result = link(source.token), prepared = prepared(source.token)
        let model = SessionModel(inventoryLoader: { _ in input }, inspectionLoader: { _, _ in source },
            inspectionCloser: { await ledger.source($0) }, preparationLoader: { _, _, _ in prepared },
            preparationCloser: { await ledger.prepared($0, $1) },
            linkInventoryLoader: { _ in await gate.wait(); return result },
            linkInventoryCloser: { await ledger.link($0, $1) })
        await model.importFolder(URL(fileURLWithPath: "/synthetic")).value
        await model.loadForInspection()!.value
        await model.prepareSelectedModule("main", baseText: "0x1000")!.value
        let operation = model.inspectBatchLinks()!
        await gate.waitUntilStarted()
        XCTAssertTrue(model.isLinking)
        model.cancelLinkInventory()
        await gate.release(); await operation.value
        XCTAssertNil(model.linkInspection)
        XCTAssertFalse(model.isLinking)
        XCTAssertNil(model.errorMessage)
        XCTAssertEqual(model.loadedInspection, source.report)
        XCTAssertEqual(model.preparedInspection, prepared.report)
        let events = await ledger.events()
        XCTAssertEqual(events, [.link(source.token, result.token)])
        await model.closeLoadedInspection()?.value
    }

    func testLateOlderSuccessCannotReplaceNewReportForSameSource() async {
        let gate = LinkTestGate(), ledger = LinkCloseLedger(), calls = LinkCallCounter()
        let input = inventory(), source = source(), oldResult = link(source.token), newResult = link(source.token, relocations: 2)
        let model = SessionModel(inventoryLoader: { _ in input }, inspectionLoader: { _, _ in source },
            inspectionCloser: { await ledger.source($0) }, linkInventoryLoader: { _ in
                if await calls.next() == 1 { await gate.wait(); return oldResult }
                let closed = await ledger.events()
                XCTAssertTrue(closed.contains(.link(source.token, oldResult.token)))
                return newResult
            }, linkInventoryCloser: { await ledger.link($0, $1) })
        await model.importFolder(URL(fileURLWithPath: "/synthetic")).value
        await model.loadForInspection()!.value
        let old = model.inspectBatchLinks()!
        await gate.waitUntilStarted()
        let newer = model.inspectBatchLinks()!
        let entered = await calls.count()
        XCTAssertEqual(entered, 1)
        XCTAssertNil(model.linkInspection)
        await gate.release(); await old.value; await newer.value
        XCTAssertEqual(model.linkInspection, newResult.report)
        XCTAssertFalse(model.isLinking)
        XCTAssertNil(model.errorMessage)
        let events = await ledger.events()
        XCTAssertEqual(events, [.link(source.token, oldResult.token)])
        await model.closeLoadedInspection()?.value
    }

    func testLateOlderFailureCannotOverwriteNewSuccess() async {
        let gate = LinkTestGate(), ledger = LinkCloseLedger(), calls = LinkCallCounter()
        let input = inventory(), source = source(), result = link(source.token)
        let model = SessionModel(inventoryLoader: { _ in input }, inspectionLoader: { _, _ in source },
            inspectionCloser: { await ledger.source($0) }, linkInventoryLoader: { _ in
                if await calls.next() == 1 { await gate.wait(); throw LinkInspectionError.resourceLimit }
                return result
            }, linkInventoryCloser: { await ledger.link($0, $1) })
        await model.importFolder(URL(fileURLWithPath: "/synthetic")).value
        await model.loadForInspection()!.value
        let old = model.inspectBatchLinks()!
        await gate.waitUntilStarted()
        let newer = model.inspectBatchLinks()!
        let entered = await calls.count()
        XCTAssertEqual(entered, 1)
        XCTAssertNil(model.linkInspection)
        await gate.release(); await old.value; await newer.value
        XCTAssertEqual(model.linkInspection, result.report)
        XCTAssertNil(model.errorMessage)
        XCTAssertFalse(model.isLinking)
        let events = await ledger.events()
        XCTAssertTrue(events.isEmpty)
        await model.closeLoadedInspection()?.value
    }

    func testSourceReplacementRejectsLateLinkWithoutClosingNewSource() async {
        let gate = LinkTestGate(), ledger = LinkCloseLedger()
        let input = inventory(), oldSource = source(), newSource = source()
        let oldResult = link(oldSource.token), newResult = link(newSource.token, relocations: 2)
        let model = SessionModel(inventoryLoader: { url in
            if url.lastPathComponent == "new" {
                let closed = await ledger.events()
                XCTAssertEqual(closed, [.link(oldSource.token, oldResult.token), .source(oldSource.token)])
            }
            return input
        }, inspectionLoader: { url, _ in
            url.lastPathComponent == "old" ? oldSource : newSource
        }, inspectionCloser: { await ledger.source($0) }, linkInventoryLoader: { token in
            if token == oldSource.token { await gate.wait(); return oldResult }
            return newResult
        }, linkInventoryCloser: { await ledger.link($0, $1) })
        await model.importFolder(URL(fileURLWithPath: "/old")).value
        await model.loadForInspection()!.value
        let old = model.inspectBatchLinks()!
        await gate.waitUntilStarted()
        let replacement = model.importFolder(URL(fileURLWithPath: "/new"))
        let beforeRelease = await ledger.events()
        XCTAssertTrue(beforeRelease.isEmpty)
        XCTAssertNil(model.loadedInspection)
        await gate.release(); await old.value; await replacement.value
        await model.loadForInspection()!.value
        await model.inspectBatchLinks()!.value
        XCTAssertEqual(model.loadedInspection, newSource.report)
        XCTAssertEqual(model.linkInspection, newResult.report)
        XCTAssertNil(model.errorMessage)
        let events = await ledger.events()
        XCTAssertTrue(events.contains(.link(oldSource.token, oldResult.token)))
        XCTAssertFalse(events.contains(.source(newSource.token)))
        XCTAssertFalse(events.contains(.link(newSource.token, newResult.token)))
        await model.closeLoadedInspection()?.value
    }

    func testWrongSourceProviderIsClosedAndCannotPublish() async {
        let input = inventory(), source = source(), wrong = link(UUID()), ledger = LinkCloseLedger()
        let model = SessionModel(inventoryLoader: { _ in input }, inspectionLoader: { _, _ in source },
            inspectionCloser: { await ledger.source($0) }, linkInventoryLoader: { _ in wrong },
            linkInventoryCloser: { await ledger.link($0, $1) })
        await model.importFolder(URL(fileURLWithPath: "/synthetic")).value
        await model.loadForInspection()!.value
        await model.inspectBatchLinks()!.value
        XCTAssertNil(model.linkInspection)
        XCTAssertFalse(model.isLinking)
        XCTAssertNotNil(model.errorMessage)
        XCTAssertEqual(model.loadedInspection, source.report)
        let events = await ledger.events()
        XCTAssertEqual(events, [.link(wrong.sourceToken, wrong.token)])
        await model.closeLoadedInspection()?.value
    }

    func testWrongSourceCleanupAwaitCannotSetErrorOnNewGeneration() async {
        let gate = LinkTestGate(), ledger = LinkCloseLedger(), calls = LinkCallCounter()
        let input = inventory(), source = source(), wrong = link(UUID()), good = link(source.token, relocations: 2)
        let model = SessionModel(inventoryLoader: { _ in input }, inspectionLoader: { _, _ in source },
            inspectionCloser: { await ledger.source($0) }, linkInventoryLoader: { _ in
                if await calls.next() == 1 { return wrong }
                let closed = await ledger.events()
                XCTAssertTrue(closed.contains(.link(wrong.sourceToken, wrong.token)))
                return good
            }, linkInventoryCloser: { source, token in
                if token == wrong.token { await gate.wait() }
                await ledger.link(source, token)
            })
        await model.importFolder(URL(fileURLWithPath: "/synthetic")).value
        await model.loadForInspection()!.value
        let old = model.inspectBatchLinks()!
        await gate.waitUntilStarted()
        let newer = model.inspectBatchLinks()!
        let entered = await calls.count()
        XCTAssertEqual(entered, 1)
        XCTAssertNil(model.linkInspection)
        await gate.release(); await old.value; await newer.value
        XCTAssertEqual(model.linkInspection, good.report)
        XCTAssertEqual(model.loadedInspection, source.report)
        XCTAssertFalse(model.isLinking)
        XCTAssertNil(model.errorMessage)
        let events = await ledger.events()
        XCTAssertEqual(events, [.link(wrong.sourceToken, wrong.token)])
        await model.closeLoadedInspection()?.value
    }

    func testFailedReplacementClosesOldLinkAndPreservesPreparedAndSource() async {
        let input = inventory(), source = source(), result = link(source.token), prepared = prepared(source.token)
        let ledger = LinkCloseLedger(), calls = LinkCallCounter()
        let model = SessionModel(inventoryLoader: { _ in input }, inspectionLoader: { _, _ in source },
            inspectionCloser: { await ledger.source($0) }, preparationLoader: { _, _, _ in prepared },
            preparationCloser: { await ledger.prepared($0, $1) }, linkInventoryLoader: { _ in
                if await calls.next() == 1 { return result }
                throw LinkInspectionError.resourceLimit
            }, linkInventoryCloser: { await ledger.link($0, $1) })
        await model.importFolder(URL(fileURLWithPath: "/synthetic")).value
        await model.loadForInspection()!.value
        await model.prepareSelectedModule("main", baseText: "0x1000")!.value
        await model.inspectBatchLinks()!.value
        await model.inspectBatchLinks()!.value
        await ledger.waitForLink(result.token)
        XCTAssertNil(model.linkInspection)
        XCTAssertFalse(model.isLinking)
        XCTAssertNotNil(model.errorMessage)
        XCTAssertEqual(model.loadedInspection, source.report)
        XCTAssertEqual(model.preparedInspection, prepared.report)
        let events = await ledger.events()
        XCTAssertEqual(events, [.link(source.token, result.token)])
        await model.closeLoadedInspection()?.value
    }

    func testLinkThenPreparationWaitsForDeliveryOrCancelledLateCleanup() async {
        for cancel in [false, true] {
            let gate = LinkTestGate(), cleanupGate = LinkTestGate(), ledger = LinkCloseLedger()
            let input = inventory(), source = source(), result = link(source.token), prepared = prepared(source.token)
            let model = SessionModel(inventoryLoader: { _ in input }, inspectionLoader: { _, _ in source },
                inspectionCloser: { await ledger.source($0) }, preparationLoader: { _, _, _ in
                    if cancel {
                        let closed = await ledger.events()
                        XCTAssertTrue(closed.contains(.link(source.token, result.token)))
                    }
                    await ledger.step("prepare-start")
                    return prepared
                }, preparationCloser: { await ledger.prepared($0, $1) }, linkInventoryLoader: { _ in
                    await ledger.step("link-start")
                    await gate.wait()
                    await ledger.step("link-return")
                    return result
                }, linkInventoryCloser: { source, token in
                    if cancel { await cleanupGate.wait() }
                    await ledger.link(source, token)
                })
            await model.importFolder(URL(fileURLWithPath: "/synthetic")).value
            await model.loadForInspection()!.value
            let linking = model.inspectBatchLinks()!
            await gate.waitUntilStarted()
            if cancel { model.cancelLinkInventory() }
            let preparing = model.prepareSelectedModule("main", baseText: "0x1000")!
            let blocked = await ledger.events()
            XCTAssertEqual(blocked, [.step("link-start")])
            XCTAssertTrue(model.isPreparing)
            await gate.release()
            if cancel {
                await cleanupGate.waitUntilStarted()
                let duringCleanup = await ledger.events()
                XCTAssertEqual(duringCleanup, [.step("link-start"), .step("link-return")])
                await cleanupGate.release()
            }
            await linking.value; await preparing.value
            let events = await ledger.events()
            var expected: [LinkCloseLedger.Event] = [.step("link-start"), .step("link-return")]
            if cancel { expected.append(.link(source.token, result.token)) }
            expected.append(.step("prepare-start"))
            XCTAssertEqual(events, expected)
            XCTAssertEqual(model.linkInspection, cancel ? nil : result.report)
            XCTAssertEqual(model.preparedInspection, prepared.report)
            XCTAssertEqual(model.loadedInspection, source.report)
            await model.closeLoadedInspection()?.value
        }
    }

    func testPreparationThenLinkWaitsForDeliveryOrCancelledLateCleanup() async {
        for cancel in [false, true] {
            let gate = LinkTestGate(), ledger = LinkCloseLedger()
            let input = inventory(), source = source(), result = link(source.token), prepared = prepared(source.token)
            let model = SessionModel(inventoryLoader: { _ in input }, inspectionLoader: { _, _ in source },
                inspectionCloser: { await ledger.source($0) }, preparationLoader: { _, _, _ in
                    await ledger.step("prepare-start")
                    await gate.wait()
                    await ledger.step("prepare-return")
                    return prepared
                }, preparationCloser: { await ledger.prepared($0, $1) }, linkInventoryLoader: { _ in
                    if cancel {
                        let closed = await ledger.events()
                        XCTAssertTrue(closed.contains(.prepared(source.token, prepared.token)))
                    }
                    await ledger.step("link-start")
                    return result
                }, linkInventoryCloser: { await ledger.link($0, $1) })
            await model.importFolder(URL(fileURLWithPath: "/synthetic")).value
            await model.loadForInspection()!.value
            let preparing = model.prepareSelectedModule("main", baseText: "0x1000")!
            await gate.waitUntilStarted()
            if cancel { model.cancelPreparation() }
            let linking = model.inspectBatchLinks()!
            let blocked = await ledger.events()
            XCTAssertEqual(blocked, [.step("prepare-start")])
            XCTAssertTrue(model.isLinking)
            await gate.release(); await preparing.value; await linking.value
            let events = await ledger.events()
            var expected: [LinkCloseLedger.Event] = [.step("prepare-start"), .step("prepare-return")]
            if cancel { expected.append(.prepared(source.token, prepared.token)) }
            expected.append(.step("link-start"))
            XCTAssertEqual(events, expected)
            XCTAssertEqual(model.preparedInspection, cancel ? nil : prepared.report)
            XCTAssertEqual(model.linkInspection, result.report)
            XCTAssertEqual(model.loadedInspection, source.report)
            await model.closeLoadedInspection()?.value
        }
    }

    func testCancelledQueuedPreparationNeverEntersLoaderAfterLinkBarrier() async {
        let gate = LinkTestGate(), ledger = LinkCloseLedger(), calls = LinkCallCounter()
        let input = inventory(), source = source(), oldResult = link(source.token), newResult = link(source.token, relocations: 2)
        let unusedPrepared = prepared(source.token)
        let model = SessionModel(inventoryLoader: { _ in input }, inspectionLoader: { _, _ in source },
            inspectionCloser: { await ledger.source($0) }, preparationLoader: { _, _, _ in
                await ledger.step("unexpected-prepare")
                return unusedPrepared
            }, preparationCloser: { await ledger.prepared($0, $1) }, linkInventoryLoader: { _ in
                if await calls.next() == 1 {
                    await ledger.step("old-link-start")
                    await gate.wait()
                    return oldResult
                }
                await ledger.step("new-link-start")
                return newResult
            }, linkInventoryCloser: { await ledger.link($0, $1) })
        await model.importFolder(URL(fileURLWithPath: "/synthetic")).value
        await model.loadForInspection()!.value
        let old = model.inspectBatchLinks()!
        await gate.waitUntilStarted()
        let skipped = model.prepareSelectedModule("main", baseText: "0x1000")!
        model.cancelPreparation()
        let newer = model.inspectBatchLinks()!
        let blocked = await ledger.events()
        XCTAssertEqual(blocked, [.step("old-link-start")])
        await gate.release(); await old.value; await skipped.value; await newer.value
        let events = await ledger.events()
        XCTAssertEqual(events, [.step("old-link-start"), .link(source.token, oldResult.token), .step("new-link-start")])
        XCTAssertNil(model.preparedInspection)
        XCTAssertFalse(model.isPreparing)
        XCTAssertEqual(model.linkInspection, newResult.report)
        await model.closeLoadedInspection()?.value
    }

    func testCancelledQueuedLinkNeverEntersLoaderAfterPreparationBarrier() async {
        let gate = LinkTestGate(), ledger = LinkCloseLedger()
        let input = inventory(), source = source(), result = link(source.token)
        let oldPrepared = prepared(source.token), newPrepared = prepared(source.token, base: 0x2000)
        let model = SessionModel(inventoryLoader: { _ in input }, inspectionLoader: { _, _ in source },
            inspectionCloser: { await ledger.source($0) }, preparationLoader: { _, _, base in
                if base == 0x1000 {
                    await ledger.step("old-prepare-start")
                    await gate.wait()
                    return oldPrepared
                }
                await ledger.step("new-prepare-start")
                return newPrepared
            }, preparationCloser: { await ledger.prepared($0, $1) }, linkInventoryLoader: { _ in
                await ledger.step("unexpected-link")
                return result
            }, linkInventoryCloser: { await ledger.link($0, $1) })
        await model.importFolder(URL(fileURLWithPath: "/synthetic")).value
        await model.loadForInspection()!.value
        let old = model.prepareSelectedModule("main", baseText: "0x1000")!
        await gate.waitUntilStarted()
        let skipped = model.inspectBatchLinks()!
        model.cancelLinkInventory()
        let newer = model.prepareSelectedModule("main", baseText: "0x2000")!
        let blocked = await ledger.events()
        XCTAssertEqual(blocked, [.step("old-prepare-start")])
        await gate.release(); await old.value; await skipped.value; await newer.value
        let events = await ledger.events()
        XCTAssertEqual(events, [.step("old-prepare-start"), .prepared(source.token, oldPrepared.token), .step("new-prepare-start")])
        XCTAssertNil(model.linkInspection)
        XCTAssertFalse(model.isLinking)
        XCTAssertEqual(model.preparedInspection, newPrepared.report)
        await model.closeLoadedInspection()?.value
    }

    func testDeallocationClosesLateUnpublishedSuccessBeforeSource() async {
        let gate = LinkTestGate(), ledger = LinkCloseLedger()
        let input = inventory(), source = source(), result = link(source.token)
        var model: SessionModel? = SessionModel(inventoryLoader: { _ in input }, inspectionLoader: { _, _ in source },
            inspectionCloser: { await ledger.source($0) }, linkInventoryLoader: { _ in await gate.wait(); return result },
            linkInventoryCloser: { await ledger.link($0, $1) })
        await model!.importFolder(URL(fileURLWithPath: "/synthetic")).value
        await model!.loadForInspection()!.value
        let operation = model!.inspectBatchLinks()!
        await gate.waitUntilStarted()
        weak var weakModel = model
        model = nil
        XCTAssertNil(weakModel)
        let beforeRelease = await ledger.events()
        XCTAssertTrue(beforeRelease.isEmpty)
        await gate.release(); await operation.value
        await ledger.waitForSource(source.token)
        let events = await ledger.events()
        XCTAssertEqual(events, [.link(source.token, result.token), .source(source.token)])
    }

    func testDeallocationClosesAcceptedDerivedReportsBeforeSource() async {
        let ledger = LinkCloseLedger(), input = inventory(), source = source()
        let result = link(source.token), prepared = prepared(source.token)
        var model: SessionModel? = SessionModel(inventoryLoader: { _ in input }, inspectionLoader: { _, _ in source },
            inspectionCloser: { await ledger.source($0) }, preparationLoader: { _, _, _ in prepared },
            preparationCloser: { await ledger.prepared($0, $1) }, linkInventoryLoader: { _ in result },
            linkInventoryCloser: { await ledger.link($0, $1) })
        await model!.importFolder(URL(fileURLWithPath: "/synthetic")).value
        await model!.loadForInspection()!.value
        await model!.prepareSelectedModule("main", baseText: "0x1000")!.value
        await model!.inspectBatchLinks()!.value
        weak var weakModel = model
        model = nil
        XCTAssertNil(weakModel)
        await ledger.waitForSource(source.token)
        let events = await ledger.events()
        XCTAssertEqual(events.count, 3)
        XCTAssertEqual(events.last, .source(source.token))
        XCTAssertTrue(events.contains(.link(source.token, result.token)))
        XCTAssertTrue(events.contains(.prepared(source.token, prepared.token)))
    }

    func testCloseClearAndBackgroundReleaseAcceptedDerivedReportsBeforeSource() async {
        for kind in 0..<3 {
            let ledger = LinkCloseLedger(), input = inventory(), source = source()
            let result = link(source.token), prepared = prepared(source.token)
            let model = SessionModel(inventoryLoader: { _ in input }, inspectionLoader: { _, _ in source },
                inspectionCloser: { await ledger.source($0) }, preparationLoader: { _, _, _ in prepared },
                preparationCloser: { await ledger.prepared($0, $1) }, linkInventoryLoader: { _ in result },
                linkInventoryCloser: { await ledger.link($0, $1) })
            await model.importFolder(URL(fileURLWithPath: "/synthetic")).value
            await model.loadForInspection()!.value
            await model.prepareSelectedModule("main", baseText: "0x1000")!.value
            await model.inspectBatchLinks()!.value
            if kind == 0 { await model.closeLoadedInspection()?.value }
            else if kind == 1 { model.clear() }
            else { model.transition(to: .background) }
            await ledger.waitForSource(source.token)
            XCTAssertNil(model.loadedInspection)
            XCTAssertNil(model.preparedInspection)
            XCTAssertNil(model.linkInspection)
            XCTAssertFalse(model.isLinking)
            XCTAssertFalse(model.isPreparing)
            let events = await ledger.events()
            XCTAssertEqual(events.count, 3)
            XCTAssertEqual(events.last, .source(source.token))
            XCTAssertTrue(events.contains(.link(source.token, result.token)))
            XCTAssertTrue(events.contains(.prepared(source.token, prepared.token)))
        }
    }

    func testCloseClearAndBackgroundAlsoRejectInFlightLateSuccess() async {
        for kind in 0..<3 {
            let gate = LinkTestGate(), ledger = LinkCloseLedger(), input = inventory(), source = source()
            let result = link(source.token)
            let model = SessionModel(inventoryLoader: { _ in input }, inspectionLoader: { _, _ in source },
                inspectionCloser: { await ledger.source($0) }, linkInventoryLoader: { _ in await gate.wait(); return result },
                linkInventoryCloser: { await ledger.link($0, $1) })
            await model.importFolder(URL(fileURLWithPath: "/synthetic")).value
            await model.loadForInspection()!.value
            let operation = model.inspectBatchLinks()!
            await gate.waitUntilStarted()
            let closing: Task<Void, Never>?
            if kind == 0 { closing = model.closeLoadedInspection() }
            else {
                closing = nil
                if kind == 1 { model.clear() }
                else { model.transition(to: .background) }
            }
            let beforeRelease = await ledger.events()
            XCTAssertTrue(beforeRelease.isEmpty)
            XCTAssertNil(model.linkInspection)
            XCTAssertFalse(model.isLinking)
            await gate.release(); await operation.value; await closing?.value
            await ledger.waitForSource(source.token)
            XCTAssertNil(model.loadedInspection)
            XCTAssertNil(model.linkInspection)
            XCTAssertFalse(model.isLinking)
            XCTAssertNil(model.errorMessage)
            let events = await ledger.events()
            XCTAssertEqual(events, [.link(source.token, result.token), .source(source.token)])
        }
    }
}

private actor LinkTestGate {
    private var blocked: CheckedContinuation<Void, Never>?
    private var started: CheckedContinuation<Void, Never>?
    func wait() async { await withCheckedContinuation { blocked = $0; started?.resume(); started = nil } }
    func waitUntilStarted() async { if blocked != nil { return }; await withCheckedContinuation { started = $0 } }
    func release() { blocked?.resume(); blocked = nil }
}

private actor LinkCallCounter {
    private var value = 0
    func next() -> Int { value += 1; return value }
    func count() -> Int { value }
}

private actor LinkCloseLedger {
    enum Event: Equatable { case link(UUID, UUID), prepared(UUID, UUID), source(UUID), step(String) }
    private var closed: [Event] = []
    private var sourceWaiters: [UUID: CheckedContinuation<Void, Never>] = [:]
    private var linkWaiters: [UUID: CheckedContinuation<Void, Never>] = [:]
    func link(_ source: UUID, _ token: UUID) {
        closed.append(.link(source, token))
        linkWaiters.removeValue(forKey: token)?.resume()
    }
    func prepared(_ source: UUID, _ token: UUID) { closed.append(.prepared(source, token)) }
    func source(_ token: UUID) {
        closed.append(.source(token))
        sourceWaiters.removeValue(forKey: token)?.resume()
    }
    func step(_ label: String) { closed.append(.step(label)) }
    func events() -> [Event] { closed }
    func waitForSource(_ token: UUID) async {
        if closed.contains(.source(token)) { return }
        await withCheckedContinuation { sourceWaiters[token] = $0 }
    }
    func waitForLink(_ token: UUID) async {
        if closed.contains(where: { if case .link(_, let value) = $0 { return value == token }; return false }) { return }
        await withCheckedContinuation { linkWaiters[token] = $0 }
    }
}
