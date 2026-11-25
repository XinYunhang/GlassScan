import CoreLocation
import Foundation
import Observation

struct PreparedUjingSession: Equatable, Identifiable {
    let id = UUID()
    let scanInfo: UjingScanInfo
    let programInfo: UjingProgramInfo
}

@MainActor
@Observable
final class LaundryController {
    var activeOrder: UjingActiveOrder? {
        didSet { persistActiveOrder() }
    }
    var favoriteStores: [FavoriteUjingStore] = [] {
        didSet { persistFavorites() }
    }
    var boardRows: [UjingStoreBoardItem] = []
    var searchResults: [UjingStoreBoardItem] = []

    var preparedSession: PreparedUjingSession?
    var isRefreshingBoard = false
    var isSearchingStores = false
    var isWorking = false
    var noticeText: String?
    var lastError: String?

    private static let activeOrderKey = "ujing_active_order_v1"
    private static let favoritesKey = "ujing_favorite_stores_v1"

    var isLoggedIn: Bool {
        !KeychainStore.read(.ujingToken).isEmpty
    }

    init() {
        if let data = UserDefaults.standard.data(forKey: Self.activeOrderKey),
           let saved = try? JSONDecoder().decode(UjingActiveOrder.self, from: data) {
            self.activeOrder = saved
        }
        if let data = UserDefaults.standard.data(forKey: Self.favoritesKey),
           let saved = try? JSONDecoder().decode([FavoriteUjingStore].self, from: data) {
            self.favoriteStores = saved
        }
    }

    // MARK: - Board & Store Search

    func searchStores(keyword: String, useGPS: Bool) async {
        let token = KeychainStore.read(.ujingToken)
        guard !token.isEmpty else {
            lastError = "请先在「我的」页登录 U净"
            return
        }
        isSearchingStores = true
        lastError = nil
        defer { isSearchingStores = false }

        var lat = 36.81
        var lng = 118.00
        if useGPS, let coord = await LocationHelper.shared.requestCurrentCoordinate() {
            lat = coord.latitude
            lng = coord.longitude
        }

        do {
            searchResults = try await UjingClient.shared.fetchStoresNear(
                token: token,
                lat: lat,
                lng: lng,
                keyword: keyword
            )
            if searchResults.isEmpty {
                noticeText = "未搜到匹配洗衣房，可换关键词或开启定位重试"
            }
        } catch {
            lastError = "搜索洗衣房失败：\(error.localizedDescription)"
        }
    }

    func toggleFavoriteStore(_ item: UjingStoreBoardItem, lat: Double = 36.81, lng: Double = 118.00) {
        if let idx = favoriteStores.firstIndex(where: { $0.id == item.id }) {
            favoriteStores.remove(at: idx)
            boardRows.removeAll { $0.id == item.id }
        } else {
            let fav = FavoriteUjingStore(id: item.id, name: item.name, keyword: item.name, lat: lat, lng: lng)
            favoriteStores.append(fav)
            if !boardRows.contains(where: { $0.id == item.id }) {
                boardRows.append(item)
            }
        }
    }

    func removeFavorite(id: String) {
        favoriteStores.removeAll { $0.id == id }
        boardRows.removeAll { $0.id == id }
    }

    func refreshBoard() async {
        let token = KeychainStore.read(.ujingToken)
        guard !token.isEmpty, !favoriteStores.isEmpty else { return }

        isRefreshingBoard = true
        defer { isRefreshingBoard = false }

        let coord = await LocationHelper.shared.requestCurrentCoordinate()
        var updated: [UjingStoreBoardItem] = []

        for fav in favoriteStores {
            let lat = coord?.latitude ?? fav.lat
            let lng = coord?.longitude ?? fav.lng
            if let list = try? await UjingClient.shared.fetchStoresNear(
                token: token,
                lat: lat,
                lng: lng,
                keyword: fav.keyword
            ) {
                if let exact = list.first(where: { $0.id == fav.id || $0.name == fav.name }) {
                    updated.append(exact)
                } else if let contains = list.first(where: { $0.name.contains(fav.name) }) {
                    updated.append(contains)
                }
            }
        }

        if !updated.isEmpty {
            boardRows = updated
        }
    }

