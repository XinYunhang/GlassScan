import Foundation

// MARK: - Qiekj (胖乖洗澡) Domain Models

struct QiekjBalance: Codable, Equatable, Sendable {
    let balance: String
    let integral: Int
    let integralAmount: String
}

enum StallAvailability: String, Codable, Equatable, Sendable {
    case idle
    case busy
    case fault
    case unknown
}

struct QiekjDevice: Codable, Equatable, Identifiable, Hashable, Sendable {
    let goodsId: String
    let goodsName: String
    let categoryCode: String
    let shopId: String
    let orgId: String
    let orgName: String
    let parentPointName: String
    let workStatus: Int?
    let skuId: String?
    let imei: String?
    var remainSeconds: Int? = nil
    var errorMessage: String? = nil

    var id: String { goodsId }

    /// Parsed numeric layout, e.g. `90403` → building `9`, floor `4`, stall `3`; `120403` → building `12`, floor `4`, stall `3`.
    var parsedLocation: (building: Int, floor: Int, stall: Int)? {
        let digits = goodsName.filter(\.isNumber)
        if digits.count == 5,
           let b = Int(digits.prefix(1)),
           let f = Int(digits.dropFirst(1).prefix(2)),
           let s = Int(digits.suffix(2)) {
            return (b, f, s)
        }
        if digits.count == 6,
           let b = Int(digits.prefix(2)),
           let f = Int(digits.dropFirst(2).prefix(2)),
           let s = Int(digits.suffix(2)) {
            return (b, f, s)
        }
        if digits.count == 4,
           let b = Int(digits.prefix(1)),
           let f = Int(digits.dropFirst(1).prefix(1)),
           let s = Int(digits.suffix(2)) {
            return (b, f, s)
        }
        return nil
    }

    var buildingKey: String {
        if let loc = parsedLocation {
            return "\(loc.building)号楼"
        }
        return parentPointName.isEmpty ? "其他区域" : parentPointName
    }

    var buildingSortOrder: Int {
        parsedLocation?.building ?? 999
    }

    var floorNumber: Int? {
        parsedLocation?.floor
    }

    var stallNumber: Int? {
        parsedLocation?.stall
    }

    var shortStallTitle: String {
        if let stall = stallNumber {
            return String(format: "%02d号隔间", stall)
        }
        return goodsName
    }

    var floorLabel: String {
        if let loc = parsedLocation {
            return "\(loc.building)号楼 \(loc.floor)层"
        }
        return parentPointName.isEmpty ? orgName : parentPointName
    }

    var availability: StallAvailability {
        if let errorMessage, !errorMessage.isEmpty {
            return .fault
        }
        if let remainSeconds, remainSeconds > 0 {
            return .busy
        }
        guard let ws = workStatus else {
            return .unknown
        }
        switch ws {
        case 0, 1, 10:
            return .idle
        case 2, 20, 21, 22:
            return .busy
        case 3, 4, 30, 40, 50:
            return .fault
        default:
            return .unknown
        }
    }

    var isIdle: Bool {
        availability == .idle
    }

    var isBusy: Bool {
        availability == .busy
    }

    var statusLabel: String {
        switch availability {
        case .idle:
            return "空闲"
        case .busy:
            if let remainSeconds, remainSeconds > 0 {
                return "使用中 · 约\(max(1, remainSeconds / 60))分"
            }
            return "使用中"
        case .fault:
            return errorMessage?.isEmpty == false ? (errorMessage ?? "故障") : "离线/维护"
        case .unknown:
            if let ws = workStatus {
                return "状态 \(ws)"
            }
            return "未刷新"
        }
    }
}

struct QiekjDeviceDetails: Equatable, Sendable {
    let goodsId: String
    let name: String
    let imei: String
    let categoryCode: String
    let supportAppUserFinish: Bool?
    let payment: String
}

struct QiekjSyncStatus: Equatable, Sendable {
    let workStatus: Int?
    let status: Int?
    let identify: String?
}

struct QiekjOrderSummary: Codable, Equatable, Identifiable, Sendable {
    let orderId: String
    let orderNo: String
    let goodsId: String
    let goodsName: String
    let skuId: String
    let categoryCode: String
    let shopId: String
    let orgId: String
    let shopName: String
    let payPrice: String
    let createTime: String

    var id: String { orderNo.isEmpty ? orderId : orderNo }
}

struct QiekjShowerReceipt: Equatable, Sendable {
    let orderNo: String
    let orderId: String
    let goodsName: String
    let realPrice: String
    let originPrice: String
    let payTypeName: String
    let elapsedSeconds: Int
    let completedAt: Date
}

