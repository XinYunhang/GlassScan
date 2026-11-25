import Foundation

actor UjingClient {
    static let shared = UjingClient()

    private let baseURL = "https://phoenix.ujing.online/api/v1"

    private enum Identity {
        case account   // ZI / 2.4.3
        case query     // ZA / 2.4.18 (no weex/UA)
        case business  // BI / 2.4.2 + weex-version
    }

    private let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 15
        config.timeoutIntervalForResource = 25
        return URLSession(configuration: config)
    }()

    // MARK: - Auth

    func requestCaptcha(mobile: String) async throws -> String {
        let result = await performRequest(
            probeType: "ujing_captcha",
            title: "U净发送验证码",
            method: "GET",
            path: "captcha",
            identity: .account,
            token: nil,
            query: [
                ("mobile", mobile),
                ("type", "1"),
                ("sessionId", "AFS_SWITCH_OFF"),
                ("token", "AFS_SWITCH_OFF"),
                ("sig", "AFS_SWITCH_OFF")
            ],
            jsonBody: nil
        )
        if result.entry.success {
            return "验证码已发送，请查收短信"
        }
        throw NSError(domain: "UjingClient", code: result.businessCode ?? -1, userInfo: [
            NSLocalizedDescriptionKey: result.businessMessage ?? result.entry.summary
        ])
    }

    func login(mobile: String, captcha: String) async throws -> String {
        let result = await performRequest(
            probeType: "ujing_login",
            title: "U净登录",
            method: "POST",
            path: "login",
            identity: .account,
            token: nil,
            query: [],
            jsonBody: ["mobile": mobile, "captcha": captcha]
        )
        if let json = result.jsonObject,
           let dataObj = json["data"] as? [String: Any],
           let token = dataObj["token"] as? String,
           !token.isEmpty {
            return token
        }
        throw NSError(domain: "UjingClient", code: result.businessCode ?? -1, userInfo: [
            NSLocalizedDescriptionKey: result.businessMessage ?? "未从响应中获取到 JWT Token"
        ])
    }

    // MARK: - Probing

    /// Calls `devices/scanWasherCode` with the FULL raw QR text, then chains `app/washer/devices/program/info` if `deviceId` is returned.
    func probeQRCode(rawQRCode: String, token: String) async -> [ProbeEntry] {
        guard !token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return [
                ProbeEntry(
                    probeType: "ujing_scan",
                    title: "U净扫码探测（需登录）",
                    method: "POST",
                    endpoint: "\(baseURL)/devices/scanWasherCode",
                    success: false,
                    durationMs: 0,
                    summary: "未配置 U净 JWT，前往「账号」页登录后可自动查设备与档位"
                )
            ]
        }

        var entries: [ProbeEntry] = []
        let scanResult = await performRequest(
            probeType: "ujing_scan",
            title: "U净扫码识别 (scanWasherCode)",
            method: "POST",
            path: "devices/scanWasherCode",
            identity: .business,
            token: token,
            query: [],
            jsonBody: ["qrCode": rawQRCode]
        )
        entries.append(scanResult.entry)

        if let deviceId = extractDeviceId(from: scanResult.jsonObject) {
            let programResult = await performRequest(
                probeType: "ujing_program",
                title: "U净设备套餐与档位 (program/info)",
                method: "GET",
                path: "app/washer/devices/program/info",
                identity: .business,
                token: token,
                query: [("deviceId", deviceId)],
                jsonBody: nil
            )
            entries.append(programResult.entry)
        }

        return entries
    }

    func probeStoresNear(keyword: String, lat: Double, lng: Double, token: String) async -> ProbeEntry {
        var query: [(String, String)] = [
            ("lat", String(lat)),
            ("lont", String(lng)), // Platform spelling is intentionally `lont`
            ("scope", "5000"),
            ("page", "1"),
            ("size", "50"),
            ("mode", "BA")
        ]
        let trimmed = keyword.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            query.append(("keyword", trimmed))
        }
        let result = await performRequest(
            probeType: "ujing_stores",
            title: "U净洗衣房门店看板 (stores/near)",
            method: "GET",
            path: "stores/near",
            identity: .query,
            token: token,
            query: query,
            jsonBody: nil
        )
        return result.entry
    }

    // MARK: - Internal

    private struct RequestOutcome {
        let entry: ProbeEntry
        let jsonObject: [String: Any]?
        let businessCode: Int?
        let businessMessage: String?
    }

    private func performRequest(
        probeType: String,
        title: String,
        method: String,
        path: String,
        identity: Identity,
        token: String?,
        query: [(String, String)],
        jsonBody: [String: Any]?
    ) async -> RequestOutcome {
        let started = Date()
        var components = URLComponents(string: "\(baseURL)/\(path)")
        if !query.isEmpty {
            components?.queryItems = query.map { URLQueryItem(name: $0.0, value: $0.1) }
        }
        guard let url = components?.url else {
            return RequestOutcome(
                entry: ProbeEntry(
                    probeType: probeType,
                    title: title,
                    method: method,
                    endpoint: "\(baseURL)/\(path)",
                    success: false,
                    durationMs: 0,
                    summary: "URL 构造失败"
                ),
                jsonObject: nil,
                businessCode: nil,
                businessMessage: nil
            )
        }

        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("*/*", forHTTPHeaderField: "Accept")
        request.setValue("zh-Hans-CN;q=1", forHTTPHeaderField: "Accept-Language")
        request.setValue("-180.000000,-180.000000", forHTTPHeaderField: "x-user-geo")
        request.setValue("apple", forHTTPHeaderField: "x-mobile-brand")
        request.setValue("iPhone14,5", forHTTPHeaderField: "x-mobile-model")

        switch identity {
        case .account:
            request.setValue("ZI", forHTTPHeaderField: "x-app-code")
            request.setValue("2.4.3", forHTTPHeaderField: "x-app-version")
            request.setValue("U jing/2.4.3 (iPhone; iOS 17.3; Scale/3.00)", forHTTPHeaderField: "User-Agent")
        case .query:
            request.setValue("ZA", forHTTPHeaderField: "x-app-code")
            request.setValue("2.4.18", forHTTPHeaderField: "x-app-version")
        case .business:
            request.setValue("BI", forHTTPHeaderField: "x-app-code")
            request.setValue("2.4.2", forHTTPHeaderField: "x-app-version")
            request.setValue("1.1.30", forHTTPHeaderField: "weex-version")
            request.setValue("U jing/2.4.2 (iPhone; iOS 17.0.1; Scale/3.00)", forHTTPHeaderField: "User-Agent")
        }

        if let token, !token.isEmpty {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }

        if method == "POST" {
            request.setValue("application/json; charset=utf-8", forHTTPHeaderField: "Content-Type")
            let bodyObj = jsonBody ?? [:]
            request.httpBody = try? JSONSerialization.data(withJSONObject: bodyObj, options: [])
        }

        do {
            let (data, response) = try await session.data(for: request)
            let elapsed = Int(Date().timeIntervalSince(started) * 1000)
            let statusCode = (response as? HTTPURLResponse)?.statusCode
            let pretty = Sanitizer.prettyJSONString(from: data, maxBytes: 24_576)

            let jsonObj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            let code = parseInt(jsonObj?["code"])
            let message = jsonObj?["message"] as? String ?? jsonObj?["msg"] as? String
            let isSuccess = (code == 0)

            var summary = "HTTP \(statusCode ?? 0)"
            if let code {
                summary += " · code=\(code)"
            }
            if let message, !message.isEmpty {
                summary += " · \(message)"
            }
            if isSuccess, let deviceId = extractDeviceId(from: jsonObj) {
                summary += " · deviceId=\(deviceId)"
            }

            return RequestOutcome(
                entry: ProbeEntry(
                    probeType: probeType,
                    title: title,
                    method: method,
                    endpoint: url.absoluteString,
                    statusCode: statusCode,
                    success: isSuccess,
                    durationMs: elapsed,
                    summary: summary,
                    rawBody: pretty,
                    errorMessage: isSuccess ? nil : message
                ),
                jsonObject: jsonObj,
                businessCode: code,
                businessMessage: message
            )
        } catch {
            let elapsed = Int(Date().timeIntervalSince(started) * 1000)
            return RequestOutcome(
                entry: ProbeEntry(
                    probeType: probeType,
                    title: title,
                    method: method,
                    endpoint: url.absoluteString,
                    success: false,
                    durationMs: elapsed,
                    summary: "网络错误：\(error.localizedDescription)",
                    errorMessage: error.localizedDescription
                ),
                jsonObject: nil,
                businessCode: nil,
                businessMessage: error.localizedDescription
            )
        }
    }

    private func extractDeviceId(from json: [String: Any]?) -> String? {
        guard let data = json?["data"] as? [String: Any] else { return nil }
        for key in ["deviceId", "id", "washerId"] {
            if let str = data[key] as? String, !str.isEmpty { return str }
            if let num = data[key] as? NSNumber { return num.stringValue }
        }
        return nil
    }

    private func parseInt(_ any: Any?) -> Int? {
        if let i = any as? Int { return i }
        if let n = any as? NSNumber { return n.intValue }
        if let s = any as? String { return Int(s) }
        return nil
    }
}
