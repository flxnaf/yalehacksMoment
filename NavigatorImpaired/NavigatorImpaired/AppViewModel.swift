import SwiftUI
import MWDATCore

#if canImport(MWDATMockDevice)
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

    private(set) var wearables: WearablesInterface
    private var registrationTask: Task<Void, Never>?

    init(wearables: WearablesInterface) {
        self.wearables = wearables
        self.registrationState = wearables.registrationState
        startObserving()
    }

    /// Kept for DepthBenchmarkView when switching to Ray-Ban; SDK is already configured at app launch.
    func configureIfNeeded() {}

    /// Meta OAuth returns to your app via the registered URL scheme.
    func handleIncomingURL(_ url: URL) {
        Task { @MainActor in
            let w = wearables
            do {
                let handled = try await w.handleUrl(url)
                if handled {
                    registrationState = w.registrationState
                }
            } catch let error as RegistrationError {
                presentError(error.description)
            } catch {
                presentError("Meta sign-in: \(error.localizedDescription)")
            }
        }
    }

    private func startObserving() {
        let w = wearables
        registrationTask = Task { [weak self] in
            for await state in w.registrationStateStream() {
                self?.registrationState = state
            }
        }
    }

    func connect() {
        let w = wearables
        Task {
            do { try await w.startRegistration() }
            catch { presentError(error.localizedDescription) }
        }
    }

    func disconnect() {
        let w = wearables
        Task {
            do { try await w.startUnregistration() }
            catch { presentError(error.localizedDescription) }
        }
    }

    func presentError(_ msg: String) { errorMessage = msg; showError = true }
    func dismissError() { showError = false; errorMessage = "" }

    deinit { registrationTask?.cancel() }
}
