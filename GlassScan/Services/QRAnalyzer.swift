import Foundation

struct QRAnalysisResult {
    let platform: ScanPlatform
    let scheme: String
    let host: String
    let path: String
    let queryItems: [KeyValueEntry]
    let extractedDeviceHint: String
    let candidateGoodsId: String?
    let stabilityHint: String
}

enum QRAnalyzer {
    private static let deviceParamKeys: [String] = [
        "goodsid", "goods_id", "deviceid", "device_id", "deviceno", "device_no",
        "nimei", "imei", "sn", "code", "id", "mac", "uuid", "qr", "qrcode", "no"
    ]

    static func analyze(rawText: String, existingRecords: [ScanRecord]) -> QRAnalysisResult {
        let trimmed = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = trimmed.lowercased()

        let url = URL(string: trimmed)
        let components = URLComponents(string: trimmed)
        let scheme = url?.scheme ?? ""
        let host = url?.host ?? ""
        let path = url?.path ?? ""

        var queryEntries: [KeyValueEntry] = []
        if let items = components?.queryItems {
            queryEntries = items.map { KeyValueEntry(key: $0.name, value: $0.value ?? "") }
        }

        // Also check fragment query params (e.g. https://host/#/scan?goodsId=123)
        if let fragment = components?.fragment, let qIndex = fragment.firstIndex(of: "?") {
            let fragQuery = String(fragment[fragment.index(after: qIndex)...])
            if let fragComponents = URLComponents(string: "https://placeholder.local?\(fragQuery)"),
               let fragItems = fragComponents.queryItems {
                for item in fragItems {
                    queryEntries.append(KeyValueEntry(key: "hash.\(item.name)", value: item.value ?? ""))
                }
            }
        }

        let platform = detectPlatform(lower: lower, host: host.lowercased(), queryEntries: queryEntries)

        var deviceHint = ""
        var goodsId: String? = nil

        for entry in queryEntries {
            let keyClean = entry.key.replacingOccurrences(of: "hash.", with: "").lowercased()
            if deviceParamKeys.contains(keyClean), !entry.value.isEmpty {
                if deviceHint.isEmpty {
                    deviceHint = "\(keyClean)=\(entry.value)"
                }
                if (keyClean == "goodsid" || keyClean == "goods_id" || keyClean == "id"), goodsId == nil {
                    goodsId = entry.value
                }
            }
        }

        if deviceHint.isEmpty, !path.isEmpty, path != "/" {
            let lastSegment = (path as NSString).lastPathComponent
            if !lastSegment.isEmpty, lastSegment != "/" {
                deviceHint = lastSegment
            }
        }

        let stabilityHint = evaluateStability(
            rawText: trimmed,
            host: host,
            path: path,
            existingRecords: existingRecords
        )

        return QRAnalysisResult(
            platform: platform,
            scheme: scheme,
            host: host,
            path: path,
            queryItems: queryEntries,
            extractedDeviceHint: deviceHint,
            candidateGoodsId: goodsId,
            stabilityHint: stabilityHint
        )
    }

    private static func detectPlatform(
        lower: String,
        host: String,
        queryEntries: [KeyValueEntry]
    ) -> ScanPlatform {
        if host.contains("qiekj") || lower.contains("qiekj") || lower.contains("pangguai") || lower.contains("pgsh") {
            return .pangguai
        }
        if host.contains("ujing") || host.contains("midea") || lower.contains("ujing") || lower.contains("u-clean") {
            return .ujing
        }
        if host.contains("puwise") || lower.contains("puwise.com") || lower.contains("puwise.cn") {
            return .shehuitong
        }
        if host.contains("alipay") || lower.hasPrefix("alipays://") || lower.hasPrefix("alipay://") || lower.contains("qr.alipay.com") {
            // Check nested Alipay mini-program page param for ujing / qiekj hints
            let joined = queryEntries.map { $0.value.lowercased() }.joined(separator: " ")
            if joined.contains("ujing") || joined.contains("washer") {
                return .ujing
            }
            if joined.contains("qiekj") || joined.contains("pangguai") {
                return .pangguai
            }
            return .alipay
        }
        if host.contains("weixin.qq.com") || host.contains("wechat") || lower.hasPrefix("weixin://") {
            return .wechat
        }
        if lower.hasPrefix("http://") || lower.hasPrefix("https://") {
            return .web
        }
        return .text
    }

    private static func evaluateStability(
        rawText: String,
        host: String,
        path: String,
        existingRecords: [ScanRecord]
    ) -> String {
        let exactMatches = existingRecords.filter { $0.rawText == rawText }
        if !exactMatches.isEmpty {
            return "与历史完全一致（共 \(exactMatches.count + 1) 次 · 静态码）"
        }
        if !host.isEmpty {
            let sameEndpoint = existingRecords.filter { $0.urlHost == host && $0.urlPath == path }
            if !sameEndpoint.isEmpty {
                return "同路径但参数不同（不同设备或动态码 · 已有 \(sameEndpoint.count) 条）"
            }
        }
        return "首次记录（可隔几分钟再扫一次对比静/动态）"
    }
}
