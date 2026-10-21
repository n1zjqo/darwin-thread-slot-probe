import Foundation
import SwiftUI

/// Owns UI generations and opaque inspection tokens, never native pointers or a launch API.
@MainActor
final class SessionModel: ObservableObject {
    typealias InventoryLoader = @Sendable (URL) async throws -> InputInventory
    typealias InspectionLoader = @Sendable (URL, InputInventory) async throws -> LoadedInspectionSession
    typealias InspectionCloser = @Sendable (UUID) async -> Void
    typealias PreparationLoader = @Sendable (UUID, String, UInt64) async throws -> PreparedInspectionSession
    typealias PreparationCloser = @Sendable (UUID, UUID) async -> Void
    typealias LinkInventoryLoader = @Sendable (UUID) async throws -> LinkInspectionSession
    typealias LinkInventoryCloser = @Sendable (UUID, UUID) async -> Void
    @Published private(set) var inventory: InputInventory?
    @Published private(set) var validation: PayloadValidationReport?
    @Published private(set) var loadedInspection: LoadedInspectionReport?
    @Published private(set) var preparedInspection: PreparedInspectionReport?
    @Published private(set) var linkInspection: LinkInspectionReport?
    @Published private(set) var isLinking = false
    @Published private(set) var isPreparing = false
    @Published private(set) var isImporting = false
    @Published private(set) var isValidating = false
    @Published private(set) var isLoading = false
    @Published private(set) var errorMessage: String?
    @Published private(set) var isForeground = true
    // Serializes worker completion AND numeric-result delivery/cleanup. Native
    // actor isolation alone does not cover a detached result awaiting MainActor.
    // This task carries no report/pointer; completed closures release their locals.
    private var workBarrier: Task<Void, Never>?
    private var operationTask: Task<Void, Never>?
    private var generation = UUID()
    private var preparationTask: Task<Void, Never>?
    private var preparationGeneration = UUID()
    private var preparedIdentity: (source: UUID, token: UUID)?
    private var linkTask: Task<Void, Never>?
    private var linkGeneration = UUID()
    private var linkIdentity: (source: UUID, token: UUID)?
    private var selectedFolder: URL?
    private var loadedToken: UUID?
    private let inventoryLoader: InventoryLoader
    private let inspectionLoader: InspectionLoader
    private let inspectionCloser: InspectionCloser
    private let preparationLoader: PreparationLoader
    private let preparationCloser: PreparationCloser
    private let linkInventoryLoader: LinkInventoryLoader
    private let linkInventoryCloser: LinkInventoryCloser

    init(inventoryLoader: @escaping InventoryLoader = { try await InputWorkQueue.shared.inventory(folder: $0) },
         inspectionLoader: @escaping InspectionLoader = { try await InputWorkQueue.shared.loadForInspection(folder: $0, inventory: $1) },
         inspectionCloser: @escaping InspectionCloser = { await InputWorkQueue.shared.close(token: $0) },
         preparationLoader: @escaping PreparationLoader = {
             try await InputWorkQueue.shared.prepare(sourceToken: $0, moduleName: $1, guestBase: $2)
         },
         preparationCloser: @escaping PreparationCloser = {
             await InputWorkQueue.shared.closePrepared(sourceToken: $0, token: $1)
         },
         linkInventoryLoader: @escaping LinkInventoryLoader = {
             try await InputWorkQueue.shared.linkInventory(sourceToken: $0)
         },
         linkInventoryCloser: @escaping LinkInventoryCloser = {
             await InputWorkQueue.shared.closeLinkInventory(sourceToken: $0, token: $1)
         }) {
        self.inventoryLoader = inventoryLoader
        self.inspectionLoader = inspectionLoader
        self.inspectionCloser = inspectionCloser
        self.preparationLoader = preparationLoader
        self.preparationCloser = preparationCloser
        self.linkInventoryLoader = linkInventoryLoader
        self.linkInventoryCloser = linkInventoryCloser
    }

    @discardableResult
    func importFolder(_ url: URL) -> Task<Void, Never> {
        cancelImport()
        let request = UUID()
        generation = request
        errorMessage = nil
        inventory = nil
        validation = nil
        selectedFolder = nil
        isImporting = true
        let loader = inventoryLoader
        let predecessor = workBarrier
        let task = Task { [weak self] in
            await predecessor?.value
            guard !Task.isCancelled, self?.generation == request else { return }
            let worker = Task.detached(priority: .userInitiated) { try await loader(url) }
            let result = await withTaskCancellationHandler(operation: { await worker.result }, onCancel: { worker.cancel() })
            guard let self = self, self.generation == request, !Task.isCancelled else { return }
            self.isImporting = false
            self.operationTask = nil
            switch result {
            case .success(let inventory):
                self.inventory = inventory
                self.selectedFolder = url
            case .failure(let error):
                if !(error is CancellationError) { self.errorMessage = error.localizedDescription }
            }
        }
        operationTask = task
        workBarrier = task
        return task
    }

