import MWDATCore
import SwiftUI

#if canImport(MWDATMockDevice)
import MWDATMockDevice
#endif

@main
struct DepthanythingTestApp: App {
    private let wearables: WearablesInterface
    @StateObject private var appVM: AppViewModel
    @StateObject private var wearablesViewModel: WearablesViewModel

    #if canImport(MWDATMockDevice)
    @StateObject private var debugMenuViewModel: DebugMenuViewModel
    #endif

    init() {
        do {
            try Wearables.configure()
        } catch {
            #if DEBUG
            NSLog("[DepthanythingTest] Wearables.configure failed: \(error)")
            #endif
        }
        let w = Wearables.shared
        wearables = w
        _appVM = StateObject(wrappedValue: AppViewModel(wearables: w))
        _wearablesViewModel = StateObject(wrappedValue: WearablesViewModel(wearables: w))
        #if canImport(MWDATMockDevice)
        _debugMenuViewModel = StateObject(wrappedValue: DebugMenuViewModel(mockDeviceKit: MockDeviceKit.shared))
        #endif
    }

    var body: some Scene {
        WindowGroup {
            MainAppView(wearables: wearables, viewModel: wearablesViewModel)
                .alert("Error", isPresented: $wearablesViewModel.showError) {
                    Button("OK") { wearablesViewModel.dismissError() }
                } message: {
                    Text(wearablesViewModel.errorMessage)
                }
                .onOpenURL { appVM.handleIncomingURL($0) }
                .alert("Error", isPresented: $appVM.showError) {
                    Button("OK") { appVM.dismissError() }
                } message: {
                    Text(appVM.errorMessage)
                }
                #if canImport(MWDATMockDevice)
                .sheet(isPresented: $debugMenuViewModel.showDebugMenu) {
                    MockDeviceKitView(viewModel: debugMenuViewModel.mockDeviceKitViewModel)
                }
                .overlay {
                    DebugMenuView(debugMenuViewModel: debugMenuViewModel)
                }
                #endif
        }
    }
}
