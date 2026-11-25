import Foundation
import Observation

@MainActor
@Observable
final class ShowerController {
    var balance: QiekjBalance?
    var devices: [QiekjDevice] = []
    var recentOrders: [QiekjOrderSummary] = []
    var favoriteGoodsIDs: Set<String> = []
    var usePoints: Bool {
        didSet { UserDefaults.standard.set(usePoints, forKey: "qiekj_use_points") }
    }

    var phase: ShowerSessionPhase = .idle
    var isRefreshing = false
    var infoBanner: String?

    private var activeTask: Task<Void, Never>?
    private var stopRequested = false

    private static let favoritesKey = "qiekj_favorite_goods_ids"
    private static let cachedDevicesKey = "qiekj_cached_devices_v1"

    var isLoggedIn: Bool {
        !KeychainStore.read(.qiekjToken).isEmpty
    }

    init() {
        self.usePoints = UserDefaults.standard.object(forKey: "qiekj_use_points") as? Bool ?? true
        if let savedFavs = UserDefaults.standard.stringArray(forKey: Self.favoritesKey) {
            self.favoriteGoodsIDs = Set(savedFavs)
        }
        if let data = UserDefaults.standard.data(forKey: Self.cachedDevicesKey),
           let cached = try? JSONDecoder().decode([QiekjDevice].self, from: data) {
            self.devices = cached
        }
    }

    func toggleFavorite(goodsId: String) {
        if favoriteGoodsIDs.contains(goodsId) {
            favoriteGoodsIDs.remove(goodsId)
        } else {
            favoriteGoodsIDs.insert(goodsId)
        }
        UserDefaults.standard.set(Array(favoriteGoodsIDs), forKey: Self.favoritesKey)
    }

    var sortedDevices: [QiekjDevice] {
        devices.sorted { a, b in
            let favA = favoriteGoodsIDs.contains(a.goodsId)
            let favB = favoriteGoodsIDs.contains(b.goodsId)
            if favA != favB { return favA }
            if a.isIdle != b.isIdle { return a.isIdle }
            return a.goodsName.localizedStandardCompare(b.goodsName) == .orderedAscending
        }
    }

    func refreshAll() async {
        let token = KeychainStore.read(.qiekjToken)
        guard !token.isEmpty else {
            balance = nil
            return
        }

        isRefreshing = true
        defer { isRefreshing = false }

        async let balTask = QiekjClient.shared.fetchBalance(token: token)
        async let latestTask = QiekjClient.shared.fetchLatestDevices(token: token, categoryCode: "08")
        async let ordersTask = QiekjClient.shared.fetchOrderHistory(token: token, page: 1, pageSize: 30)

        let bal = try? await balTask
        let latest = (try? await latestTask) ?? []
        let orders = (try? await ordersTask) ?? []

        if let bal { self.balance = bal }
        self.recentOrders = orders

        // Merge by goodsId (latestUsed first, then historical orders, then full floor machines!)
        var mergedById: [String: QiekjDevice] = [:]
        for d in self.devices {
            mergedById[d.goodsId] = d
        }
        for o in orders {
            if mergedById[o.goodsId] == nil {
                mergedById[o.goodsId] = QiekjDevice(
                    goodsId: o.goodsId,
                    goodsName: o.goodsName,
                    categoryCode: o.categoryCode,
                    shopId: o.shopId,
                    orgId: o.orgId,
                    orgName: o.shopName,
                    parentPointName: "",
                    workStatus: nil,
                    skuId: o.skuId.isEmpty ? nil : o.skuId,
                    imei: nil
                )
            }
        }
        for d in latest {
            mergedById[d.goodsId] = d
        }

        // Discover all stalls in the same campus shop via `appointNew/near/newMachines`
        let shopId = latest.first(where: { !$0.shopId.isEmpty })?.shopId
            ?? orders.first(where: { !$0.shopId.isEmpty })?.shopId
            ?? ""
        let orgId = latest.first(where: { !$0.orgId.isEmpty && $0.orgId != "0" })?.orgId
            ?? orders.first(where: { !$0.orgId.isEmpty && $0.orgId != "0" })?.orgId
            ?? "0"

        if !shopId.isEmpty {
            var nearList = (try? await QiekjClient.shared.fetchNearMachines(
                token: token,
                shopId: shopId,
                machineTypeId: "08",
                orgId: orgId
            )) ?? []
            if nearList.isEmpty && orgId != "0" {
                nearList = (try? await QiekjClient.shared.fetchNearMachines(
                    token: token,
                    shopId: shopId,
                    machineTypeId: "08",
                    orgId: "0"
                )) ?? []
            }
            for d in nearList {
                mergedById[d.goodsId] = d
            }
        }

        self.devices = Array(mergedById.values)
        if let encoded = try? JSONEncoder().encode(self.devices) {
            UserDefaults.standard.set(encoded, forKey: Self.cachedDevicesKey)
        }
    }