    // MARK: - Scan → Program → Create → Pay → Start

    func prepareFromQRCode(_ rawQRCode: String) async -> Bool {
        let token = KeychainStore.read(.ujingToken)
        guard !token.isEmpty else {
            lastError = "识别 U净设备需要先在「我的」页登录 U净"
            return false
        }

        isWorking = true
        lastError = nil
        defer { isWorking = false }

        do {
            let scanInfo = try await UjingClient.shared.scanWasher(token: token, qrCode: rawQRCode)
            guard !scanInfo.deviceId.isEmpty else {
                let reason = scanInfo.reason.isEmpty ? "该二维码暂无法在洗衣机服务识别" : scanInfo.reason
                lastError = reason
                return false
            }

            let program = try await UjingClient.shared.fetchProgramInfo(token: token, deviceId: scanInfo.deviceId)
            preparedSession = PreparedUjingSession(scanInfo: scanInfo, programInfo: program)
            return true
        } catch {
            lastError = "识别失败：\(error.localizedDescription)"
            return false
        }
    }

    func createOrder(
        session: PreparedUjingSession,
        model: UjingWashModel,
        washTemperatureId: Int?,
        useDetergent: Bool,
        useDisinfectant: Bool,
        selectedDryMinutes: Int?
    ) async -> Bool {
        let token = KeychainStore.read(.ujingToken)
        guard !token.isEmpty else {
            lastError = "请先登录 U净"
            return false
        }

        // Prevent stacking if there is a non-terminal active order
        if let existing = activeOrder, !existing.isTerminal {
            await refreshActiveOrder()
            if let refreshed = activeOrder, !refreshed.isTerminal {
                lastError = "当前已有进行中的 U净订单，请先处理或取消后再下新单"
                return false
            }
        }

        isWorking = true
        lastError = nil
        defer { isWorking = false }

        let program = session.programInfo
        let isDryer = program.isDryer
        let dryMinutes = isDryer ? (selectedDryMinutes ?? model.timeMinutes) : nil
        let dryTimeParam = dryMinutes.map { max($0 / 10, 1) }
        let estPriceFen = model.estimatedPriceFen(selectedDryMinutes: dryMinutes)
        let totalMinutes = dryMinutes ?? model.timeMinutes

        do {
            let created = try await UjingClient.shared.createOrder(
                token: token,
                deviceId: program.deviceId,
                deviceTypeId: program.deviceTypeId,
                storeId: program.storeId,
                washModelId: model.workModelId,
                type: program.type,
                washTemperatureId: (!isDryer && program.isWashTemperatureEnable) ? washTemperatureId : nil,
                detergentGearId: (!isDryer && useDetergent) ? 1 : nil,
                disinfectantGearId: (!isDryer && useDisinfectant) ? 4 : nil,
                dryTime: dryTimeParam
            )

            let deviceLabel = [program.deviceTypeName, program.deviceNo].filter { !$0.isEmpty }.joined(separator: " ")
            let order = UjingActiveOrder(
                orderId: created.orderId,
                orderNo: created.orderNo,
                deviceId: program.deviceId,
                deviceName: deviceLabel.isEmpty ? "U净设备" : deviceLabel,
                storeName: program.storeName,
                modelName: model.displayTitle(isDryer: isDryer),
                isDryer: isDryer,
                estimatedPriceText: PriceFormatter.fenToYuan(estPriceFen),
                payPriceText: "",
                status: "10",
                statusRemark: "待支付（2分钟锁机）",
                payFlag: 0,
                remainSeconds: totalMinutes * 60,
                durationSeconds: totalMinutes * 60,
                createdAt: Date(),
                lastSyncedAt: Date()
            )
            activeOrder = order
            preparedSession = nil
            noticeText = "订单已创建，请在 2 分钟内完成支付宝付款"
            await refreshActiveOrder()
            return true
        } catch {
            lastError = "下单失败：\(error.localizedDescription)"
            return false
        }
    }

