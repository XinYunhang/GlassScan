import SwiftData
import SwiftUI

enum AppTabSelection: Hashable {
    case scan
    case records
    case accounts
}

struct RootTabView: View {
    @State private var selectedTab: AppTabSelection = .scan
    @Query(sort: \ScanRecord.createdAt, order: .reverse) private var records: [ScanRecord]

    var body: some View {
        TabView(selection: $selectedTab) {
            Tab("扫码", systemImage: "qrcode.viewfinder", value: AppTabSelection.scan) {
                ScanTabView(selectedTab: $selectedTab)
            }

            Tab("记录", systemImage: "tray.full.fill", value: AppTabSelection.records) {
                RecordsTabView()
            }
            .badge(records.count)

            Tab("账号", systemImage: "person.badge.key.fill", value: AppTabSelection.accounts) {
                AccountsTabView(selectedTab: $selectedTab)
            }
        }
        .tabBarMinimizeBehavior(.onScrollDown)
    }
}
