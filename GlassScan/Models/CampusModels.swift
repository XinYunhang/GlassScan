import Foundation

// MARK: - Qiekj (胖乖洗澡) Domain Models

struct QiekjBalance: Codable, Equatable, Sendable {
    let balance: String
    let integral: Int
    let integralAmount: String
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

    var id: String { goodsId }

    var isIdle: Bool {
        // Observed on campus showers: 10 or 1 = idle, 2 = in use
        guard let workStatus else { return true }
        return workStatus == 10 || workStatus == 1 || workStatus == 0
    }

    var statusLabel: String {
        guard let workStatus else { return "可尝试" }
        switch workStatus {
        case 0, 1, 10: return "空闲"
        case 2: return "使用中"
        default: return "状态 \(workStatus)"
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

enum PriceFormatter {
    static func fenToYuan(_ fen: Int) -> String {
        let sign = fen < 0 ? "-" : ""
        let absVal = abs(fen)
        return String(format: "%@¥%d.%02d", sign, absVal / 100, absVal % 100)
    }
}
