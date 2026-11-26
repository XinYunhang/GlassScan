import SwiftData
import SwiftUI

struct LaundryTabView: View {
    @Binding var selectedTab: AppTabSelection

    @Environment(LaundryController.self) private var laundry
    @Query(sort: \ScanRecord.createdAt, order: .reverse) private var scanRecords: [ScanRecord]
    @State private var showStoreSearch = false
    @State private var searchKeyword = ""
    @State private var showCancelConfirm = false
    @State private var renamingDevice: SavedUjingDevice?
    @State private var aliasDraft = ""

    @Namespace private var glassNS

    private var hasImportableUjingRecords: Bool {
        let savedQRs = Set(laundry.savedDevices.map(\.rawQRCode))
        return scanRecords.contains { rec in
            let lower = rec.rawText.lowercased()
            return (rec.platform == .ujing || lower.contains("ujing") || lower.contains("midea"))
                && !savedQRs.contains(rec.rawText)
        }
    }

    var body: some View {
        @Bindable var bindableLaundry = laundry

        NavigationStack {
            ZStack {
                LiquidBackdrop(style: .laundry)

                ScrollView {
                    VStack(spacing: 16) {
                        if !laundry.isLoggedIn {
                            loginPromptCard
                        } else {
                            if let error = laundry.lastError {
                                bannerCard(text: error, isError: true)
                            } else if let notice = laundry.noticeText {
                                bannerCard(text: notice, isError: false)
                            }

                            if let order = laundry.activeOrder {
                                activeOrderHeroCard(order: order)
                            }

                            savedDevicesSection
                            quickScanCard(hasActiveOrder: laundry.activeOrder != nil && laundry.activeOrder?.isTerminal == false)
                            boardSection
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 8)
                    .padding(.bottom, 32)
                }
                .refreshable {
                    await laundry.refreshActiveOrder()
                    await laundry.refreshSavedDevicesStatus()
                    await laundry.refreshBoard()
                }
            }
            .navigationTitle("U净洗衣")
            .toolbar {
                if laundry.isLoggedIn {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button {
                            showStoreSearch = true
                        } label: {
                            Image(systemName: "plus")
                        }
                        .accessibilityLabel("搜索并收藏洗衣房")
                    }
                    ToolbarItem(placement: .topBarTrailing) {
                        Button {
                            Task {
                                await laundry.refreshActiveOrder()
                                await laundry.refreshSavedDevicesStatus()
                                await laundry.refreshBoard()
                            }
                        } label: {
                            if laundry.isRefreshingBoard || laundry.isRefreshingSavedDevices {
                                ProgressView()
                            } else {
                                Image(systemName: "arrow.clockwise")
                            }
                        }
                    }
                }
            }
            .task {
                if laundry.isLoggedIn {
                    await laundry.refreshActiveOrder()
                    if !laundry.savedDevices.isEmpty {
                        await laundry.refreshSavedDevicesStatus()
                    }
                    if laundry.boardRows.isEmpty && !laundry.favoriteStores.isEmpty {
                        await laundry.refreshBoard()
                    }
                }
            }
            // Poll active non-terminal order every 15s while on the Laundry tab
            .task(id: laundry.activeOrder?.orderId) {
                while !Task.isCancelled {
                    guard let order = laundry.activeOrder, !order.isTerminal else { break }
                    try? await Task.sleep(for: .seconds(15))
                    if Task.isCancelled { break }
                    await laundry.refreshActiveOrder()
                }
            }
            .sheet(item: $bindableLaundry.preparedSession) { session in
                UjingOrderSheet(session: session) {
                    // Stay on Laundry tab where the newly created order card appears at the top
                }
            }
            .sheet(isPresented: $showStoreSearch) {
                storeSearchSheet
            }
            .alert("确认取消这笔订单？", isPresented: $showCancelConfirm) {
                Button("继续保留", role: .cancel) {}
                Button("取消订单", role: .destructive) {
                    Task { await laundry.cancelActiveOrder() }
                }
            } message: {
                Text("取消后会立即释放 2 分钟机器锁定，他人可正常使用。")
            }
            .alert(
                "自定义洗衣机备注名",
                isPresented: Binding(
                    get: { renamingDevice != nil },
                    set: { if !$0 { renamingDevice = nil } }
                ),
                presenting: renamingDevice
            ) { device in
                TextField("例如：9楼4层 左边1号机", text: $aliasDraft)
                Button("取消", role: .cancel) { renamingDevice = nil }
                Button("保存") {
                    laundry.renameSavedDevice(id: device.deviceId, alias: aliasDraft)
                    renamingDevice = nil
                }
            } message: { device in
                Text("给这台固定二维码机器起个好认的名字，方便在宿舍远程锁机。")
            }
        }
    }

