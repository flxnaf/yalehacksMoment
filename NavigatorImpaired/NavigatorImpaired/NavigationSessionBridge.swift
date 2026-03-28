import Foundation

/// Holds the active `NavigationController` for K2 fall context and replanning.
@MainActor
final class NavigationSessionBridge {
  static let shared = NavigationSessionBridge()
  weak var controller: NavigationController?
  private init() {}
}
