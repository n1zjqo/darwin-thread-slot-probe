import Foundation
import SwiftUI

/// Owns UI generations and opaque inspection tokens, never native pointers or a launch API.
@MainActor
final class SessionModel: ObservableObject {
    typealias InventoryLoader = @Sendable (URL) async throws -> InputInventory
    typealias InspectionLoader = @Sendable (URL, InputInventory) async throws -> LoadedInspectionSession
    typealias InspectionCloser = @Sendable (UUID) async -> Void
    @Published private(set) var inventory: InputInventory?
    @Published private(set) var validation: PayloadValidationReport?
    @Published private(set) var loadedInspection: LoadedInspectionReport?
    @Published private(set) var isImporting = false
    @Published private(set) var isValidating = false
    @Published private(set) var isLoading = false
    @Published private(set) var errorMessage: String?
    @Published private(set) var isForeground = true
    private var operationTask: Task<Void, Never>?
    private var generation = UUID()
    private var selectedFolder: URL?
    private var loadedToken: UUID?
    private let inventoryLoader: InventoryLoader
    private let inspectionLoader: InspectionLoader
    private let inspectionCloser: InspectionCloser

    init(inventoryLoader: @escaping InventoryLoader = { try await InputWorkQueue.shared.inventory(folder: $0) },
         inspectionLoader: @escaping InspectionLoader = { try await InputWorkQueue.shared.loadForInspection(folder: $0, inventory: $1) },
         inspectionCloser: @escaping InspectionCloser = { await InputWorkQueue.shared.close(token: $0) }) {
        self.inventoryLoader = inventoryLoader
        self.inspectionLoader = inspectionLoader
        self.inspectionCloser = inspectionCloser
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
        let task = Task { [weak self] in
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
        let task = Task { [weak self] in
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
        let task = Task { [weak self] in
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
        return task
    }

    /// Release the exact accepted session; an older close cannot close a newer token.
    @discardableResult
    func closeLoadedInspection() -> Task<Void, Never>? {
        loadedInspection = nil
        guard let token = loadedToken else { return nil }
        loadedToken = nil
        let closer = inspectionCloser
        return Task { await closer(token) }
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
        if let token = loadedToken {
            let closer = inspectionCloser
            Task { await closer(token) }
        }
    }
}