    func payActiveOrderWithAlipay() async {
        guard let order = activeOrder else { return }
        let token = KeychainStore.read(.ujingToken)
        guard !token.isEmpty else { return }

        isWorking = true
        lastError = nil
        defer { isWorking = false }

        do {
            let orderInfo = try await UjingClient.shared.fetchAlipayOrderInfo(token: token, orderId: order.orderId)
            let launchResult = await AlipayLauncher.launch(orderInfo: orderInfo)
            switch launchResult {
            case .launched:
                noticeText = "已拉起支付宝收银台，付款完成后切回 GlassScan 将自动同步状态"
            case .alipayNotInstalled:
                lastError = "未检测到支付宝客户端或无法拉起，请确认已安装支付宝"
            case .encodingFailed:
                lastError = "支付宝订单参数编码失败"
            }
        } catch {
            lastError = "获取支付宝支付参数失败：\(error.localizedDescription)"
        }
    }

    func refreshActiveOrder(checkPayFirst: Bool = false) async {
        guard let current = activeOrder else { return }
        let token = KeychainStore.read(.ujingToken)
        guard !token.isEmpty else { return }

        if checkPayFirst {
            _ = try? await UjingClient.shared.fetchLastPayStatus(token: token, orderId: current.orderId)
        }

        do {
            let updated = try await UjingClient.shared.fetchOrderDetail(
                token: token,
                orderId: current.orderId,
                existing: current
            )
            activeOrder = updated

            if updated.status == "40" && updated.remainSeconds > 15 {
                NotificationHelper.scheduleLaundryDone(
                    orderId: updated.orderId,
                    deviceName: updated.deviceName,
                    isDryer: updated.isDryer,
                    inSeconds: updated.remainSeconds
                )
            } else if updated.isTerminal {
                NotificationHelper.cancelLaundryDone(orderId: updated.orderId)
            }
        } catch {
            // Keep existing snapshot on transient network hiccup
        }
    }

    func startActiveOrder() async {
        guard let order = activeOrder else { return }
        let token = KeychainStore.read(.ujingToken)
        guard !token.isEmpty else { return }

        isWorking = true
        lastError = nil
        defer { isWorking = false }

        do {
            try await UjingClient.shared.controlOrder(token: token, orderId: order.orderId, action: "start")
            noticeText = "云端启动指令已发送，请留意机器开始运转"
            if order.durationSeconds > 60 {
                NotificationHelper.scheduleLaundryDone(
                    orderId: order.orderId,
                    deviceName: order.deviceName,
                    isDryer: order.isDryer,
                    inSeconds: order.durationSeconds
                )
            }
            try? await Task.sleep(for: .seconds(2))
            await refreshActiveOrder()
        } catch {
            lastError = "启动失败：\(error.localizedDescription)"
        }
    }

    func cancelActiveOrder() async {
        guard let order = activeOrder else { return }
        let token = KeychainStore.read(.ujingToken)
        guard !token.isEmpty else { return }

        isWorking = true
        lastError = nil
        defer { isWorking = false }

        do {
            try await UjingClient.shared.cancelOrder(token: token, orderId: order.orderId)
            NotificationHelper.cancelLaundryDone(orderId: order.orderId)
            activeOrder = nil
            noticeText = "订单已取消，机器锁机已释放"
        } catch {
            lastError = "取消失败：\(error.localizedDescription)"
        }
    }

    func dismissOrder() {
        if let order = activeOrder {
            NotificationHelper.cancelLaundryDone(orderId: order.orderId)
        }
        activeOrder = nil
    }

    private func persistActiveOrder() {
        if let activeOrder, let data = try? JSONEncoder().encode(activeOrder) {
            UserDefaults.standard.set(data, forKey: Self.activeOrderKey)
        } else {
            UserDefaults.standard.removeObject(forKey: Self.activeOrderKey)
        }
    }

    private func persistFavorites() {
        if let data = try? JSONEncoder().encode(favoriteStores) {
            UserDefaults.standard.set(data, forKey: Self.favoritesKey)
        }
    }
}
