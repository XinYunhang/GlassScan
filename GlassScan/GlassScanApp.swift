import SwiftData
import SwiftUI

@main
struct GlassScanApp: App {
    @Environment(\.scenePhase) private var scenePhase

    @State private var coordinator = ProbeCoordinator()
    @State private var showerController = ShowerController()
    @State private var laundryController = LaundryController()

    var body: some Scene {
        WindowGroup {
            RootTabView()
                .environment(coordinator)
                .environment(showerController)
                .environment(laundryController)
                .onOpenURL { url in
                    if url.scheme?.lowercased() == AlipayLauncher.callbackScheme {
                        Task {
                            await laundryController.refreshActiveOrder(checkPayFirst: true)
                        }
                    }
                }
                .onChange(of: scenePhase) { _, newPhase in
                    if newPhase == .active {
                        Task {
                            if let order = laundryController.activeOrder, !order.isTerminal {
                                await laundryController.refreshActiveOrder(checkPayFirst: order.canPay)
                            }
                        }
                    }
                }
        }
        .modelContainer(for: ScanRecord.self)
    }
}
