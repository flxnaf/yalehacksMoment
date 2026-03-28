import SwiftUI
import MWDATCore

#if DEBUG
import MWDATMockDevice
#endif

enum CameraSource: String, CaseIterable {
    case phone   = "Phone"
    case glasses = "Ray-Ban"
}

@MainActor
class AppViewModel: ObservableObject {
    @Published var registrationState: RegistrationState = .unavailable
    @Published var showError = false
    @Published var errorMessage = ""

    private(set) var wearables: WearablesInterface?
    private var registrationTask: Task<Void, Never>?

    // Called once when user first switches to Ray-Ban mode
    func configureIfNeeded() {
        guard wearables == nil else { return }
        do {
            try Wearables.configure()
            wearables = Wearables.shared
            startObserving()
        } catch {
            showError("SDK configure failed: \(error.localizedDescription)")
        }
    }

    private func startObserving() {
        guard let w = wearables else { return }
        registrationTask = Task { [weak self] in
            for await state in w.registrationStateStream() {
                self?.registrationState = state
            }
        }
    }

    func connect() {
        guard let w = wearables else { return }
        Task {
            do { try await w.startRegistration() }
            catch { showError(error.localizedDescription) }
        }
    }

    func disconnect() {
        guard let w = wearables else { return }
        Task {
            do { try await w.startUnregistration() }
            catch { showError(error.localizedDescription) }
        }
    }

    func showError(_ msg: String) { errorMessage = msg; showError = true }
    func dismissError() { showError = false; errorMessage = "" }

    deinit { registrationTask?.cancel() }
}