enum ShowerSessionPhase: Equatable {
    case idle
    case preparing(device: QiekjDevice, step: String)
    case running(
        device: QiekjDevice,
        orderNo: String,
        startedAt: Date,
        step: String,
        appEndSupported: Bool,
        stopping: Bool
    )
    case settling(device: QiekjDevice, step: String)
    case finished(QiekjShowerReceipt)
    case failed(message: String)
}

// MARK: - Ujing (U净洗衣 / 烘干) Domain Models

struct UjingScanInfo: Equatable, Sendable {
    let rawQRCode: String
    let deviceId: String
    let deviceTypeId: Int
    let moduleType: Int
    let createOrderEnabled: Bool
    let status: String
    let reason: String
    var orderId: String = ""
    var remainSeconds: Int? = nil

    var isCloudStart: Bool {
        moduleType != 1 && moduleType != 5
    }

    var moduleLabel: String {
        switch moduleType {
        case 0: return "2G"
        case 1: return "蓝牙 Nordic"
        case 2: return "NB-IoT"
        case 3: return "2G + 蓝牙"
        case 4: return "NB + 蓝牙"
        case 5: return "蓝牙 Cypress"
        case 6: return "Wi-Fi Mesh"
        case 7: return "4G 云端"
        default: return "云端 (\(moduleType))"
        }
    }

    var badgeText: String {
        if createOrderEnabled { return "空闲可下单" }
        if status == "8" || reason.contains("离线") { return "离线" }
        if status == "2" || reason.contains("故障") { return "故障" }
        return "使用中"
    }
}

struct UjingWashModel: Equatable, Identifiable, Sendable {
    let workModelId: Int
    let workModelName: String
    let basePriceFen: Int
    let timeMinutes: Int
    let hide: Bool
    let isDefault: Bool
    let additionDryTimeTitle: String
    let additionDryTimeOptions: [Int]

    var id: Int { workModelId }

    var hasAdditionDryTime: Bool {
        !additionDryTimeOptions.filter { $0 > 0 && $0 % 10 == 0 }.isEmpty
    }

    func displayTitle(isDryer: Bool) -> String {
        let base = workModelName.isEmpty ? (isDryer ? "烘干" : "洗涤模式") : workModelName
        if isDryer && !hasAdditionDryTime && timeMinutes > 0 {
            return "\(base) · \(timeMinutes)分钟"
        }
        return base
    }

    func estimatedPriceFen(selectedDryMinutes: Int?) -> Int {
        guard hasAdditionDryTime, let selectedDryMinutes, basePriceFen > 0 else {
            return basePriceFen
        }
        let baseMin = max(timeMinutes, 10)
        let extra = max(selectedDryMinutes - baseMin, 0) * basePriceFen / baseMin
        return basePriceFen + extra
    }
}

struct UjingProgramInfo: Equatable, Sendable {
    let deviceId: String
    let deviceNo: String
    let deviceTypeId: Int
    let deviceTypeName: String
    let storeId: String
    let storeName: String
    let moduleType: Int
    let type: Int
    let isWashTemperatureEnable: Bool
    let isForceDetergent: Bool
    let isForceDisinfectant: Bool
    let models: [UjingWashModel]

    var isDryer: Bool {
        type == 2 || deviceTypeId == 3 || deviceTypeName.contains("烘干") || deviceTypeName.contains("干衣")
    }

    var visibleModels: [UjingWashModel] {
        models.filter { !$0.hide }
    }
}

struct UjingActiveOrder: Codable, Equatable, Sendable {
    let orderId: String
    let orderNo: String
    let deviceId: String
    let deviceName: String
    let storeName: String
    let modelName: String
    let isDryer: Bool
    let estimatedPriceText: String
    let payPriceText: String
    let status: String
    let statusRemark: String
    let payFlag: Int
    let remainSeconds: Int
    let durationSeconds: Int
    let createdAt: Date
    let lastSyncedAt: Date

    var statusLabel: String {
        if !statusRemark.isEmpty { return statusRemark }
        switch status {
        case "0": return "已创建"
        case "10": return "待支付（2分钟锁机）"
        case "17": return "支付确认中"
        case "20": return "已支付 · 待启动"
        case "21": return "启动中…"
        case "22": return "自洁启动中"
        case "24": return "投放洗衣液中…"
        case "29": return "订单保护中"
        case "30": return "筒自洁中"
        case "35": return "自洁完成 · 待启动"
        case "40": return isDryer ? "烘干中" : "洗涤中"
        case "50": return isDryer ? "烘干完成 · 请取衣" : "洗涤完成 · 请取衣"
        case "51": return "支付超时"
        case "52": return "启动失败"
        case "53", "60": return "已取消"
        default: return "状态 \(status)"
        }
    }

