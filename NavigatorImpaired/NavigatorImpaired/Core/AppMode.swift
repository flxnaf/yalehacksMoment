import Foundation

/// All possible app modes. Only one active at a time.
enum AppMode: String, CaseIterable {
    case idle
    case navigatingOutdoor
    case navigatingIndoor
    case indoorScanning
    case scanning
    case emergency
}
