import Foundation

@MainActor
final class SightAssistController: ObservableObject {
    @Published var mode: AppMode = .idle
    @Published var navigationStatus: String = ""

    var navigationController: NavigationController?

    init(navigationController: NavigationController? = nil) {
        self.navigationController = navigationController
    }

    func transition(to newMode: AppMode) {
        if mode == .navigatingOutdoor && newMode != .navigatingOutdoor {
            navigationController?.stopNavigation()
        }
        if newMode == .idle {
            navigationStatus = ""
        }
        mode = newMode
    }
}
