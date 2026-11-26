import Foundation
import Observation
import SwiftData

@MainActor
@Observable
final class ProbeCoordinator {
    var autoHTTPProbe: Bool {
        didSet { UserDefaults.standard.set(autoHTTPProbe, forKey: "autoHTTPProbe") }
    }
    var autoUjingProbe: Bool {
        didSet { UserDefaults.standard.set(autoUjingProbe, forKey: "autoUjingProbe") }
    }
    var autoQiekjProbe: Bool {
        didSet { UserDefaults.standard.set(autoQiekjProbe, forKey: "autoQiekjProbe") }
    }
    var sanitizeExport: Bool {
        didSet { UserDefaults.standard.set(sanitizeExport, forKey: "sanitizeExport") }
    }

    var isProbing: Bool = false
    var statusBanner: String = "对准二维码自动探测并保存"
    var lastError: String?

    init() {
        let defaults = UserDefaults.standard
        self.autoHTTPProbe = defaults.object(forKey: "autoHTTPProbe") as? Bool ?? true
        self.autoUjingProbe = defaults.object(forKey: "autoUjingProbe") as? Bool ?? true
        self.autoQiekjProbe = defaults.object(forKey: "autoQiekjProbe") as? Bool ?? true
        self.sanitizeExport = defaults.object(forKey: "sanitizeExport") as? Bool ?? true
    }

    func handleScannedCode(
        rawText: String,
        symbology: String,
        source: ScanSource,
        context: ModelContext,
        existingRecords: [ScanRecord]
    ) async -> ScanRecord {
        let trimmed = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
        isProbing = true
        lastError = nil
        statusBanner = "正在解析与自动查询数据…"
        defer {
            isProbing = false
        }

        let analysis = QRAnalyzer.analyze(rawText: trimmed, existingRecords: existingRecords)
        let record = ScanRecord(
            rawText: trimmed,
            symbology: symbology,
            source: source,
            platform: analysis.platform,
            urlScheme: analysis.scheme,
            urlHost: analysis.host,
            urlPath: analysis.path,
            extractedDeviceHint: analysis.extractedDeviceHint,
            stabilityHint: analysis.stabilityHint,
            queryItems: analysis.queryItems,
            probes: []
        )
        context.insert(record)
        try? context.save()

        let probes = await runProbes(
            rawText: trimmed,
            platform: analysis.platform,
            candidateGoodsId: analysis.candidateGoodsId
        )
        record.probes = probes
        try? context.save()

        let successCount = probes.filter(\.success).count
        statusBanner = probes.isEmpty
            ? "已保存原始扫码数据"
            : "已保存 · 探测 \(successCount)/\(probes.count) 项成功"

        return record
    }

    func reprobe(record: ScanRecord, context: ModelContext) async {
        isProbing = true
        defer { isProbing = false }

        let analysis = QRAnalyzer.analyze(rawText: record.rawText, existingRecords: [])
        let probes = await runProbes(
            rawText: record.rawText,
            platform: record.platform,
            candidateGoodsId: analysis.candidateGoodsId
        )
        record.probes = probes
        try? context.save()
    }

    func probeUjingDirectly(record: ScanRecord, context: ModelContext) async {
        isProbing = true
        defer { isProbing = false }

        let token = KeychainStore.read(.ujingToken)
        let extra = await UjingClient.shared.probeQRCode(rawQRCode: record.rawText, token: token)
        var current = record.probes.filter { !$0.probeType.hasPrefix("ujing_") }
        current.append(contentsOf: extra)
        record.probes = current
        if extra.contains(where: \.success) {
            record.platform = .ujing
        }
        try? context.save()
    }

    func saveManualSnapshot(
        platform: ScanPlatform,
        title: String,
        probes: [ProbeEntry],
        context: ModelContext
    ) -> ScanRecord {
        let record = ScanRecord(
            rawText: "[\(platform.displayName) 账号数据同步] \(title)",
            symbology: "API_SYNC",
            source: .manualProbe,
            platform: platform,
            note: title,
            stabilityHint: "主动同步采样",
            probes: probes
        )
        context.insert(record)
        try? context.save()
        return record
    }

    private func runProbes(
        rawText: String,
        platform: ScanPlatform,
        candidateGoodsId: String?
    ) async -> [ProbeEntry] {
        var results: [ProbeEntry] = []

        // 1. Generic read-only HTTP probe for any http(s) QR URL
        if autoHTTPProbe, rawText.lowercased().hasPrefix("http://") || rawText.lowercased().hasPrefix("https://") {
            let httpEntry = await HTTPProber.probe(urlString: rawText)
            results.append(httpEntry)
        }

        // 2. Ujing probe if Ujing token exists and code looks like Ujing / Alipay / unknown (skip Puwise drinking water)
        let ujingToken = KeychainStore.read(.ujingToken)
        if autoUjingProbe, !ujingToken.isEmpty {
            let shouldTryUjing = (platform == .ujing || platform == .alipay || platform == .web || platform == .text)
            if shouldTryUjing {
                let ujingEntries = await UjingClient.shared.probeQRCode(rawQRCode: rawText, token: ujingToken)
                results.append(contentsOf: ujingEntries)
            }
        }

        // 2.5 Puwise (社慧通饮水) local identification
        if platform == .shehuitong {
            results.append(
                ProbeEntry(
                    probeType: "shehuitong_hint",
                    title: "社慧通饮水机二维码 (puwise.com)",
                    method: "LOCAL",
                    endpoint: rawText,
                    success: true,
                    durationMs: 0,
                    summary: "已识别为社慧通校园饮水机固定码并保存；该平台仅限支付宝/微信「社慧通」小程序扣款，暂不支持独立 HTTP 鉴权。"
                )
            )
        }

        // 3. Qiekj probe if Qiekj token exists and platform is Pangguai with candidate goodsId
        let qiekjToken = KeychainStore.read(.qiekjToken)
        if autoQiekjProbe, platform == .pangguai {
            if let goodsId = candidateGoodsId, !goodsId.isEmpty {
                let qiekjEntries = await QiekjClient.shared.probeGoods(goodsId: goodsId, token: qiekjToken)
                results.append(contentsOf: qiekjEntries)
            } else if !qiekjToken.isEmpty {
                results.append(
                    ProbeEntry(
                        probeType: "qiekj_hint",
                        title: "胖乖二维码参数提示",
                        method: "LOCAL",
                        endpoint: "local://qiekj-parser",
                        success: true,
                        durationMs: 0,
                        summary: "已识别为胖乖码，但未发现标准 goodsId 参数；已保留完整原文供分析，也可在「账号」页同步历史订单"
                    )
                )
            }
        }

        return results
    }
}
