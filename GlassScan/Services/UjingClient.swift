import Foundation

struct UjingClientError: LocalizedError {
    let code: Int
    let message: String
    var errorDescription: String? { message }
}

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
        throw UjingClientError(code: result.businessCode ?? -1, message: result.businessMessage ?? result.entry.summary)
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
        throw UjingClientError(code: result.businessCode ?? -1, message: result.businessMessage ?? "未从响应中获取到 JWT Token")
    }

    // MARK: - Production Laundry & Payment APIs

    func scanWasher(token: String, qrCode: String) async throws -> UjingScanInfo {
        let result = await performRequest(
            probeType: "ujing_scan",
            title: "U净扫码识别",
            method: "POST",
            path: "devices/scanWasherCode",
            identity: .business,
            token: token,
            query: [],
            jsonBody: ["qrCode": qrCode]
        )
        try requireSuccess(result)

        let data = result.jsonObject?["data"] as? [String: Any] ?? [:]
        let inner = (data["result"] as? [String: Any]) ?? data
        return UjingScanInfo(
            rawQRCode: qrCode,
            deviceId: stringValue(inner["deviceId"]) ?? "",
            deviceTypeId: intValue(inner["deviceTypeId"]) ?? 0,
            moduleType: intValue(inner["moduleType"]) ?? -1,
            createOrderEnabled: boolValue(inner["createOrderEnabled"]) ?? false,
            status: stringValue(inner["status"]) ?? "",
            reason: stringValue(inner["reason"]) ?? ""
        )
    }

    func fetchProgramInfo(token: String, deviceId: String) async throws -> UjingProgramInfo {
        let result = await performRequest(
            probeType: "ujing_program",
            title: "U净设备套餐",
            method: "GET",
            path: "app/washer/devices/program/info",
            identity: .business,
            token: token,
            query: [("deviceId", deviceId)],
            jsonBody: nil
        )
        try requireSuccess(result)

        let data = result.jsonObject?["data"] as? [String: Any] ?? [:]
        let rawModels = data["deviceWashModel"] as? [[String: Any]] ?? []
        let models: [UjingWashModel] = rawModels.map { m in
            let dryDict = m["additionDryTime"] as? [String: Any]
            let rawOpts = dryDict?["options"] as? [Any] ?? []
            let opts = rawOpts.compactMap { intValue($0) }.filter { $0 > 0 && $0 % 10 == 0 }
            return UjingWashModel(
                workModelId: intValue(m["workModelId"]) ?? 0,
                workModelName: stringValue(m["workModelName"]) ?? "",
                basePriceFen: intValue(m["basePrice"]) ?? 0,
                timeMinutes: intValue(m["time"]) ?? 0,
                hide: boolValue(m["hide"]) ?? false,
                isDefault: boolValue(m["isDefault"]) ?? false,
                additionDryTimeTitle: stringValue(dryDict?["title"]) ?? "烘干时长",
                additionDryTimeOptions: opts
            )
        }

        return UjingProgramInfo(
            deviceId: stringValue(data["deviceId"]) ?? deviceId,
            deviceNo: stringValue(data["deviceNo"]) ?? "",
            deviceTypeId: intValue(data["deviceTypeId"]) ?? 0,
            deviceTypeName: stringValue(data["deviceTypeName"]) ?? "洗衣机",
            storeId: stringValue(data["storeId"]) ?? "",
            storeName: stringValue(data["storeName"]) ?? "",
            moduleType: intValue(data["moduleType"]) ?? -1,
            type: intValue(data["type"]) ?? 1,
            isWashTemperatureEnable: boolValue(data["isWashTemperatureEnable"]) ?? false,
            isForceDetergent: boolValue(data["isForceDetergent"]) ?? false,
            isForceDisinfectant: boolValue(data["isForceDisinfectant"]) ?? false,
            models: models
        )
    }

    func fetchStoresNear(token: String, lat: Double, lng: Double, keyword: String?) async throws -> [UjingStoreBoardItem] {
        var query: [(String, String)] = [
            ("lat", String(lat)),
            ("lont", String(lng)),
            ("scope", "5000"),
            ("page", "1"),
            ("size", "60"),
            ("mode", "BA")
        ]
        if let keyword, !keyword.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            query.append(("keyword", keyword.trimmingCharacters(in: .whitespacesAndNewlines)))
        }
        let result = await performRequest(
            probeType: "ujing_stores",
            title: "U净附近门店",
            method: "GET",
            path: "stores/near",
            identity: .query,
            token: token,
            query: query,
            jsonBody: nil
        )
        try requireSuccess(result)

        let data = result.jsonObject?["data"] as? [String: Any] ?? [:]
        let storeList = data["storeList"] as? [[String: Any]] ?? []
        return storeList.compactMap { s in
            guard let id = stringValue(s["id"]), !id.isEmpty,
                  let name = stringValue(s["name"]), !name.isEmpty else {
                return nil
            }
            let subject = s["serviceSubject"] as? [String: Any]
            let subjectName = stringValue(subject?["name"]) ?? ""
            let infoList = s["storeInfo"] as? [[String: Any]] ?? []

            var washerFree = 0, washerTotal = 0
            var dryerFree = 0, dryerTotal = 0
            var shoeFree = 0, shoeTotal = 0

            for info in infoList {
                let cat = intValue(info["category"]) ?? 0
                let access = intValue(info["access"]) ?? 0
                let num = intValue(info["num"]) ?? 0
                switch cat {
                case 1:
                    washerFree += access
                    washerTotal += num
                case 2:
                    dryerFree += access
                    dryerTotal += num
                case 3:
                    shoeFree += access
                    shoeTotal += num
                default:
                    break
                }
            }

            return UjingStoreBoardItem(
                id: id,
                name: name,
                subjectName: subjectName,
                washerFree: washerFree,
                washerTotal: washerTotal,
                dryerFree: dryerFree,
                dryerTotal: dryerTotal,
                shoeFree: shoeFree,
                shoeTotal: shoeTotal
            )
        }
    }

    func createOrder(
        token: String,
        deviceId: String,
        deviceTypeId: Int,
        storeId: String,
        washModelId: Int,
        type: Int,
        washTemperatureId: Int?,
        detergentGearId: Int?,
        disinfectantGearId: Int?,
        dryTime: Int?
    ) async throws -> (orderId: String, orderNo: String) {
        var body: [String: Any] = [
            "type": type,
            "deviceTypeId": deviceTypeId,
            "deviceId": deviceId,
            "deviceWashModelId": washModelId,
            "storeId": storeId
        ]
        if type != 2, let washTemperatureId {
            body["washTemperatureId"] = washTemperatureId
        }
        if type != 2, let detergentGearId {
            body["wp_detergentGearId"] = detergentGearId
        }
        if type != 2, let disinfectantGearId {
            body["wp_disinfectantGearId"] = disinfectantGearId
        }
        if let dryTime {
            body["dryTime"] = dryTime
        }

        let result = await performRequest(
            probeType: "ujing_create_order",
            title: "U净创建订单",
            method: "POST",
            path: "orders/create",
            identity: .business,
            token: token,
            query: [],
            jsonBody: body
        )
        try requireSuccess(result)

        let data = result.jsonObject?["data"] as? [String: Any] ?? [:]
        guard let orderId = stringValue(data["orderId"]), !orderId.isEmpty else {
            throw UjingClientError(code: -1, message: "下单成功但未返回 orderId")
        }
        let orderNo = stringValue(data["orderNo"]) ?? orderId
        return (orderId, orderNo)
    }

    func fetchAlipayOrderInfo(token: String, orderId: String) async throws -> String {
        let result = await performRequest(
            probeType: "ujing_pay_args",
            title: "U净获取支付宝参数",
            method: "GET",
            path: "payment/arguments",
            identity: .business,
            token: token,
            query: [
                ("channel", "alipay"),
                ("orderId", orderId),
                ("couponId", ""),
                ("isUseRedPacket", "false"),
                ("redPacketId", "0"),
                ("alipayF2FNoAds", "false"),
                ("branchType", "0"),
                ("jumpToAliMini", "false"),
                ("payVersion", "1")
            ],
            jsonBody: nil
        )
        try requireSuccess(result)

        let data = result.jsonObject?["data"] as? [String: Any] ?? [:]
        let payInfo = data["payInfo"] as? [String: Any] ?? [:]
        if let orderInfo = stringValue(payInfo["orderInfo"]), !orderInfo.isEmpty {
            return orderInfo
        }
        if let directOrderInfo = stringValue(data["orderInfo"]), !directOrderInfo.isEmpty {
            return directOrderInfo
        }
        throw UjingClientError(code: -1, message: "未返回支付宝签名参数 orderInfo")
    }

    func fetchOrderDetail(token: String, orderId: String, existing: UjingActiveOrder?) async throws -> UjingActiveOrder {
        let result = await performRequest(
            probeType: "ujing_order_detail",
            title: "U净查询订单详情",
            method: "GET",
            path: "orders/\(orderId)/detail",
            identity: .business,
            token: token,
            query: [("additional", "price")],
            jsonBody: nil
        )
        try requireSuccess(result)

        let data = result.jsonObject?["data"] as? [String: Any] ?? [:]
        let devType = stringValue(data["deviceTypeName"]) ?? ""
        let devNo = stringValue(data["deviceNo"]) ?? ""
        let composedName = [devType, devNo].filter { !$0.isEmpty }.joined(separator: " ")

        return UjingActiveOrder(
            orderId: stringValue(data["orderId"]) ?? orderId,
            orderNo: stringValue(data["orderNo"]) ?? existing?.orderNo ?? orderId,
            deviceId: stringValue(data["deviceId"]) ?? existing?.deviceId ?? "",
            deviceName: composedName.isEmpty ? (existing?.deviceName ?? "U净设备") : composedName,
            storeName: stringValue(data["storeName"]) ?? existing?.storeName ?? "",
            modelName: stringValue(data["cycle"]) ?? existing?.modelName ?? "",
            isDryer: existing?.isDryer ?? (devType.contains("烘干") || devType.contains("干衣")),
            estimatedPriceText: existing?.estimatedPriceText ?? "",
            payPriceText: stringValue(data["payPrice"]) ?? existing?.payPriceText ?? "",
            status: stringValue(data["status"]) ?? existing?.status ?? "0",
            statusRemark: stringValue(data["statusRemark"]) ?? "",
            payFlag: intValue(data["payFlag"]) ?? existing?.payFlag ?? 0,
            remainSeconds: intValue(data["remainTime"]) ?? 0,
            durationSeconds: existing?.durationSeconds ?? 0,
            createdAt: existing?.createdAt ?? Date(),
            lastSyncedAt: Date()
        )
    }

    func fetchLastPayStatus(token: String, orderId: String) async throws -> (payFlag: Int, status: String) {
        let result = await performRequest(
            probeType: "ujing_last_pay",
            title: "U净查询支付状态",
            method: "GET",
            path: "app/payment/\(orderId)/lastPayStatus",
            identity: .business,
            token: token,
            query: [],
            jsonBody: nil
        )
        try requireSuccess(result)
        let data = result.jsonObject?["data"] as? [String: Any] ?? [:]
        return (intValue(data["payFlag"]) ?? 0, stringValue(data["status"]) ?? "")
    }

    func cancelOrder(token: String, orderId: String) async throws {
        let result = await performRequest(
            probeType: "ujing_cancel_order",
            title: "U净取消订单",
            method: "POST",
            path: "orders/\(orderId)/cancel",
            identity: .business,
            token: token,
            query: [],
            jsonBody: ["orderId": orderId]
        )
        try requireSuccess(result)
    }

    func controlOrder(token: String, orderId: String, action: String = "start") async throws {
        let result = await performRequest(
            probeType: "ujing_control",
            title: "U净云端控制 (\(action))",
            method: "GET",
            path: "orders/\(orderId)/control/\(action)",
            identity: .business,
            token: token,
            query: [],
            jsonBody: nil
        )
        let code = result.businessCode ?? -1
        let data = result.jsonObject?["data"] as? [String: Any]
        let innerErrorCode = intValue(data?["errorCode"])
        let accepted = (code == 0) || (code == 1703 && innerErrorCode == 0)
        if accepted { return }
        let innerMsg = stringValue(data?["errorMessage"])
        throw UjingClientError(code: code, message: innerMsg ?? result.businessMessage ?? "启动失败（code=\(code)）")
    }

    // MARK: - Debug Probe Helpers (for GlassScan export)

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
                    summary: "未配置 U净 JWT，前往「我的」页登录后可自动查设备与档位"
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
            ("lont", String(lng)),
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

    private func requireSuccess(_ outcome: RequestOutcome) throws {
        if outcome.entry.success { return }
        throw UjingClientError(
            code: outcome.businessCode ?? -1,
            message: outcome.businessMessage ?? outcome.entry.summary
        )
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
                businessMessage: "URL 构造失败"
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
            let code = intValue(jsonObj?["code"])
            let message = jsonObj?["message"] as? String ?? jsonObj?["msg"] as? String
            let isSuccess = (code == 0)

            var summary = "HTTP \(statusCode ?? 0)"
            if let code { summary += " · code=\(code)" }
            if let message, !message.isEmpty { summary += " · \(message)" }
            if isSuccess, let deviceId = extractDeviceId(from: jsonObj) {
                summary += " · deviceId=\(deviceId)"
            }

            AppLog.log(
                isSuccess ? .net : .warn,
                module: .laundry,
                "\(method) /\(path) → \(summary) (\(elapsed)ms)",
                detail: pretty
            )

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
            AppLog.log(.error, module: .laundry, "\(method) /\(path) 网络错误 (\(elapsed)ms)：\(error.localizedDescription)")
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
        if let inner = data["result"] as? [String: Any] {
            for key in ["deviceId", "id", "washerId"] {
                if let str = stringValue(inner[key]), !str.isEmpty { return str }
            }
        }
        for key in ["deviceId", "id", "washerId"] {
            if let str = stringValue(data[key]), !str.isEmpty { return str }
        }
        return nil
    }

    private func stringValue(_ any: Any?) -> String? {
        if let s = any as? String { return s }
        if let n = any as? NSNumber { return n.stringValue }
        return nil
    }

    private func intValue(_ any: Any?) -> Int? {
        if let i = any as? Int { return i }
        if let n = any as? NSNumber { return n.intValue }
        if let s = any as? String { return Int(s) ?? Double(s).map(Int.init) }
        return nil
    }

    private func boolValue(_ any: Any?) -> Bool? {
        if let b = any as? Bool { return b }
        if let n = any as? NSNumber { return n.intValue != 0 }
        if let s = any as? String {
            let l = s.lowercased()
            if l == "true" || l == "1" { return true }
            if l == "false" || l == "0" { return false }
        }
        return nil
    }
}
