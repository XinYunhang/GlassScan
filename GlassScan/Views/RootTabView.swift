import SwiftUI

enum AppTabSelection: Hashable {
    case shower
    case laundry
    case scan
    case accounts
}

struct RootTabView: View {
    @State private var selectedTab: AppTabSelection = .shower

    @Environment(ShowerController.self) private var shower
    @Environment(LaundryController.self) private var laundry

    private var showerActive: Bool {
        if case .running = shower.phase { return true }
        return false
    }

    private var laundryHasActiveOrder: Bool {
        guard let order = laundry.activeOrder else { return false }
        return !order.isTerminal || order.isDone
    }

    var body: some View {
        TabView(selection: $selectedTab) {
            Tab("洗澡", systemImage: "drop.fill", value: AppTabSelection.shower) {
                ShowerTabView(selectedTab: $selectedTab)
            }
            .badge(showerActive ? 1 : 0)

            Tab("洗衣", systemImage: "washer.fill", value: AppTabSelection.laundry) {
                LaundryTabView(selectedTab: $selectedTab)
            }
            .badge(laundryHasActiveOrder ? 1 : 0)

            Tab("扫码", systemImage: "qrcode.viewfinder", value: AppTabSelection.scan) {
                ScanTabView(selectedTab: $selectedTab)
            }

            Tab("我的", systemImage: "person.badge.key.fill", value: AppTabSelection.accounts) {
                AccountsTabView(selectedTab: $selectedTab)
            }
        }
        .tabBarMinimizeBehavior(.onScrollDown)
    }
}
