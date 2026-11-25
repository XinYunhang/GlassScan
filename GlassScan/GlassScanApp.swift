import SwiftData
import SwiftUI

@main
struct GlassScanApp: App {
    @State private var coordinator = ProbeCoordinator()

    var body: some Scene {
        WindowGroup {
            RootTabView()
                .environment(coordinator)
        }
        .modelContainer(for: ScanRecord.self)
    }
}