    var canPay: Bool {
        payFlag == 0 && (status == "0" || status == "10" || status == "17")
    }

    var canCancel: Bool {
        status == "0" || status == "10" || status == "17"
    }

    var canStart: Bool {
        status == "20" || status == "22" || status == "35"
    }

    var isRunning: Bool {
        status == "21" || status == "24" || status == "29" || status == "30" || status == "40"
    }

    var isDone: Bool {
        status == "50"
    }

    var isTerminal: Bool {
        status == "50" || status == "51" || status == "52" || status == "53" || status == "60"
    }

    var effectivePriceText: String {
        if !payPriceText.isEmpty && payPriceText != "0" && payPriceText != "0.00" {
            return payPriceText.hasPrefix("¥") ? payPriceText : "¥\(payPriceText)"
        }
        return estimatedPriceText
    }
}

struct UjingStoreBoardItem: Codable, Equatable, Identifiable, Sendable {
    let id: String
    let name: String
    let subjectName: String
    let washerFree: Int
    let washerTotal: Int
    let dryerFree: Int
    let dryerTotal: Int
    let shoeFree: Int
    let shoeTotal: Int
}

struct FavoriteUjingStore: Codable, Equatable, Identifiable, Sendable {
    let id: String
    let name: String
    let keyword: String
    let lat: Double
    let lng: Double
}

struct SavedUjingDevice: Codable, Equatable, Identifiable, Sendable {
    let deviceId: String
    let rawQRCode: String
    var deviceNo: String
    var deviceTypeId: Int
    var deviceTypeName: String
    var storeId: String
    var storeName: String
    var moduleType: Int
    var customAlias: String
    var savedAt: Date
    var lastCreateOrderEnabled: Bool?
    var lastStatus: String
    var lastReason: String
    var lastCheckedAt: Date?
    var lastOrderId: String? = nil
    var estimatedRemainSeconds: Int? = nil
    var estimatedFinishAt: Date? = nil
    var remainTimeSource: String? = nil

    var id: String { deviceId }

    var isDryer: Bool {
        deviceTypeId == 3 || deviceTypeName.contains("烘干") || deviceTypeName.contains("干衣")
    }

    var displayName: String {
        let trimmed = customAlias.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { return trimmed }
        let composed = [deviceTypeName, deviceNo].filter { !$0.isEmpty }.joined(separator: " ")
        return composed.isEmpty ? "U净机器 \(String(deviceId.suffix(4)))" : composed
    }

    var subtitle: String {
        let trimmedAlias = customAlias.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedAlias.isEmpty {
            let parts = [storeName, deviceNo].filter { !$0.isEmpty }
            return parts.isEmpty ? deviceTypeName : parts.joined(separator: " · ")
        }
        return storeName.isEmpty ? "已保存固定二维码" : storeName
    }

    var statusBadgeText: String {
        guard let enabled = lastCreateOrderEnabled else { return "点刷新查状态" }
        if enabled { return "空闲可锁机" }
        if lastStatus == "8" || lastReason.contains("离线") { return "离线" }
        if lastStatus == "2" || lastReason.contains("故障") { return "故障" }
        return "使用中"
    }

    var isKnownIdle: Bool { lastCreateOrderEnabled == true }
    var isKnownBusy: Bool { lastCreateOrderEnabled == false }

    func liveRemainingSeconds(at now: Date) -> Int? {
        guard isKnownBusy, let finishAt = estimatedFinishAt else { return nil }
        let remaining = Int(finishAt.timeIntervalSince(now))
        return remaining > 0 ? remaining : nil
    }

    func estimatedFinishClockText(at now: Date) -> String? {
        guard isKnownBusy, let finishAt = estimatedFinishAt, finishAt > now else { return nil }
        let comps = Calendar.current.dateComponents([.hour, .minute], from: finishAt)
        guard let h = comps.hour, let m = comps.minute else { return nil }
        return String(format: "%02d:%02d", h, m)
    }
}

enum PriceFormatter {
    static func fenToYuan(_ fen: Int) -> String {
        let sign = fen < 0 ? "-" : ""
        let absVal = abs(fen)
        return String(format: "%@¥%d.%02d", sign, absVal / 100, absVal % 100)
    }
}
