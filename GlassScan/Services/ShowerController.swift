import Foundation
import Observation

struct ActiveShowerSnapshot: Codable, Equatable, Sendable {
    let device: QiekjDevice
    let skuId: String
    let orderNo: String
    let startedAt: Date
    let appEndSupported: Bool
}

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
    var stopErrorMessage: String?
    var isRefreshing = false
    var infoBanner: String?

    /// Highlighted stall jumped to right after scanning a Pangguai QR code
    var highlightedDevice: QiekjDevice?
    var unmatchedScanSN: String?

    /// Persisted building & floor selection (e.g. "9号楼", floor 4)
    var selectedBuilding: String? {
        didSet {
            if let selectedBuilding {
                UserDefaults.standard.set(selectedBuilding, forKey: Self.selectedBuildingKey)
            } else {
                UserDefaults.standard.removeObject(forKey: Self.selectedBuildingKey)
            }
        }
    }
    var selectedFloor: Int? {
        didSet {
            if let selectedFloor {
                UserDefaults.standard.set(selectedFloor, forKey: Self.selectedFloorKey)
            } else {
                UserDefaults.standard.removeObject(forKey: Self.selectedFloorKey)
            }
        }
    }

    private var activeSnapshot: ActiveShowerSnapshot? {
        didSet { persistActiveSnapshot() }
    }
    private var pollTask: Task<Void, Never>?
    private var stopTask: Task<Void, Never>?
    private var lastIdentifyOrderNo: String?
    private var everWorked = false
    private var stopRequested = false

    private static let favoritesKey = "qiekj_favorite_goods_ids"
    private static let cachedDevicesKey = "qiekj_cached_devices_v1"
    private static let activeSnapshotKey = "qiekj_active_shower_v1"
    private static let selectedBuildingKey = "qiekj_selected_building_v1"
    private static let selectedFloorKey = "qiekj_selected_floor_v1"
    private static let userPickedFloorKey = "qiekj_user_picked_floor_v1"

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
        self.selectedBuilding = UserDefaults.standard.string(forKey: Self.selectedBuildingKey)
        if UserDefaults.standard.object(forKey: Self.selectedFloorKey) != nil {
            self.selectedFloor = UserDefaults.standard.integer(forKey: Self.selectedFloorKey)
        }
        // Restore active shower if iOS suspended/restarted the app mid-shower
        if let data = UserDefaults.standard.data(forKey: Self.activeSnapshotKey),
           let snap = try? JSONDecoder().decode(ActiveShowerSnapshot.self, from: data) {
            // Only auto-restore if started within the last 60 minutes
            if Date().timeIntervalSince(snap.startedAt) < 3600 {
                self.activeSnapshot = snap
                self.phase = .running(
                    device: snap.device,
                    orderNo: snap.orderNo,
                    startedAt: snap.startedAt,
                    step: "已恢复进行中的洗澡会话",
                    appEndSupported: snap.appEndSupported,
                    stopping: false
                )
                AppLog.shared.record(.info, module: .shower, "冷启动恢复洗澡会话：隔间 \(snap.device.goodsName) orderNo=\(snap.orderNo)")
                resumePollingIfNeeded()
            } else {
                UserDefaults.standard.removeObject(forKey: Self.activeSnapshotKey)
            }
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

    func clearHighlight() {
        highlightedDevice = nil
        unmatchedScanSN = nil
    }

    func selectBuilding(_ building: String?) {
        UserDefaults.standard.set(true, forKey: Self.userPickedFloorKey)
        selectedBuilding = building
        let floors = availableFloors(for: building)
        if let current = selectedFloor, !floors.contains(current) {
            selectedFloor = floors.first
        }
    }

    func selectFloor(_ floor: Int?) {
        UserDefaults.standard.set(true, forKey: Self.userPickedFloorKey)
        selectedFloor = floor
    }

    var availableBuildings: [String] {
        var orderMap: [String: Int] = [:]
        for d in devices {
            let key = d.buildingKey
            if let existing = orderMap[key] {
                orderMap[key] = min(existing, d.buildingSortOrder)
            } else {
                orderMap[key] = d.buildingSortOrder
            }
        }
        return orderMap.keys.sorted { a, b in
            let oa = orderMap[a] ?? 999
            let ob = orderMap[b] ?? 999
            if oa != ob { return oa < ob }
            return a.localizedStandardCompare(b) == .orderedAscending
        }
    }

    func availableFloors(for building: String?) -> [Int] {
        let filtered = devices.filter { d in
            guard let building else { return true }
            return d.buildingKey == building
        }
        return Array(Set(filtered.compactMap(\.floorNumber))).sorted()
    }

    var sortedDevices: [QiekjDevice] {
        devices.sorted { a, b in
            if highlightedDevice?.goodsId == a.goodsId { return true }
            if highlightedDevice?.goodsId == b.goodsId { return false }
            let favA = favoriteGoodsIDs.contains(a.goodsId)
            let favB = favoriteGoodsIDs.contains(b.goodsId)
            if favA != favB { return favA }
            if a.buildingSortOrder != b.buildingSortOrder { return a.buildingSortOrder < b.buildingSortOrder }
            if let fa = a.floorNumber, let fb = b.floorNumber, fa != fb { return fa < fb }
            if let sa = a.stallNumber, let sb = b.stallNumber, sa != sb { return sa < sb }
            return a.goodsName.localizedStandardCompare(b.goodsName) == .orderedAscending
        }
    }

    func refreshAll() async {
        guard !isRefreshing else { return }
        let token = KeychainStore.read(.qiekjToken)
        guard !token.isEmpty else {
            balance = nil
            return
        }

        isRefreshing = true
        defer { isRefreshing = false }
        AppLog.shared.record(.info, module: .shower, "开始刷新胖乖余额、历史订单与隔间列表")

        async let balTask = QiekjClient.shared.fetchBalance(token: token)
        async let latestTask = QiekjClient.shared.fetchLatestDevices(token: token, categoryCode: "08")
        async let ordersTask = QiekjClient.shared.fetchOrderHistory(token: token, page: 1, pageSize: 30)

        let bal = try? await balTask
        let latest = (try? await latestTask) ?? []
        let orders = (try? await ordersTask) ?? []

        if let bal { self.balance = bal }
        self.recentOrders = orders

        // Preserve previously discovered IMEIs when merging
        let oldImeiById = Dictionary(uniqueKeysWithValues: devices.compactMap { d in
            d.imei.map { (d.goodsId, $0) }
        })

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
                    imei: oldImeiById[o.goodsId]
                )
            }
        }
        for d in latest {
            mergedById[d.goodsId] = QiekjDevice(
                goodsId: d.goodsId,
                goodsName: d.goodsName,
                categoryCode: d.categoryCode,
                shopId: d.shopId,
                orgId: d.orgId,
                orgName: d.orgName,
                parentPointName: d.parentPointName,
                workStatus: d.workStatus,
                skuId: d.skuId ?? mergedById[d.goodsId]?.skuId,
                imei: d.imei ?? oldImeiById[d.goodsId]
            )
        }

        let shopId = latest.first(where: { !$0.shopId.isEmpty })?.shopId
            ?? orders.first(where: { !$0.shopId.isEmpty })?.shopId
            ?? ""
        let orgId = latest.first(where: { !$0.orgId.isEmpty && $0.orgId != "0" })?.orgId
            ?? orders.first(where: { !$0.orgId.isEmpty && $0.orgId != "0" })?.orgId
            ?? "0"

        var nearCount = 0
        if !shopId.isEmpty {
            var nearList = (try? await QiekjClient.shared.fetchNearMachines(
                token: token,
                shopId: shopId,
                machineTypeId: "08",
                orgId: "0"
            )) ?? []
            if nearList.isEmpty && orgId != "0" {
                nearList = (try? await QiekjClient.shared.fetchNearMachines(
                    token: token,
                    shopId: shopId,
                    machineTypeId: "08",
                    orgId: orgId
                )) ?? []
            }
            nearCount = nearList.count
            for d in nearList {
                mergedById[d.goodsId] = QiekjDevice(
                    goodsId: d.goodsId,
                    goodsName: d.goodsName,
                    categoryCode: d.categoryCode,
                    shopId: d.shopId,
                    orgId: d.orgId,
                    orgName: d.orgName,
                    parentPointName: d.parentPointName,
                    workStatus: d.workStatus,
                    skuId: d.skuId ?? mergedById[d.goodsId]?.skuId,
                    imei: d.imei ?? oldImeiById[d.goodsId],
                    remainSeconds: d.remainSeconds,
                    errorMessage: d.errorMessage
                )
            }
        }

        self.devices = Array(mergedById.values)
        saveDevicesCache()

        // First-time smart default: pre-select the user's most recently used building & floor!
        if !UserDefaults.standard.bool(forKey: Self.userPickedFloorKey) {
            if let anchor = latest.first ?? devices.first(where: { $0.goodsId == orders.first?.goodsId }),
               let loc = anchor.parsedLocation {
                selectedBuilding = "\(loc.building)号楼"
                selectedFloor = loc.floor
            }
        }

        var statusHistogram: [String: Int] = [:]
        for d in devices {
            let key = d.workStatus.map(String.init) ?? "nil"
            statusHistogram[key, default: 0] += 1
        }
        let histText = statusHistogram.keys.sorted().map { "\($0):\(statusHistogram[$0] ?? 0)" }.joined(separator: ", ")
        AppLog.shared.record(
            .info,
            module: .shower,
            "刷新完成：总隔间 \(devices.count) 台（latestUsed=\(latest.count), 订单=\(orders.count), near=\(nearCount)）",
            detail: "workStatus 分布：\(histText)\n楼栋：\(availableBuildings.joined(separator: ", "))"
        )
    }

    /// Resolves a scanned Pangguai QR code (`SN=...` or `goodsId=...`) to the exact stall and highlights it!
    func resolveScannedShower(rawText: String, sn: String?, goodsId: String?) async -> QiekjDevice? {
        let token = KeychainStore.read(.qiekjToken)
        unmatchedScanSN = nil
        AppLog.shared.record(.info, module: .scan, "开始解析胖乖洗澡码：SN=\(sn ?? "-") goodsId=\(goodsId ?? "-")")

        func focusDevice(_ dev: QiekjDevice) -> QiekjDevice {
            highlightedDevice = dev
            if let loc = dev.parsedLocation {
                selectedBuilding = "\(loc.building)号楼"
                selectedFloor = loc.floor
            }
            return dev
        }

        // 1. Direct goodsId match
        if let goodsId, !goodsId.isEmpty {
            if let dev = await addDeviceByGoodsId(goodsId) {
                AppLog.shared.record(.info, module: .shower, "通过 goodsId 直接定位到隔间 \(dev.goodsName)")
                return focusDevice(dev)
            }
        }

        guard let sn, !sn.isEmpty else {
            return nil
        }

        // 2. Instant local IMEI cache hit
        if let cachedMatch = devices.first(where: { $0.imei == sn }) {
            AppLog.shared.record(.info, module: .shower, "本地 IMEI 缓存命中隔间 \(cachedMatch.goodsName) (SN=\(sn))")
            return focusDevice(cachedMatch)
        }

        guard !token.isEmpty else {
            unmatchedScanSN = sn
            AppLog.shared.record(.warn, module: .shower, "未登录胖乖，无法解析 SN=\(sn)")
            return nil
        }

        // 3. Query backend `/goods/scan/v2`
        if let scannedGoodsId = await QiekjClient.shared.scanBySN(token: token, sn: sn, rawQRCode: rawText),
           let dev = await addDeviceByGoodsId(scannedGoodsId) {
            AppLog.shared.record(.info, module: .shower, "扫码接口定位到隔间 \(dev.goodsName) (goodsId=\(dev.goodsId))")
            return focusDevice(dev)
        }

        // 4. Fallback: refresh device list if empty, then build IMEI index via `goods/normal/details`
        if devices.isEmpty {
            await refreshAll()
        }
        let candidates = devices.filter { $0.imei == nil || $0.imei?.isEmpty == true }.prefix(25)
        for candidate in candidates {
            if let details = try? await QiekjClient.shared.fetchDeviceDetails(token: token, goodsId: candidate.goodsId) {
                let updated = QiekjDevice(
                    goodsId: candidate.goodsId,
                    goodsName: details.name.isEmpty ? candidate.goodsName : details.name,
                    categoryCode: details.categoryCode,
                    shopId: candidate.shopId,
                    orgId: candidate.orgId,
                    orgName: candidate.orgName,
                    parentPointName: candidate.parentPointName,
                    workStatus: candidate.workStatus,
                    skuId: candidate.skuId,
                    imei: details.imei,
                    remainSeconds: candidate.remainSeconds,
                    errorMessage: candidate.errorMessage
                )
                upsertDevice(updated)
                if details.imei == sn {
                    AppLog.shared.record(.info, module: .shower, "IMEI 索引匹配成功：隔间 \(updated.goodsName) (SN=\(sn))")
                    return focusDevice(updated)
                }
            }
        }

        unmatchedScanSN = sn
        AppLog.shared.record(.warn, module: .shower, "暂未将 SN=\(sn) 匹配到已知隔间（已搜索 \(devices.count) 台设备）")
        return nil
    }

    func addDeviceByGoodsId(_ goodsId: String) async -> QiekjDevice? {
        let token = KeychainStore.read(.qiekjToken)
        let trimmed = goodsId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty, !trimmed.isEmpty else { return nil }

        do {
            let details = try await QiekjClient.shared.fetchDeviceDetails(token: token, goodsId: trimmed)
            let skuId = try? await QiekjClient.shared.fetchSkuId(token: token, goodsId: trimmed)
            let existing = devices.first(where: { $0.goodsId == details.goodsId })
            let device = QiekjDevice(
                goodsId: details.goodsId,
                goodsName: details.name,
                categoryCode: details.categoryCode,
                shopId: existing?.shopId ?? devices.first?.shopId ?? "",
                orgId: existing?.orgId ?? devices.first?.orgId ?? "0",
                orgName: existing?.orgName ?? devices.first?.orgName ?? "",
                parentPointName: existing?.parentPointName ?? "",
                workStatus: existing?.workStatus ?? 10,
                skuId: skuId ?? existing?.skuId,
                imei: details.imei
            )
            upsertDevice(device)
            return device
        } catch {
            infoBanner = "添加设备失败：\(error.localizedDescription)"
            AppLog.shared.record(.error, module: .shower, "按 goodsId=\(trimmed) 添加设备失败：\(error.localizedDescription)")
            return nil
        }
    }

    // MARK: - Start / Poll / Stop / Settle Lifecycle

    func startShower(device: QiekjDevice) {
        guard pollTask == nil else { return }
        let token = KeychainStore.read(.qiekjToken)
        guard !token.isEmpty else {
            phase = .failed(message: "请先前往「我的」页登录胖乖生活")
            return
        }

        stopRequested = false
        everWorked = false
        lastIdentifyOrderNo = nil
        stopErrorMessage = nil
        phase = .preparing(device: device, step: "正在获取设备 SKU…")
        AppLog.shared.record(.info, module: .shower, "开始启动洗澡：隔间 \(device.goodsName) (goodsId=\(device.goodsId))")

        pollTask = Task { [weak self] in
            guard let self else { return }
            await self.runUnlockAndPoll(device: device, token: token)
        }
    }

    func resumePollingIfNeeded() {
        guard pollTask == nil, let snap = activeSnapshot else { return }
        let token = KeychainStore.read(.qiekjToken)
        guard !token.isEmpty else { return }
        pollTask = Task { [weak self] in
            guard let self else { return }
            await self.pollLoop(snapshot: snap, token: token)
        }
    }

    /// Immediately invokes `POST /goods/endWater` without waiting for the poll timer!
    func requestStopShower() {
        guard let snap = activeSnapshot else {
            phase = .idle
            return
        }
        let token = KeychainStore.read(.qiekjToken)
        guard !token.isEmpty else { return }

        stopRequested = true
        stopErrorMessage = nil
        phase = .running(
            device: snap.device,
            orderNo: snap.orderNo,
            startedAt: snap.startedAt,
            step: "正在发送远程停阀指令…",
            appEndSupported: snap.appEndSupported,
            stopping: true
        )
        AppLog.shared.record(.info, module: .shower, "用户点击「结束洗澡」：立即请求 goods/endWater (goodsId=\(snap.device.goodsId))")

        stopTask?.cancel()
        stopTask = Task { [weak self] in
            guard let self else { return }
            await self.performImmediateStop(snapshot: snap, token: token)
        }
    }

    /// Lets the user settle the bill directly if they pressed the physical stop button on the machine.
    func forceSettleCurrentSession() {
        guard let snap = activeSnapshot else { return }
        let token = KeychainStore.read(.qiekjToken)
        guard !token.isEmpty else { return }

        pollTask?.cancel()
        pollTask = nil
        stopTask?.cancel()
        stopTask = nil
        AppLog.shared.record(.info, module: .shower, "用户手动触发结算账单：orderNo=\(lastIdentifyOrderNo ?? snap.orderNo)")

        Task {
            await settleSession(snapshot: snap, token: token)
        }
    }

    func forceDismissActiveSession() {
        pollTask?.cancel()
        pollTask = nil
        stopTask?.cancel()
        stopTask = nil
        activeSnapshot = nil
        stopErrorMessage = nil
        phase = .idle
        AppLog.shared.record(.warn, module: .shower, "用户手动关闭本地洗澡状态面板")
    }

    func dismissResult() {
        if case .finished = phase {
            phase = .idle
        } else if case .failed = phase {
            phase = .idle
        }
    }

    private func runUnlockAndPoll(device: QiekjDevice, token: String) async {
        do {
            phase = .preparing(device: device, step: "正在获取设备 SKU…")
            let skuId = try await QiekjClient.shared.fetchSkuId(token: token, goodsId: device.goodsId)

            phase = .preparing(device: device, step: "正在检测设备状态…")
            _ = try? await QiekjClient.shared.syncWater(token: token, skuId: skuId)

            phase = .preparing(device: device, step: "正在读取设备能力与 IMEI…")
            let details = try await QiekjClient.shared.fetchDeviceDetails(token: token, goodsId: device.goodsId)
            let appEndSupported = details.supportAppUserFinish ?? true

            // Save discovered IMEI back to device cache
            let enrichedDevice = QiekjDevice(
                goodsId: device.goodsId,
                goodsName: details.name.isEmpty ? device.goodsName : details.name,
                categoryCode: details.categoryCode,
                shopId: device.shopId,
                orgId: device.orgId,
                orgName: device.orgName,
                parentPointName: device.parentPointName,
                workStatus: device.workStatus,
                skuId: skuId,
                imei: details.imei
            )
            upsertDevice(enrichedDevice)

            phase = .preparing(device: enrichedDevice, step: "正在进行风控预检…")
            try await QiekjClient.shared.checkUserIsRisk(token: token)

            phase = .preparing(device: enrichedDevice, step: "正在确认先用后付通道…")
            try await QiekjClient.shared.addUserAfterPayChannel(token: token)

            phase = .preparing(device: enrichedDevice, step: "正在进行位置校验…")
            let catCode = details.categoryCode.isEmpty ? "08" : details.categoryCode
            try await QiekjClient.shared.isCheckLocation(token: token, categoryCode: catCode, imei: details.imei)

            phase = .preparing(device: enrichedDevice, step: "正在云端开阀出水…")
            let orderNo = try await QiekjClient.shared.unlockWater(
                token: token,
                skuId: skuId,
                usePoints: usePoints
            )

            let snap = ActiveShowerSnapshot(
                device: enrichedDevice,
                skuId: skuId,
                orderNo: orderNo,
                startedAt: Date(),
                appEndSupported: appEndSupported
            )
            activeSnapshot = snap
            highlightedDevice = nil
            phase = .running(
                device: enrichedDevice,
                orderNo: orderNo,
                startedAt: snap.startedAt,
                step: "已开阀出水中",
                appEndSupported: appEndSupported,
                stopping: false
            )
            AppLog.shared.record(
                .info,
                module: .shower,
                "云端开阀成功：隔间 \(enrichedDevice.goodsName) orderNo=\(orderNo) skuId=\(skuId) appEndSupported=\(appEndSupported)"
            )

            try? await Task.sleep(for: .seconds(2))
            await pollLoop(snapshot: snap, token: token)
        } catch {
            pollTask = nil
            activeSnapshot = nil
            phase = .failed(message: error.localizedDescription)
            AppLog.shared.record(.error, module: .shower, "启动洗澡失败：\(error.localizedDescription)")
        }
    }

    private func pollLoop(snapshot: ActiveShowerSnapshot, token: String) async {
        defer { pollTask = nil }

        var lastLoggedSignature = ""
        var attempts = 0
        let maxAttempts = 720 // 3s * 720 = 36 minutes

        while attempts < maxAttempts {
            if Task.isCancelled || stopRequested { return }
            attempts += 1

            do {
                let sync = try await QiekjClient.shared.syncWater(token: token, skuId: snapshot.skuId)
                let sig = sync.map { "ws=\($0.workStatus.map(String.init) ?? "nil"),st=\($0.status.map(String.init) ?? "nil"),id=\($0.identify ?? "")" } ?? "nil"
                if sig != lastLoggedSignature {
                    lastLoggedSignature = sig
                    AppLog.shared.record(.info, module: .shower, "用水状态轮询变化（第 \(attempts) 次）：\(sig)")
                }

                if let sync {
                    if let id = sync.identify, !id.isEmpty {
                        lastIdentifyOrderNo = id
                    }
                    if sync.workStatus == 2 {
                        everWorked = true
                    }
                    // Hardware/platform reports session finished
                    if sync.status == 5 || (everWorked && sync.workStatus != 2) {
                        AppLog.shared.record(.info, module: .shower, "检测到设备侧已停水（\(sig)），自动进入结算")
                        await settleSession(snapshot: snapshot, token: token)
                        return
                    }
                } else {
                    // IMPORTANT: Never abort `.running` to `.failed` on nil!
                    // Only auto-settle if we already confirmed water was flowing earlier.
                    if everWorked {
                        AppLog.shared.record(.info, module: .shower, "设备已关闭会话（sync=nil 且已出水），自动进入结算")
                        await settleSession(snapshot: snapshot, token: token)
                        return
                    }
                }
            } catch {
                AppLog.shared.record(.warn, module: .shower, "轮询 syncWater 暂时失败（保持会话不中断）：\(error.localizedDescription)")
            }

            try? await Task.sleep(for: .seconds(3))
        }
    }

    private func performImmediateStop(snapshot: ActiveShowerSnapshot, token: String) async {
        pollTask?.cancel()
        pollTask = nil

        var endWaterSucceeded = false
        var endWaterFailureReason: String?

        do {
            try await QiekjClient.shared.endWater(token: token, goodsId: snapshot.device.goodsId)
            endWaterSucceeded = true
            AppLog.shared.record(.info, module: .shower, "远程停阀 goods/endWater 已受理，开始等待设备确认停水")
        } catch {
            endWaterFailureReason = error.localizedDescription
            AppLog.shared.record(.error, module: .shower, "远程停阀 goods/endWater 失败：\(error.localizedDescription)")
        }

        if endWaterSucceeded {
            phase = .running(
                device: snapshot.device,
                orderNo: snapshot.orderNo,
                startedAt: snapshot.startedAt,
                step: "远程停阀已受理，等待水控器回报结算…",
                appEndSupported: snapshot.appEndSupported,
                stopping: true
            )

            // Wait up to 12s for device to close session, then proceed to settle
            for i in 1...8 {
                try? await Task.sleep(for: .milliseconds(1500))
                if let sync = try? await QiekjClient.shared.syncWater(token: token, skuId: snapshot.skuId) {
                    if let id = sync.identify, !id.isEmpty { lastIdentifyOrderNo = id }
                    AppLog.shared.record(.info, module: .shower, "停阀后同步 #\(i)：workStatus=\(sync.workStatus ?? -1) status=\(sync.status ?? -1)")
                    if sync.status == 5 || sync.workStatus != 2 {
                        break
                    }
                } else {
                    AppLog.shared.record(.info, module: .shower, "停阀后同步 #\(i)：会话已关闭 (data=null)")
                    break
                }
            }

            await settleSession(snapshot: snapshot, token: token)
        } else {
            // Keep `.running` card visible with actionable buttons instead of trapping the user!
            stopRequested = false
            stopErrorMessage = "远程停阀失败：\(endWaterFailureReason ?? "设备无响应")。可点下方重试，或在设备上按停水键后点「立即结算」。"
            phase = .running(
                device: snapshot.device,
                orderNo: snapshot.orderNo,
                startedAt: snapshot.startedAt,
                step: "远程停阀未成功（会话保留中）",
                appEndSupported: snapshot.appEndSupported,
                stopping: false
            )
            resumePollingIfNeeded()
        }
    }

    private func settleSession(snapshot: ActiveShowerSnapshot, token: String) async {
        phase = .settling(device: snapshot.device, step: "正在生成后付结算账单…")
        let finalOrderNo = lastIdentifyOrderNo ?? snapshot.orderNo
        let elapsed = max(0, Int(Date().timeIntervalSince(snapshot.startedAt)))

        do {
            let orderId = try await QiekjClient.shared.createAfterPay(token: token, orderNo: finalOrderNo)
            phase = .settling(device: snapshot.device, step: "正在查询本次消费明细…")
            let detail = try await QiekjClient.shared.fetchOrderDetail(token: token, orderId: orderId)

            let receipt = QiekjShowerReceipt(
                orderNo: finalOrderNo,
                orderId: orderId,
                goodsName: snapshot.device.goodsName,
                realPrice: detail.realPrice,
                originPrice: detail.originPrice,
                payTypeName: detail.payTypeName,
                elapsedSeconds: elapsed,
                completedAt: Date()
            )
            activeSnapshot = nil
            stopErrorMessage = nil
            phase = .finished(receipt)
            AppLog.shared.record(.info, module: .shower, "洗澡结算完成：隔间 \(receipt.goodsName) 实付 ¥\(receipt.realPrice) 用时 \(elapsed)s")
            await refreshAll()
        } catch {
            AppLog.shared.record(.error, module: .shower, "结算账单失败（orderNo=\(finalOrderNo)）：\(error.localizedDescription)")
            // Keep running card with retry option if settle failed!
            stopRequested = false
            stopErrorMessage = "账单结算暂未成功：\(error.localizedDescription)。水控器停水后可稍等几秒点「立即结算」。"
            phase = .running(
                device: snapshot.device,
                orderNo: snapshot.orderNo,
                startedAt: snapshot.startedAt,
                step: "等待账单结算",
                appEndSupported: snapshot.appEndSupported,
                stopping: false
            )
        }
    }

    private func upsertDevice(_ device: QiekjDevice) {
        if let idx = devices.firstIndex(where: { $0.goodsId == device.goodsId }) {
            devices[idx] = device
        } else {
            devices.insert(device, at: 0)
        }
        saveDevicesCache()
    }

    private func saveDevicesCache() {
        if let encoded = try? JSONEncoder().encode(devices) {
            UserDefaults.standard.set(encoded, forKey: Self.cachedDevicesKey)
        }
    }

    private func persistActiveSnapshot() {
        if let activeSnapshot, let data = try? JSONEncoder().encode(activeSnapshot) {
            UserDefaults.standard.set(data, forKey: Self.activeSnapshotKey)
        } else {
            UserDefaults.standard.removeObject(forKey: Self.activeSnapshotKey)
        }
    }
}
