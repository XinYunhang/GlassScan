import CryptoKit
import Foundation

actor QiekjClient {
    static let shared = QiekjClient()

    private let baseURL = "https://userapi.qiekj.com"
    private let apiVersion = "1.60.3"
    private let channel = "android_app"
    private let appSecret = "nFU9pbG8YQoAe1kFh+E7eyrdlSLglwEJeA0wwHB1j5o="

    private let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 15
        config.timeoutIntervalForResource = 25
        return URLSession(configuration: config)
    }()

    // MARK: - Auth

    func sendCode(phone: String) async throws -> String {
        let outcome = await postForm(
            probeType: "qiekj_sms",
            title: "胖乖发送验证码",
            path: "/common/sms/sendCode",
            token: nil,
            form: [("phone", phone), ("template", "reg")],
            isLoginAPI: true
        )
        if outcome.entry.success {
            return "胖乖验证码已发送"
        }
        throw NSError(domain: "QiekjClient", code: outcome.businessCode ?? -1, userInfo: [
            NSLocalizedDescriptionKey: outcome.businessMessage ?? outcome.entry.summary
        ])
    }

    func login(phone: String, verifyCode: String) async throws -> String {
        let outcome = await postForm(
            probeType: "qiekj_login",
            title: "胖乖登录",
            path: "/user/reg",
            token: nil,
            form: [("channel", channel), ("phone", phone), ("verify", verifyCode)],
            isLoginAPI: true
        )
        if let json = outcome.jsonObject,
           let dataObj = json["data"] as? [String: Any],
           let token = dataObj["token"] as? String,
           !token.isEmpty {
            return token
        }
        throw NSError(domain: "QiekjClient", code: outcome.businessCode ?? -1, userInfo: [
            NSLocalizedDescriptionKey: outcome.businessMessage ?? "未获取到胖乖 Token"
        ])
    }

    // MARK: - Probing

    func probeGoods(goodsId: String, token: String) async -> [ProbeEntry] {
        guard !token.isEmpty else {
            return [
                ProbeEntry(
                    probeType: "qiekj_details",
                    title: "胖乖设备探测（需登录）",
                    method: "POST",
                    endpoint: "\(baseURL)/goods/normal/details",
                    success: false,
                    durationMs: 0,
                    summary: "未配置胖乖 Token，前往「账号」页登录后可查设备与历史订单"
                )
            ]
        }

        async let details = postForm(
            probeType: "qiekj_details",
            title: "胖乖设备详情 (goods/normal/details)",
            path: "/goods/normal/details",
            token: token,
            form: [("goodsId", goodsId), ("token", token)],
            isLoginAPI: false
        )
        async let skus = postForm(
            probeType: "qiekj_skus",
            title: "胖乖设备 SKU (goods/normal/skus)",
            path: "/goods/normal/skus",
            token: token,
            form: [("goodsId", goodsId), ("token", token)],
            isLoginAPI: false
        )

        let (d, s) = await (details, skus)
        return [d.entry, s.entry]
    }

    /// Syncs balance, recent orders (`order/list`), and latest used devices across common category codes (including water/shower).
    func syncAccountSnapshot(token: String) async -> [ProbeEntry] {
        guard !token.isEmpty else { return [] }
        var entries: [ProbeEntry] = []

        let balance = await postForm(
            probeType: "qiekj_balance",
            title: "胖乖账户余额 (user/balance)",
            path: "/user/balance",
            token: token,
            form: [("token", token)],
            isLoginAPI: false
        )
        entries.append(balance.entry)

        let orders = await postForm(
            probeType: "qiekj_orders",
            title: "胖乖历史订单 (order/list · 最近 10 笔)",
            path: "/order/list",
            token: token,
            form: [("page", "1"), ("pageSize", "10"), ("token", token)],
            isLoginAPI: false
        )
        entries.append(orders.entry)

        // Probe common category codes: 1~6 covers laundry/water/shower/dryer variants across campuses
        for code in ["1", "2", "3", "4", "5", "6"] {
            let latest = await postForm(
                probeType: "qiekj_latest_\(code)",
                title: "胖乖最近使用设备 (categoryCode=\(code))",
                path: "/goods/latestUsed",
                token: token,
                form: [("categoryCode", code), ("token", token)],
                isLoginAPI: false
            )
            // Keep all successful non-empty lists, or code 5 as baseline
            if code == "5" || (latest.entry.success && latest.rawListCount > 0) {
                entries.append(latest.entry)
            }
        }

        return entries
    }

    // MARK: - Internal

    private struct RequestOutcome {
        let entry: ProbeEntry
        let jsonObject: [String: Any]?
        let businessCode: Int?
        let businessMessage: String?
        let rawListCount: Int
    }

    private func postForm(
        probeType: String,
        title: String,
        path: String,
        token: String?,
        form: [(String, String)],
        isLoginAPI: Bool
    ) async -> RequestOutcome {
        let started = Date()
        let fullURLString = "\(baseURL)\(path)"
        guard let url = URL(string: fullURLString) else {
            return RequestOutcome(
                entry: ProbeEntry(
                    probeType: probeType,
                    title: title,
                    method: "POST",
                    endpoint: fullURLString,
                    success: false,
                    durationMs: 0,
                    summary: "无效 URL"
                ),
                jsonObject: nil,
                businessCode: nil,
                businessMessage: nil,
                rawListCount: 0
            )
        }

        let timestamp = String(Int64(Date().timeIntervalSince1970 * 1000))
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue(apiVersion, forHTTPHeaderField: "Version")
        request.setValue(channel, forHTTPHeaderField: "channel")
        request.setValue("Redmi", forHTTPHeaderField: "phoneBrand")
        request.setValue("okhttp/3.14.9", forHTTPHeaderField: "User-Agent")
        request.setValue("application/x-www-form-urlencoded;charset=UTF-8", forHTTPHeaderField: "Content-Type")
        request.setValue(timestamp, forHTTPHeaderField: "timestamp")

        if let token, !token.isEmpty {
            request.setValue(token, forHTTPHeaderField: "token")
            request.setValue(token, forHTTPHeaderField: "Authorization")
            if !isLoginAPI {
                let signInput = "appSecret=\(appSecret)&channel=\(channel)&timestamp=\(timestamp)&token=\(token)&version=\(apiVersion)\(path)"
                let digest = SHA256.hash(data: Data(signInput.utf8))
                let hex = digest.map { String(format: "%02x", $0) }.joined()
                request.setValue(hex, forHTTPHeaderField: "sign")
            }
        }

        let bodyString = form.map { key, value in
            "\(formEncode(key))=\(formEncode(value))"
        }.joined(separator: "&")
        request.httpBody = Data(bodyString.utf8)

        do {
            let (data, response) = try await session.data(for: request)
            let elapsed = Int(Date().timeIntervalSince(started) * 1000)
            let statusCode = (response as? HTTPURLResponse)?.statusCode
            let pretty = Sanitizer.prettyJSONString(from: data, maxBytes: 24_576)

            let jsonObj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            let code = parseInt(jsonObj?["code"])
            let msg = jsonObj?["msg"] as? String ?? jsonObj?["message"] as? String
            let listCount = (jsonObj?["data"] as? [Any])?.count ?? 0
            let isSuccess = (code == 0 || code == 200)

            var summary = "HTTP \(statusCode ?? 0)"
            if let code { summary += " · code=\(code)" }
            if listCount > 0 { summary += " · \(listCount) 条" }
            if let msg, !msg.isEmpty { summary += " · \(msg)" }

            return RequestOutcome(
                entry: ProbeEntry(
                    probeType: probeType,
                    title: title,
                    method: "POST",
                    endpoint: fullURLString,
                    statusCode: statusCode,
                    success: isSuccess,
                    durationMs: elapsed,
                    summary: summary,
                    rawBody: pretty,
                    errorMessage: isSuccess ? nil : msg
                ),
                jsonObject: jsonObj,
                businessCode: code,
                businessMessage: msg,
                rawListCount: listCount
            )
        } catch {
            let elapsed = Int(Date().timeIntervalSince(started) * 1000)
            return RequestOutcome(
                entry: ProbeEntry(
                    probeType: probeType,
                    title: title,
                    method: "POST",
                    endpoint: fullURLString,
                    success: false,
                    durationMs: elapsed,
                    summary: "网络错误：\(error.localizedDescription)",
                    errorMessage: error.localizedDescription
                ),
                jsonObject: nil,
                businessCode: nil,
                businessMessage: error.localizedDescription,
                rawListCount: 0
            )
        }
    }

    private func formEncode(_ string: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return string.addingPercentEncoding(withAllowedCharacters: allowed) ?? string
    }

    private func parseInt(_ any: Any?) -> Int? {
        if let i = any as? Int { return i }
        if let n = any as? NSNumber { return n.intValue }
        if let s = any as? String { return Int(s) }
        return nil
    }
}
