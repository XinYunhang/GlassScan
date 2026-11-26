import Foundation
import SwiftData

enum ScanPlatform: String, Codable, CaseIterable, Identifiable, Sendable {
    case pangguai = "pangguai"
    case ujing = "ujing"
    case shehuitong = "shehuitong"
    case alipay = "alipay"
    case wechat = "wechat"
    case web = "web"
    case text = "text"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .pangguai: return "胖乖生活"
        case .ujing: return "U净"
        case .shehuitong: return "社慧通饮水"
        case .alipay: return "支付宝"
        case .wechat: return "微信"
        case .web: return "网页链接"
        case .text: return "纯文本"
        }
    }

    var systemImage: String {
        switch self {
        case .pangguai: return "drop.fill"
        case .ujing: return "washer.fill"
        case .shehuitong: return "cup.and.saucer.fill"
        case .alipay: return "qrcode.viewfinder"
        case .wechat: return "message.fill"
        case .web: return "globe"
        case .text: return "doc.text"
        }
    }
}

enum ScanSource: String, Codable, Sendable {
    case camera = "camera"
    case photo = "photo"
    case paste = "paste"
    case manualProbe = "manual_probe"

    var displayName: String {
        switch self {
        case .camera: return "相机扫码"
        case .photo: return "相册识码"
        case .paste: return "剪贴板"
        case .manualProbe: return "账号同步"
        }
    }
}

struct KeyValueEntry: Codable, Equatable, Identifiable, Sendable {
    var id: String { "\(key)=\(value)" }
    let key: String
    let value: String
}

struct ProbeEntry: Codable, Equatable, Identifiable, Sendable {
    let id: UUID
    let probeType: String        // "http_get", "ujing_scan", "ujing_program", "ujing_stores", "qiekj_details", "qiekj_skus", "qiekj_latest", "qiekj_orders"
    let title: String
    let method: String
    let endpoint: String
    let statusCode: Int?
    let success: Bool
    let durationMs: Int
    let redirectChain: [String]
    let headers: [KeyValueEntry]
    let summary: String
    let rawBody: String
    let errorMessage: String?
    let createdAt: Date

    init(
        id: UUID = UUID(),
        probeType: String,
        title: String,
        method: String,
        endpoint: String,
        statusCode: Int? = nil,
        success: Bool,
        durationMs: Int,
        redirectChain: [String] = [],
        headers: [KeyValueEntry] = [],
        summary: String,
        rawBody: String = "",
        errorMessage: String? = nil,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.probeType = probeType
        self.title = title
        self.method = method
        self.endpoint = endpoint
        self.statusCode = statusCode
        self.success = success
        self.durationMs = durationMs
        self.redirectChain = redirectChain
        self.headers = headers
        self.summary = summary
        self.rawBody = rawBody
        self.errorMessage = errorMessage
        self.createdAt = createdAt
    }
}

@Model
final class ScanRecord {
    var id: UUID = UUID()
    var createdAt: Date = Date()
    var rawText: String = ""
    var symbology: String = "QR"
    var sourceRaw: String = ScanSource.camera.rawValue
    var platformRaw: String = ScanPlatform.text.rawValue
    var note: String = ""
    var urlScheme: String = ""
    var urlHost: String = ""
    var urlPath: String = ""
    var extractedDeviceHint: String = ""
    var stabilityHint: String = "首次记录"
    var queryItemsJSON: String = "[]"
    var probesJSON: String = "[]"

    init(
        id: UUID = UUID(),
        createdAt: Date = Date(),
        rawText: String,
        symbology: String = "QR",
        source: ScanSource = .camera,
        platform: ScanPlatform = .text,
        note: String = "",
        urlScheme: String = "",
        urlHost: String = "",
        urlPath: String = "",
        extractedDeviceHint: String = "",
        stabilityHint: String = "首次记录",
        queryItems: [KeyValueEntry] = [],
        probes: [ProbeEntry] = []
    ) {
        self.id = id
        self.createdAt = createdAt
        self.rawText = rawText
        self.symbology = symbology
        self.sourceRaw = source.rawValue
        self.platformRaw = platform.rawValue
        self.note = note
        self.urlScheme = urlScheme
        self.urlHost = urlHost
        self.urlPath = urlPath
        self.extractedDeviceHint = extractedDeviceHint
        self.stabilityHint = stabilityHint
        self.queryItemsJSON = Self.encodeJSON(queryItems)
        self.probesJSON = Self.encodeJSON(probes)
    }

    var source: ScanSource {
        get { ScanSource(rawValue: sourceRaw) ?? .camera }
        set { sourceRaw = newValue.rawValue }
    }

    var platform: ScanPlatform {
        get { ScanPlatform(rawValue: platformRaw) ?? .text }
        set { platformRaw = newValue.rawValue }
    }

    var queryItems: [KeyValueEntry] {
        get { Self.decodeJSON(queryItemsJSON, default: []) }
        set { queryItemsJSON = Self.encodeJSON(newValue) }
    }

    var probes: [ProbeEntry] {
        get { Self.decodeJSON(probesJSON, default: []) }
        set { probesJSON = Self.encodeJSON(newValue) }
    }

    var displayTitle: String {
        if !note.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return note
        }
        if !extractedDeviceHint.isEmpty {
            return "\(platform.displayName) · \(extractedDeviceHint)"
        }
        if !urlHost.isEmpty {
            return "\(platform.displayName) · \(urlHost)"
        }
        return String(rawText.prefix(36))
    }

    private static func encodeJSON<T: Encodable>(_ value: T) -> String {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(value),
              let string = String(data: data, encoding: .utf8) else {
            return "[]"
        }
        return string
    }

    private static func decodeJSON<T: Decodable>(_ raw: String, default fallback: T) -> T {
        guard let data = raw.data(using: .utf8) else { return fallback }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode(T.self, from: data)) ?? fallback
    }
}