    private var loginPromptCard: some View {
        VStack(spacing: 14) {
            Image(systemName: "washer.fill")
                .font(.system(size: 48))
                .foregroundStyle(.indigo)
            Text("登录 U净以启用空闲看板与扫码付款")
                .font(.headline)
            Text("在宿舍就能查看洗衣房空闲台数，扫码选档后直接拉起支付宝付款并云端启动。")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button {
                selectedTab = .accounts
            } label: {
                Label("前往「我的」登录 U净", systemImage: "person.badge.key.fill")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.glassProminent)
            .tint(.indigo)
            .controlSize(.large)
        }
        .padding(22)
        .glassEffect(.regular, in: .rect(cornerRadius: 28))
    }

    private func bannerCard(text: String, isError: Bool) -> some View {
        HStack(spacing: 10) {
            Image(systemName: isError ? "exclamationmark.triangle.fill" : "sparkles")
                .foregroundStyle(isError ? .orange : .indigo)
            Text(text)
                .font(.footnote.weight(.medium))
            Spacer()
            Button {
                laundry.lastError = nil
                laundry.noticeText = nil
            } label: {
                Image(systemName: "xmark")
                    .font(.caption.bold())
            }
            .buttonStyle(.plain)
        }
        .padding(14)
        .glassEffect(.regular.tint(isError ? .orange : .indigo), in: .rect(cornerRadius: 20))
    }