    @discardableResult
    func validatePayloads() -> Task<Void, Never>? {
        guard let folder = selectedFolder, let inventory = inventory, !isImporting, !isValidating, !isLoading else { return nil }
        cancelImport()
        let request = UUID()
        generation = request
        validation = nil
        errorMessage = nil
        isValidating = true
        let predecessor = workBarrier
        let task = Task { [weak self] in
            await predecessor?.value
            guard !Task.isCancelled, self?.generation == request else { return }
            let worker = Task.detached(priority: .userInitiated) {
                try await InputWorkQueue.shared.validate(folder: folder, inventory: inventory)
            }
            let result = await withTaskCancellationHandler(operation: { await worker.result }, onCancel: { worker.cancel() })
            guard let self = self, self.generation == request, !Task.isCancelled else { return }
            self.isValidating = false
            self.operationTask = nil
            switch result {
            case .success(let validation): self.validation = validation
            case .failure(let error):
                if !(error is CancellationError) { self.errorMessage = error.localizedDescription }
            }
        }
        operationTask = task
        workBarrier = task
        return task
    }

    @discardableResult
    func loadForInspection() -> Task<Void, Never>? {
        guard let folder = selectedFolder, let inventory = inventory, !isImporting, !isValidating, !isLoading else { return nil }
        cancelImport()
        let request = UUID()
        generation = request
        validation = nil
        errorMessage = nil
        isLoading = true
        let loader = inspectionLoader
        let closer = inspectionCloser
        let predecessor = workBarrier
        let task = Task { [weak self] in
            await predecessor?.value
            guard !Task.isCancelled, self?.generation == request else { return }
            let worker = Task.detached(priority: .userInitiated) { try await loader(folder, inventory) }
            let result = await withTaskCancellationHandler(operation: { await worker.result }, onCancel: { worker.cancel() })
            // A successful native load may race cancellation or UI deallocation. Its
            // token must be closed even when this generation can no longer publish.
            guard let self = self, self.generation == request, !Task.isCancelled else {
                if case .success(let session) = result { await closer(session.token) }
                return
            }
            self.isLoading = false
            self.operationTask = nil
            switch result {
            case .success(let session):
                self.loadedToken = session.token
                self.loadedInspection = session.report
            case .failure(let error):
                if !(error is CancellationError) { self.errorMessage = error.localizedDescription }
            }
        }
        operationTask = task
        workBarrier = task
        return task
    }

    /// Uses an already-held module. The explicit base is a layout-model integer,
    /// not an inferred game address; no input is reopened and no native pointer crosses await.
    @discardableResult
    func prepareSelectedModule(_ moduleName: String, baseText: String) -> Task<Void, Never>? {
        guard let sourceToken = loadedToken, let report = loadedInspection,
              !isImporting, !isValidating, !isLoading else { return nil }
        let base: UInt64
        do {
            guard report.modules.contains(where: { $0.name == moduleName }) else {
                throw PreparedInspectionError.unknownModule
            }
            base = try PreparedModelBase.parse(baseText)
        } catch { errorMessage = error.localizedDescription; return nil }
        cancelPreparation() // Close only the old derived model, not its source.
        let request = UUID()
        preparationGeneration = request
        isPreparing = true
        errorMessage = nil
        let loader = preparationLoader
        let closer = preparationCloser
        let predecessor = workBarrier
        let task = Task { [weak self] in
            await predecessor?.value
            guard !Task.isCancelled, self?.preparationGeneration == request else { return }
            let worker = Task.detached(priority: .userInitiated) {
                try await loader(sourceToken, moduleName, base)
            }
            let result = await withTaskCancellationHandler(operation: { await worker.result }, onCancel: { worker.cancel() })
            guard let self = self, self.preparationGeneration == request,
                  self.loadedToken == sourceToken, !Task.isCancelled else {
                if case .success(let session) = result { await closer(session.sourceToken, session.token) }
                return
            }
            self.isPreparing = false
            self.preparationTask = nil
            switch result {
            case .success(let session):
                guard session.sourceToken == sourceToken else {
                    await closer(session.sourceToken, session.token)
                    // A faulty injected provider must not publish into a different source.
                    if self.preparationGeneration == request { self.errorMessage = PreparedInspectionError.staleSource.localizedDescription }
                    return
                }
                self.preparedIdentity = (sourceToken, session.token)
                self.preparedInspection = session.report
            case .failure(let error):
                if !(error is CancellationError) { self.errorMessage = error.localizedDescription }
            }
        }
        preparationTask = task
        workBarrier = task
        return task
    }