    func addDeviceByGoodsId(_ goodsId: String) async -> QiekjDevice? {
        let token = KeychainStore.read(.qiekjToken)
        let trimmed = goodsId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty, !trimmed.isEmpty else { return nil }

        do {
            let details = try await QiekjClient.shared.fetchDeviceDetails(token: token, goodsId: trimmed)
            let skuId = try? await QiekjClient.shared.fetchSkuId(token: token, goodsId: trimmed)
            let device = QiekjDevice(
                goodsId: details.goodsId,
                goodsName: details.name,
                categoryCode: details.categoryCode,
                shopId: devices.first?.shopId ?? "",
                orgId: devices.first?.orgId ?? "0",
                orgName: devices.first?.orgName ?? "",
                parentPointName: "",
                workStatus: 10,
                skuId: skuId,
                imei: details.imei
            )
            if let idx = devices.firstIndex(where: { $0.goodsId == device.goodsId }) {
                devices[idx] = device
            } else {
                devices.insert(device, at: 0)
            }
            if let encoded = try? JSONEncoder().encode(devices) {
                UserDefaults.standard.set(encoded, forKey: Self.cachedDevicesKey)
            }
            return device
        } catch {
            infoBanner = "添加设备失败：\(error.localizedDescription)"
            return nil
        }
    }

    func startShower(device: QiekjDevice) {
        guard activeTask == nil else { return }
        let token = KeychainStore.read(.qiekjToken)
        guard !token.isEmpty else {
            phase = .failed(message: "请先前往「我的」页登录胖乖生活")
            return
        }

        stopRequested = false
        phase = .preparing(device: device, step: "正在获取设备 SKU…")

        activeTask = Task { [weak self] in
            guard let self else { return }
            defer { self.activeTask = nil }
            await self.runShowerPipeline(device: device, token: token)
        }
    }

    func requestStopShower() {
        stopRequested = true
        if case let .running(device, orderNo, startedAt, _, appEndSupported, _) = phase {
            phase = .running(
                device: device,
                orderNo: orderNo,
                startedAt: startedAt,
                step: appEndSupported ? "正在下发远程停阀…" : "请在设备端按结束按钮，等待回报…",
                appEndSupported: appEndSupported,
                stopping: true
            )
        }
    }

    func dismissResult() {
        if case .finished = phase {
            phase = .idle
        } else if case .failed = phase {
            phase = .idle
        }
    }

