import SwiftUI

@main
struct DepthanythingTestApp: App {
    @StateObject private var appVM = AppViewModel()

    var body: some Scene {
        WindowGroup {
            DepthBenchmarkView()
                .environmentObject(appVM)
        }
    }
}