    private func activeOrderHeroCard(order: UjingActiveOrder) -> some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let elapsedSinceSync = max(0, Int(context.date.timeIntervalSince(order.lastSyncedAt)))
            let liveRemain = max(0, order.remainSeconds - (order.status == "40" ? elapsedSinceSync : 0))

            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(order.deviceName)
                            .font(.headline)
                        Text([order.storeName, order.modelName].filter { !$0.isEmpty }.joined(separator: " · "))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Text(order.effectivePriceText)
                        .font(.title3.monospacedDigit().weight(.bold))
                }

                HStack(spacing: 8) {
                    Circle()
                        .fill(order.isDone ? Color.orange : (order.isRunning ? Color.green : Color.indigo))
                        .frame(width: 9, height: 9)
                    Text(order.statusLabel)
                        .font(.subheadline.weight(.semibold))
                    Spacer()
                    if order.status == "40" && liveRemain > 0 {
                        Text("约剩 \(formatMinutesSeconds(liveRemain))")
                            .font(.subheadline.monospacedDigit().weight(.semibold))
                            .foregroundStyle(.indigo)
                    }
                }

                if order.canPay {
                    VStack(spacing: 10) {
                        Button {
                            Task { await laundry.payActiveOrderWithAlipay() }
                        } label: {
                            Label(laundry.isWorking ? "正在拉起支付宝…" : "打开支付宝付款", systemImage: "creditcard.fill")
                                .font(.headline)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 6)
                        }
                        .buttonStyle(.glassProminent)
                        .tint(.blue)
                        .disabled(laundry.isWorking)

                        HStack(spacing: 10) {
                            Button {
                                Task { await laundry.refreshActiveOrder(checkPayFirst: true) }
                            } label: {
                                Label("我已付款 · 刷新", systemImage: "arrow.clockwise")
                                    .frame(maxWidth: .infinity)
                            }
                            .buttonStyle(.glass)

                            Button(role: .destructive) {
                                showCancelConfirm = true
                            } label: {
                                Label("取消订单", systemImage: "xmark.circle")
                            }
                            .buttonStyle(.glass)
                        }
                    }
                } else if order.canStart {
                    Button {
                        Task { await laundry.startActiveOrder() }
                    } label: {
                        Label(laundry.isWorking ? "正在发送启动指令…" : "云端启动机器", systemImage: "play.circle.fill")
                            .font(.headline)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 6)
                    }
                    .buttonStyle(.glassProminent)
                    .tint(.green)
                    .disabled(laundry.isWorking)
                } else if order.isDone {
                    Button {
                        laundry.dismissOrder()
                    } label: {
                        Label("我已取走衣物", systemImage: "checkmark.circle.fill")
                            .font(.headline)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 6)
                    }
                    .buttonStyle(.glassProminent)
                    .tint(.orange)
                } else if order.isTerminal {
                    Button("知道了 · 清除记录") {
                        laundry.dismissOrder()
                    }
                    .buttonStyle(.glass)
                    .frame(maxWidth: .infinity, alignment: .trailing)
                } else {
                    HStack {
                        Text("已自动设置完成提醒")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button {
                            Task { await laundry.refreshActiveOrder() }
                        } label: {
                            Label("刷新进度", systemImage: "arrow.clockwise")
                                .font(.caption.weight(.semibold))
                        }
                        .buttonStyle(.glass)
                    }
                }
            }
            .padding(18)
            .glassEffect(
                .regular.tint(order.isDone ? .orange : .indigo),
                in: .rect(cornerRadius: 28)
            )
            .glassEffectID("ujing-active-order", in: glassNS)
        }
    }

    // MARK: - Saved Washers (Remote Lock & Pay)

    private var savedDevicesSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("已保存洗衣机 · 远程锁机 (\(laundry.savedDevices.count))")
                        .font(.headline)
                    if !laundry.savedDevices.isEmpty {
                        let idleCount = laundry.savedDevices.filter(\.isKnownIdle).count
                        Text("空闲 \(idleCount) 台 · 在宿舍即可先下单锁机 2 分钟并付款")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer()
                if !laundry.savedDevices.isEmpty {
                    Button {
                        Task { await laundry.refreshSavedDevicesStatus() }
                    } label: {
                        Label(laundry.isRefreshingSavedDevices ? "查询中" : "查空闲", systemImage: "arrow.clockwise")
                            .font(.caption.weight(.semibold))
                    }
                    .buttonStyle(.glass)
                    .disabled(laundry.isRefreshingSavedDevices)
                }
            }

            if laundry.savedDevices.isEmpty {
                VStack(spacing: 10) {
                    Text("扫码一次即可永久保存洗衣机固定码")
                        .font(.subheadline.weight(.semibold))
                    Text("去洗衣房把常用机器的二维码各扫一遍（哪怕当时正在使用中也会自动保存）。以后看到空闲，在宿舍直接远程锁机付款，不怕被别人抢先占机。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                    HStack(spacing: 10) {
                        Button {
                            selectedTab = .scan
                        } label: {
                            Label("去扫码收录", systemImage: "qrcode.viewfinder")
                        }
                        .buttonStyle(.glassProminent)
                        .tint(.indigo)

                        if hasImportableUjingRecords {
                            Button {
                                Task {
                                    let rawTexts = scanRecords.map(\.rawText)
                                    _ = await laundry.importSavedDevices(from: rawTexts)
                                }
                            } label: {
                                Label("从历史导入", systemImage: "tray.and.arrow.down")
                            }
                            .buttonStyle(.glass)
                        }
                    }
                }
                .frame(maxWidth: .infinity)
                .padding(18)
                .glassEffect(.regular, in: .rect(cornerRadius: 24))
            } else {
                LazyVGrid(columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)], spacing: 10) {
                    ForEach(laundry.savedDevices) { dev in
                        savedDeviceCard(device: dev)
                    }
                }

                if hasImportableUjingRecords {
                    Button {
                        Task {
                            let rawTexts = scanRecords.map(\.rawText)
                            _ = await laundry.importSavedDevices(from: rawTexts)
                        }
                    } label: {
                        Label("发现历史扫码记录中有未收录的 U净机器，点此一键导入", systemImage: "tray.and.arrow.down")
                            .font(.caption.weight(.semibold))
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.glass)
                }
            }
        }
    }

    private func savedDeviceCard(device: SavedUjingDevice) -> some View {
        let badgeColor: Color = device.isKnownIdle ? .green : (device.isKnownBusy ? .orange : .secondary)

        return VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 6) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(device.displayName)
                        .font(.subheadline.weight(.bold))
                        .lineLimit(2)
                    Text(device.subtitle)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 2)
                Menu {
                    Button {
                        aliasDraft = device.customAlias.isEmpty ? device.displayName : device.customAlias
                        renamingDevice = device
                    } label: {
                        Label("自定义备注名", systemImage: "pencil")
                    }
                    Button(role: .destructive) {
                        laundry.removeSavedDevice(id: device.deviceId)
                    } label: {
                        Label("删除该机器", systemImage: "trash")
                    }
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 24, height: 24)
                }
            }

            HStack(spacing: 5) {
                Circle()
                    .fill(badgeColor)
                    .frame(width: 7, height: 7)
                Text(device.statusBadgeText)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(badgeColor)
                    .lineLimit(1)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(badgeColor.opacity(0.15), in: Capsule())

            if device.isKnownIdle {
                Button {
                    Task { _ = await laundry.prepareFromSavedDevice(device) }
                } label: {
                    Label("远程锁机下单", systemImage: "lock.fill")
                        .font(.caption.weight(.bold))
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.glassProminent)
                .tint(.indigo)
                .controlSize(.small)
                .disabled(laundry.isWorking)
            } else {
                Button {
                    Task { _ = await laundry.prepareFromSavedDevice(device) }
                } label: {
                    Label("查状态 / 下单", systemImage: "washer.fill")
                        .font(.caption.weight(.semibold))
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.glass)
                .controlSize(.small)
                .disabled(laundry.isWorking)
            }
        }
        .padding(14)
        .glassEffect(
            device.isKnownIdle ? .regular.tint(.indigo) : .regular,
            in: .rect(cornerRadius: 22)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .strokeBorder(device.isKnownIdle ? Color.green.opacity(0.35) : Color.clear, lineWidth: 1)
        )
    }

    private func quickScanCard(hasActiveOrder: Bool) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text(hasActiveOrder ? "已有进行中的订单" : "扫机身二维码立即下单")
                        .font(.headline)
                    Text("自动识别洗衣机 / 烘干机档位，拉起支付宝付款后云端启动")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }

            if hasActiveOrder {
                Button {
                    selectedTab = .scan
                } label: {
                    Label("去扫码（换一台）", systemImage: "qrcode.viewfinder")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 4)
                }
                .buttonStyle(.glass)
            } else {
                Button {
                    selectedTab = .scan
                } label: {
                    Label("扫码启动 U净洗衣机", systemImage: "qrcode.viewfinder")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 4)
                }
                .buttonStyle(.glassProminent)
                .tint(.indigo)
            }
        }
        .padding(18)
        .glassEffect(.regular, in: .rect(cornerRadius: 24))
    }

    private var boardSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("收藏洗衣房空闲看板")
                    .font(.headline)
                Spacer()
                Button {
                    showStoreSearch = true
                } label: {
                    Label("添加楼栋", systemImage: "plus.circle")
                        .font(.caption.weight(.semibold))
                }
                .buttonStyle(.glass)
            }

            if laundry.favoriteStores.isEmpty {
                VStack(spacing: 10) {
                    Text("还没有收藏洗衣房")
                        .font(.subheadline.weight(.medium))
                    Text("点右上角「+」输入宿舍楼栋名（或用当前位置搜索），收藏后在床上就能看空闲台数。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                    Button("搜索我的宿舍洗衣房") {
                        showStoreSearch = true
                    }
                    .buttonStyle(.glass)
                }
                .frame(maxWidth: .infinity)
                .padding(20)
                .glassEffect(.regular, in: .rect(cornerRadius: 24))
            } else {
                LazyVStack(spacing: 10) {
                    ForEach(laundry.favoriteStores) { fav in
                        let row = laundry.boardRows.first(where: { $0.id == fav.id || $0.name == fav.name })
                        boardRowCard(fav: fav, row: row)
                    }
                }
            }
        }
    }

    private func boardRowCard(fav: FavoriteUjingStore, row: UjingStoreBoardItem?) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(fav.name)
                    .font(.headline)
                Spacer()
                Button(role: .destructive) {
                    laundry.removeFavorite(id: fav.id)
                } label: {
                    Image(systemName: "trash")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }

            if let row {
                HStack(spacing: 12) {
                    metricPill(title: "洗衣机", free: row.washerFree, total: row.washerTotal)
                    if row.dryerTotal > 0 {
                        metricPill(title: "烘干机", free: row.dryerFree, total: row.dryerTotal)
                    }
                    if row.shoeTotal > 0 {
                        metricPill(title: "洗鞋机", free: row.shoeFree, total: row.shoeTotal)
                    }
                }
            } else {
                Text(laundry.isRefreshingBoard ? "正在刷新空闲台数…" : "下拉刷新以获取最新空闲状态")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(16)
        .glassEffect(.regular, in: .rect(cornerRadius: 22))
    }

    private func metricPill(title: String, free: Int, total: Int) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.caption2)
                .foregroundStyle(.secondary)
            Text(free > 0 ? "空闲 \(free)/\(total)" : "全满 0/\(total)")
                .font(.subheadline.monospacedDigit().weight(.bold))
                .foregroundStyle(free > 0 ? .green : .orange)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private var storeSearchSheet: some View {
        NavigationStack {
            List {
                Section("搜索本校洗衣房") {
                    HStack {
                        TextField("输入楼栋或学校关键字（如：12栋）", text: $searchKeyword)
                            .submitLabel(.search)
                            .onSubmit {
                                Task { await laundry.searchStores(keyword: searchKeyword, useGPS: true) }
                            }
                        Button("搜索") {
                            Task { await laundry.searchStores(keyword: searchKeyword, useGPS: true) }
                        }
                        .buttonStyle(.glassProminent)
                        .disabled(laundry.isSearchingStores)
                    }

                    Button {
                        Task { await laundry.searchStores(keyword: "", useGPS: true) }
                    } label: {
                        Label("用当前位置查附近洗衣房", systemImage: "location.fill")
                    }
                    .disabled(laundry.isSearchingStores)
                }

                if laundry.isSearchingStores {
                    Section {
                        HStack {
                            ProgressView()
                            Text("正在查询门店…")
                                .foregroundStyle(.secondary)
                        }
                    }
                } else if !laundry.searchResults.isEmpty {
                    Section("点击收藏到看板（\(laundry.searchResults.count) 家）") {
                        ForEach(laundry.searchResults) { item in
                            let isFav = laundry.favoriteStores.contains(where: { $0.id == item.id })
                            Button {
                                laundry.toggleFavoriteStore(item)
                            } label: {
                                HStack {
                                    VStack(alignment: .leading, spacing: 3) {
                                        Text(item.name)
                                            .font(.headline)
                                            .foregroundStyle(.primary)
                                        Text("\(item.subjectName) · 洗衣机空闲 \(item.washerFree)/\(item.washerTotal)")
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                    Image(systemName: isFav ? "star.fill" : "star")
                                        .foregroundStyle(isFav ? .yellow : .secondary)
                                }
                            }
                        }
                    }
                }
            }
            .navigationTitle("添加洗衣房")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("完成") { showStoreSearch = false }
                }
            }
        }
    }

    private func formatMinutesSeconds(_ seconds: Int) -> String {
        let m = seconds / 60
        let s = seconds % 60
        return String(format: "%d分%02d秒", m, s)
    }
}