    private func runShowerPipeline(device: QiekjDevice, token: String) async {
        do {
            phase = .preparing(device: device, step: "正在获取设备 SKU…")
            let skuId = try await QiekjClient.shared.fetchSkuId(token: token, goodsId: device.goodsId)

            phase = .preparing(device: device, step: "正在检测设备状态…")
            _ = try? await QiekjClient.shared.syncWater(token: token, skuId: skuId)

            phase = .preparing(device: device, step: "正在读取设备能力与 IMEI…")
            let details = try await QiekjClient.shared.fetchDeviceDetails(token: token, goodsId: device.goodsId)
            let appEndSupported = details.supportAppUserFinish ?? true

            phase = .preparing(device: device, step: "正在进行风控预检…")
            try await QiekjClient.shared.checkUserIsRisk(token: token)

            phase = .preparing(device: device, step: "正在确认先用后付通道…")
            try await QiekjClient.shared.addUserAfterPayChannel(token: token)

            phase = .preparing(device: device, step: "正在进行位置校验…")
            let catCode = details.categoryCode.isEmpty ? "08" : details.categoryCode
            try await QiekjClient.shared.isCheckLocation(token: token, categoryCode: catCode, imei: details.imei)

            phase = .preparing(device: device, step: "正在云端开阀出水…")
            let orderNo = try await QiekjClient.shared.unlockWater(
                token: token,
                skuId: skuId,
                usePoints: usePoints
            )

            let startedAt = Date()
            phase = .running(
                device: device,
                orderNo: orderNo,
                startedAt: startedAt,
                step: "已开阀出水中",
                appEndSupported: appEndSupported,
                stopping: false
            )

            try? await Task.sleep(for: .seconds(2))

            // Poll every 2 seconds for up to 30 minutes (900 attempts)
            let maxAttempts = 900
            var attempts = 0
            var everWorked = false
            var emptyStreak = 0
            var lastSync: QiekjSyncStatus?
            var remoteEndAttempted = false
            var remoteEndAccepted = false
            var remoteEndDeadline: Date?

            while attempts < maxAttempts {
                if Task.isCancelled { return }
                attempts += 1

                let sync = try await QiekjClient.shared.syncWater(token: token, skuId: skuId)

                if sync == nil {
                    emptyStreak += 1
                    if everWorked || remoteEndAccepted {
                        break // Device closed session → proceed to settle!
                    }
                    if emptyStreak >= 6 {
                        throw QiekjClientError(code: -1, message: "设备未响应，可能已离线或被占用")
                    }
                    try? await Task.sleep(for: .seconds(2))
                    continue
                }

                emptyStreak = 0
                lastSync = sync
                if sync?.workStatus == 2 {
                    everWorked = true
                }

                if stopRequested {
                    if !remoteEndAttempted {
                        remoteEndAttempted = true
                        if appEndSupported {
                            phase = .running(
                                device: device,
                                orderNo: orderNo,
                                startedAt: startedAt,
                                step: "正在下发远程停阀，等待设备回报…",
                                appEndSupported: appEndSupported,
                                stopping: true
                            )
                            do {
                                try await QiekjClient.shared.endWater(token: token, goodsId: device.goodsId)
                                remoteEndAccepted = true
                                remoteEndDeadline = Date().addingTimeInterval(20)
                            } catch {
                                remoteEndAccepted = false
                                phase = .running(
                                    device: device,
                                    orderNo: orderNo,
                                    startedAt: startedAt,
                                    step: "远程关阀未受理，请在设备端按结束键",
                                    appEndSupported: false,
                                    stopping: true
                                )
                            }
                        }
                    }

                    // Status == 5 means platform confirms session finished
                    if sync?.status == 5 {
                        break
                    }
                    if let deadline = remoteEndDeadline, Date() >= deadline {
                        break
                    }
                } else {
                    // User closed physical valve on hardware
                    if sync?.status == 5 || (everWorked && sync?.workStatus != 2) {
                        break
                    }
                }

                try? await Task.sleep(for: .seconds(2))
            }

            // Settle order
            phase = .settling(device: device, step: "正在生成后付结算账单…")
            let finalOrderNo = (lastSync?.identify?.isEmpty == false ? lastSync?.identify : nil) ?? orderNo
            let elapsed = Int(Date().timeIntervalSince(startedAt))

            let orderId = try await QiekjClient.shared.createAfterPay(token: token, orderNo: finalOrderNo)
            phase = .settling(device: device, step: "正在查询本次消费明细…")
            let detail = try await QiekjClient.shared.fetchOrderDetail(token: token, orderId: orderId)

            let receipt = QiekjShowerReceipt(
                orderNo: finalOrderNo,
                orderId: orderId,
                goodsName: device.goodsName,
                realPrice: detail.realPrice,
                originPrice: detail.originPrice,
                payTypeName: detail.payTypeName,
                elapsedSeconds: elapsed,
                completedAt: Date()
            )
            phase = .finished(receipt)
            await refreshAll()
        } catch {
            phase = .failed(message: error.localizedDescription)
        }
    }
}
