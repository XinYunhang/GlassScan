import CoreTransferable
import Foundation
import UniformTypeIdentifiers

struct ExportPayload: Codable {
    let app: String
    let exportedAt: Date
    let sanitized: Bool
    let recordCount: Int
    let records: [ExportRecord]
}

struct ExportRecord: Codable {
    let id: UUID
    let createdAt: Date
    let note: String
    let platform: String
    let source: String
    let symbology: String
    let stabilityHint: String
    let rawText: String
    let urlScheme: String
    let urlHost: String
    let urlPath: String
    let extractedDeviceHint: String
    let queryItems: [KeyValueEntry]
    let probes: [ProbeEntry]
}

struct ExportJSONDocument: Transferable {
    let filename: String
    let data: Data

    static var transferRepresentation: some TransferRepresentation {
        DataRepresentation(exportedContentType: .json) { item in
            item.data
        }
        .suggestedFileName { item in
            item.filename
        }
    }
}

enum ExportService {
    static func buildJSONData(records: [ScanRecord], sanitize: Bool) -> Data {
        let exported = records.map { record in
            let cleanedProbes = record.probes.map { probe in
                ProbeEntry(
                    id: probe.id,
                    probeType: probe.probeType,
                    title: probe.title,
                    method: probe.method,
                    endpoint: Sanitizer.sanitizeText(probe.endpoint, enabled: sanitize),
                    statusCode: probe.statusCode,
                    success: probe.success,
                    durationMs: probe.durationMs,
                    redirectChain: probe.redirectChain.map { Sanitizer.sanitizeText($0, enabled: sanitize) },
                    headers: sanitize ? Sanitizer.sanitizeHeaders(probe.headers) : probe.headers,
                    summary: Sanitizer.sanitizeText(probe.summary, enabled: sanitize),
                    rawBody: Sanitizer.sanitizeText(probe.rawBody, enabled: sanitize),
                    errorMessage: probe.errorMessage.map { Sanitizer.sanitizeText($0, enabled: sanitize) },
                    createdAt: probe.createdAt
                )
            }

            let cleanedQueries = record.queryItems.map { item in
                KeyValueEntry(
                    key: item.key,
                    value: Sanitizer.sanitizeText(item.value, enabled: sanitize)
                )
            }

            return ExportRecord(
                id: record.id,
                createdAt: record.createdAt,
                note: record.note,
                platform: record.platform.rawValue,
                source: record.source.rawValue,
                symbology: record.symbology,
                stabilityHint: record.stabilityHint,
                rawText: Sanitizer.sanitizeText(record.rawText, enabled: sanitize),
                urlScheme: record.urlScheme,
                urlHost: record.urlHost,
                urlPath: record.urlPath,
                extractedDeviceHint: Sanitizer.sanitizeText(record.extractedDeviceHint, enabled: sanitize),
                queryItems: cleanedQueries,
                probes: cleanedProbes
            )
        }

        let payload = ExportPayload(
            app: "GlassScan-iOS26",
            exportedAt: Date(),
            sanitized: sanitize,
            recordCount: exported.count,
            records: exported
        )

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return (try? encoder.encode(payload)) ?? Data("{}".utf8)
    }

    static func buildJSONString(records: [ScanRecord], sanitize: Bool) -> String {
        let data = buildJSONData(records: records, sanitize: sanitize)
        return String(data: data, encoding: .utf8) ?? "{}"
    }

    static func makeDocument(records: [ScanRecord], sanitize: Bool) -> ExportJSONDocument {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmm"
        let stamp = formatter.string(from: Date())
        let data = buildJSONData(records: records, sanitize: sanitize)
        return ExportJSONDocument(filename: "GlassScan-Export-\(stamp).json", data: data)
    }
}
