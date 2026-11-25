import CoreTransferable
import Foundation
import Observation
import UniformTypeIdentifiers

enum LogLevel: String, Codable, CaseIterable, Sendable {
    case info = "INFO"
    case net = "NET"
    case warn = "WARN"
    case error = "ERROR"
}

enum LogModule: String, Codable, CaseIterable, Identifiable, Sendable {
    case shower = "洗澡"
    case laundry = "洗衣"
    case scan = "扫码"
    case auth = "账号"
    case network = "网络"
    case system = "系统"

    var id: String { rawValue }
}

struct AppLogEntry: Codable, Identifiable, Equatable, Sendable {
    let id: UUID
    let timestamp: Date
    let level: LogLevel
    let module: LogModule
    let message: String
    let detail: String

    init(
        id: UUID = UUID(),
        timestamp: Date = Date(),
        level: LogLevel,
        module: LogModule,
        message: String,
        detail: String = ""
    ) {
        self.id = id
        self.timestamp = timestamp
        self.level = level
        self.module = module
        self.message = message
        self.detail = detail
    }
}

struct ExportLogDocument: Transferable {
    let filename: String
    let text: String

    static var transferRepresentation: some TransferRepresentation {
        DataRepresentation(exportedContentType: .plainText) { item in
            Data(item.text.utf8)
        }
        .suggestedFileName { item in
            item.filename
        }
    }
}

@MainActor
@Observable
final class AppLog {
    static let shared = AppLog()

    private(set) var entries: [AppLogEntry] = []
    private let maxEntries = 500
    private let storageURL: URL

    var errorCount: Int {
        entries.filter { $0.level == .error || $0.level == .warn }.count
    }

    private init() {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        self.storageURL = dir.appendingPathComponent("glassscan_app_log.json")
        loadFromDisk()
    }

    func record(
        _ level: LogLevel,
        module: LogModule,
        _ message: String,
        detail: String = ""
    ) {
        let safeMessage = Sanitizer.sanitizeText(message, enabled: true)
        let clippedDetail = detail.count > 4000 ? String(detail.prefix(4000)) + "\n...(已截断)" : detail
        let safeDetail = Sanitizer.sanitizeText(clippedDetail, enabled: true)

        let entry = AppLogEntry(
            level: level,
            module: module,
            message: safeMessage,
            detail: safeDetail
        )
        entries.insert(entry, at: 0)
        if entries.count > maxEntries {
            entries.removeLast(entries.count - maxEntries)
        }
        saveToDisk()
    }

    nonisolated static func log(
        _ level: LogLevel,
        module: LogModule,
        _ message: String,
        detail: String = ""
    ) {
        Task { @MainActor in
            AppLog.shared.record(level, module: module, message, detail: detail)
        }
    }

    func clear() {
        entries.removeAll()
        try? FileManager.default.removeItem(at: storageURL)
    }

    func formattedExportText(filtered: [AppLogEntry]? = nil) -> String {
        let list = (filtered ?? entries).reversed()
        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"

        var lines: [String] = [
            "# GlassScan 运行日志（已自动脱敏）",
            "# 导出时间：\(df.string(from: Date()))",
            "# 条数：\(list.count)",
            ""
        ]

        for entry in list {
            lines.append("[\(df.string(from: entry.timestamp))] [\(entry.level.rawValue)] [\(entry.module.rawValue)] \(entry.message)")
            if !entry.detail.isEmpty {
                let indented = entry.detail
                    .split(separator: "\n", omittingEmptySubsequences: false)
                    .map { "    \($0)" }
                    .joined(separator: "\n")
                lines.append(indented)
            }
        }
        return lines.joined(separator: "\n")
    }

    func makeExportDocument(filtered: [AppLogEntry]? = nil) -> ExportLogDocument {
        let df = DateFormatter()
        df.dateFormat = "yyyyMMdd-HHmm"
        let filename = "GlassScan-Log-\(df.string(from: Date())).txt"
        return ExportLogDocument(filename: filename, text: formattedExportText(filtered: filtered))
    }

    private func loadFromDisk() {
        guard let data = try? Data(contentsOf: storageURL) else { return }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        if let decoded = try? decoder.decode([AppLogEntry].self, from: data) {
            entries = decoded
        }
    }

    private func saveToDisk() {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        if let data = try? encoder.encode(entries) {
            try? data.write(to: storageURL, options: .atomic)
        }
    }
}