    /// Cancels pending preparation and closes an accepted model only. Source stays loaded.
    @discardableResult
    func cancelPreparation() -> Task<Void, Never>? {
        preparationGeneration = UUID()
        preparationTask?.cancel()
        preparationTask = nil
        isPreparing = false
        preparedInspection = nil
        guard let identity = preparedIdentity else { return workBarrier }
        preparedIdentity = nil
        let closer = preparationCloser
        let predecessor = workBarrier
        let task = Task {
            await predecessor?.value
            await closer(identity.source, identity.token)
        }
        workBarrier = task
        return task
    }

    /// A separate explicit action. Uses every held module; takes no base or provider
    /// choice, and neither releases nor weakens the existing prepared-model contract.
    @discardableResult
    func inspectBatchLinks() -> Task<Void, Never>? {
        guard let sourceToken = loadedToken, loadedInspection != nil,
              !isImporting, !isValidating, !isLoading else { return nil }
        cancelLinkInventory() // Replace the prior numeric report, not the prepared image.
        let request = UUID()
        linkGeneration = request
        isLinking = true
        errorMessage = nil
        let loader = linkInventoryLoader
        let closer = linkInventoryCloser
        let predecessor = workBarrier
        let task = Task { [weak self] in
            await predecessor?.value
            guard !Task.isCancelled, self?.linkGeneration == request else { return }
            let worker = Task.detached(priority: .userInitiated) { try await loader(sourceToken) }
            let result = await withTaskCancellationHandler(operation: { await worker.result }, onCancel: { worker.cancel() })
            guard let self = self, self.linkGeneration == request,
                  self.loadedToken == sourceToken, !Task.isCancelled else {
                if case .success(let session) = result { await closer(session.sourceToken, session.token) }
                return
            }
            self.isLinking = false
            self.linkTask = nil
            switch result {
            case .success(let session):
                guard session.sourceToken == sourceToken else {
                    await closer(session.sourceToken, session.token)
                    if self.linkGeneration == request {
                        self.errorMessage = LinkInspectionError.staleSource.localizedDescription
                    }
                    return
                }
                self.linkIdentity = (sourceToken, session.token)
                self.linkInspection = session.report
            case .failure(let error):
                if !(error is CancellationError) { self.errorMessage = error.localizedDescription }
            }
        }
        linkTask = task
        workBarrier = task
        return task
    }

    /// Invalidates late results and clears only the accepted copied inventory report.
    @discardableResult
    func cancelLinkInventory() -> Task<Void, Never>? {
        linkGeneration = UUID()
        linkTask?.cancel()
        linkTask = nil
        isLinking = false
        linkInspection = nil
        guard let identity = linkIdentity else { return workBarrier }
        linkIdentity = nil
        let closer = linkInventoryCloser
        let predecessor = workBarrier
        let task = Task {
            await predecessor?.value
            await closer(identity.source, identity.token)
        }
        workBarrier = task
        return task
    }

    /// Release the exact accepted session; an older close cannot close a newer token.
    @discardableResult
    func closeLoadedInspection() -> Task<Void, Never>? {
        cancelLinkInventory()
        cancelPreparation()
        loadedInspection = nil
        guard let token = loadedToken else { return workBarrier }
        loadedToken = nil
        let closer = inspectionCloser
        let predecessor = workBarrier
        let task = Task {
            await predecessor?.value
            await closer(token) // Actor also enforces derived-before-source release.
        }
        workBarrier = task
        return task
    }

    func reportPickerError(_ error: Error) {
        let nsError = error as NSError
        if nsError.domain != NSCocoaErrorDomain || nsError.code != NSUserCancelledError {
            errorMessage = error.localizedDescription
        }
    }

    func cancelImport() {
        generation = UUID()
        operationTask?.cancel()
        operationTask = nil
        isImporting = false
        isValidating = false
        isLoading = false
        closeLoadedInspection()
    }

    func clear() {
        cancelImport()
        inventory = nil
        validation = nil
        selectedFolder = nil
        errorMessage = nil
    }

    func transition(to phase: ScenePhase) {
        isForeground = phase == .active
        if phase == .background { cancelImport() }
    }

    deinit {
        operationTask?.cancel()
        preparationTask?.cancel()
        linkTask?.cancel()
        let predecessor = workBarrier
        let linked = linkIdentity
        let closeLink = linkInventoryCloser
        let identity = preparedIdentity
        let source = loadedToken
        let closePrepared = preparationCloser
        let closeSource = inspectionCloser
        Task {
            await predecessor?.value
            if let linked = linked { await closeLink(linked.source, linked.token) }
            if let identity = identity { await closePrepared(identity.source, identity.token) }
            if let source = source { await closeSource(source) }
        }
    }
}
