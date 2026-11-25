import CryptoKit
import Foundation

struct QiekjClientError: LocalizedError {
    let code: Int
    let message: String
    var errorDescription: String? { message }
}

actor QiekjClient {
    static let shared = QiekjClient()

    private let baseURL = "https://userapi.qiekj.com"
    private let apiVersion = "1.60.3"
    private let pointsVersion = "1.123.0"
    private let channel = "android_app"
    private let appSecret = "nFU9pbG8YQoAe1kFh+E7eyrdlSLglwEJeA0wwHB1j5o="

    private let promotionsWithPoints =
        #"[{"assetId":"0","oldPromotionId":"","orgId":"0","promotionId":"0","promotionType":"-6"},{"assetId":"0","oldPromotionId":"","orgId":"0","promotionId":"0","promotionType":"-7"},{"assetId":"0","oldPromotionId":"","orgId":"0","promotionId":"0","promotionType":"8"}]"#
    private let promotionsWithoutPoints =
        #"[{"assetId":"0","oldPromotionId":"","orgId":"0","promotionId":"0","promotionType":"-6"},{"assetId":"0","oldPromotionId":"","orgId":"0","promotionId":"0","promotionType":"-7"}]"#

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
        throw QiekjClientError(code: outcome.businessCode ?? -1, message: outcome.businessMessage ?? outcome.entry.summary)
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
        throw QiekjClientError(code: outcome.businessCode ?? -1, message: outcome.businessMessage ?? "未获取到胖乖 Token")
    }

    // MARK: - Production Shower & Account APIs

    func fetchBalance(token: String) async throws -> QiekjBalance {
        let outcome = await postForm(
            probeType: "qiekj_balance",
            title: "胖乖账户余额",
            path: "/user/balance",
            token: token,
            form: [("token", token)],
            isLoginAPI: false
        )
        try requireSuccess(outcome)
        let data = outcome.jsonObject?["data"] as? [String: Any] ?? [:]
        return QiekjBalance(
            balance: stringValue(data["balance"]) ?? "0.00",
            integral: intValue(data["integral"]) ?? 0,
            integralAmount: stringValue(data["integralAmount"]) ?? "0.00"
        )
    }

    func fetchLatestDevices(token: String, categoryCode: String = "08") async throws -> [QiekjDevice] {
        let outcome = await postForm(
            probeType: "qiekj_latest",
            title: "胖乖最近设备",
            path: "/goods/latestUsed",
            token: token,
            form: [("categoryCode", categoryCode), ("token", token)],
            isLoginAPI: false
        )
        try requireSuccess(outcome)
        let list = outcome.jsonObject?["data"] as? [[String: Any]] ?? []
        return list.compactMap(parseDeviceDict)
    }

    func fetchOrderHistory(token: String, page: Int = 1, pageSize: Int = 30) async throws -> [QiekjOrderSummary] {
        let outcome = await postForm(
            probeType: "qiekj_orders",
            title: "胖乖历史订单",
            path: "/order/list",
            token: token,
            form: [("page", String(page)), ("pageSize", String(pageSize)), ("token", token)],
            isLoginAPI: false
        )
        try requireSuccess(outcome)
        let data = outcome.jsonObject?["data"] as? [String: Any] ?? [:]
        let items = data["items"] as? [[String: Any]] ?? []
        return items.compactMap { item -> QiekjOrderSummary? in
            let tradeItems = item["tradeOrderItem"] as? [[String: Any]] ?? []
            let lineItems = item["lineItems"] as? [[String: Any]] ?? []
            let firstTrade = tradeItems.first ?? [:]
            let firstLine = lineItems.first ?? [:]

            let goodsId = stringValue(firstTrade["goodsId"]) ?? stringValue(firstLine["goodsId"]) ?? ""
            guard !goodsId.isEmpty else { return nil }
            let goodsName = stringValue(firstTrade["goodsName"]) ?? stringValue(item["machineName"]) ?? goodsId
            let skuId = stringValue(firstTrade["skuId"]) ?? stringValue(firstLine["skuId"]) ?? ""
            let categoryCode = stringValue(firstTrade["goodsCategory"]) ?? "08"
            let shopId = stringValue(item["shopId"]) ?? ""
            let orgId = stringValue(item["shopAutoId"]) ?? "0"
            let shopName = stringValue(item["shopName"]) ?? ""
            let payPrice = stringValue(item["payPrice"]) ?? stringValue(item["markPrice"]) ?? "0.00"
            let createTime = stringValue(item["createTime"]) ?? ""
            let orderNo = stringValue(item["orderNo"]) ?? stringValue(item["id"]) ?? ""
            let orderId = stringValue(item["id"]) ?? orderNo

            return QiekjOrderSummary(
                orderId: orderId,
                orderNo: orderNo,
                goodsId: goodsId,
                goodsName: goodsName,
                skuId: skuId,
                categoryCode: categoryCode,
                shopId: shopId,
                orgId: orgId,
                shopName: shopName,
                payPrice: payPrice,
                createTime: createTime
            )
        }
    }

    func fetchNearMachines(
        token: String,
        shopId: String,
        machineTypeId: String = "08",
        orgId: String = "0"
    ) async throws -> [QiekjDevice] {
        guard !shopId.isEmpty else { return [] }
        let outcome = await postForm(
            probeType: "qiekj_near_machines",
            title: "胖乖附近设备列表",
            path: "/appointNew/near/newMachines",
            token: token,
            form: [
                ("goodsPage", "1"),
                ("pageSize", "100"),
                ("shopId", shopId),
                ("machineTypeId", machineTypeId),
                ("orgId", orgId),
                ("token", token)
            ],
            isLoginAPI: false
        )
        try requireSuccess(outcome)
        guard let root = outcome.jsonObject?["data"] else { return [] }
        var collected: [QiekjDevice] = []
        collectMachines(from: root, fallbackShopId: shopId, fallbackOrgId: orgId, fallbackCategory: machineTypeId, into: &collected)
        return collected
    }

    func fetchSkuId(token: String, goodsId: String) async throws -> String {
        let outcome = await postForm(
            probeType: "qiekj_skus",
            title: "获取设备 SKU",
            path: "/goods/normal/skus",
            token: token,
            form: [("goodsId", goodsId), ("token", token)],
            isLoginAPI: false
        )
        try requireSuccess(outcome)
        let list = outcome.jsonObject?["data"] as? [[String: Any]] ?? []
        if let first = list.first, let skuId = stringValue(first["skuId"]), !skuId.isEmpty {
            return skuId
        }
        throw QiekjClientError(code: -1, message: "未获取到设备 skuId")
    }

    func fetchDeviceDetails(token: String, goodsId: String) async throws -> QiekjDeviceDetails {
        let outcome = await postForm(
            probeType: "qiekj_details",
            title: "获取设备详情",
            path: "/goods/normal/details",
            token: token,
            form: [("goodsId", goodsId), ("token", token)],
            isLoginAPI: false
        )
        try requireSuccess(outcome)
        let data = outcome.jsonObject?["data"] as? [String: Any] ?? [:]
        guard let imei = stringValue(data["imei"]), !imei.isEmpty else {
            throw QiekjClientError(code: -1, message: "设备详情缺少 IMEI")
        }
        return QiekjDeviceDetails(
            goodsId: stringValue(data["goodsId"]) ?? goodsId,
            name: stringValue(data["name"]) ?? goodsId,
            imei: imei,
            categoryCode: stringValue(data["categoryCode"]) ?? "08",
            supportAppUserFinish: boolValue(data["supportAppUserFinish"]),
            payment: stringValue(data["payment"]) ?? "after"
        )
    }

    /// Resolves a scanned `SN` / QR URL via `/goods/scan/v2` to obtain `goodsId`.
    func scanBySN(token: String, sn: String, rawQRCode: String) async -> String? {
        let attempts: [[(String, String)]] = [
            [("SN", sn), ("token", token)],
            [("sn", sn), ("token", token)],
            [("NQT", rawQRCode), ("token", token)],
            [("imei", sn), ("token", token)]
        ]
        for form in attempts {
            let outcome = await postForm(
                probeType: "qiekj_scan_v2",
                title: "胖乖扫码反查 (goods/scan/v2)",
                path: "/goods/scan/v2",
                token: token,
                form: form,
                isLoginAPI: false
            )
            if outcome.entry.success, let data = outcome.jsonObject?["data"] as? [String: Any] {
                if let gid = stringValue(data["goodsId"]) ?? stringValue(data["id"]), !gid.isEmpty {
                    AppLog.log(.info, module: .shower, "goods/scan/v2 成功命中 goodsId=\(gid)", detail: outcome.entry.rawBody)
                    return gid
                }
            }
        }
        return nil
    }

    func syncWater(token: String, skuId: String) async throws -> QiekjSyncStatus? {
        let outcome = await postForm(
            probeType: "qiekj_sync",
            title: "同步用水状态",
            path: "/goods/water/sync",
            token: token,
            form: [("skuId", skuId), ("token", token)],
            isLoginAPI: false
        )
        try requireSuccess(outcome)
        guard let data = outcome.jsonObject?["data"] as? [String: Any] else {
            return nil
        }
        return QiekjSyncStatus(
            workStatus: intValue(data["workStatus"]),
            status: intValue(data["status"]),
            identify: stringValue(data["identify"])
        )
    }

    func checkUserIsRisk(token: String) async throws {
        let outcome = await postForm(
            probeType: "qiekj_risk",
            title: "检查积分风控",
            path: "/userIntegral/checkUserIsRisk",
            token: token,
            form: [("token", token)],
            isLoginAPI: false
        )
        try requireSuccess(outcome)
    }

    func addUserAfterPayChannel(token: String, method: String = "15") async throws {
        let outcome = await postForm(
            probeType: "qiekj_afterpay_channel",
            title: "确认后付通道",
            path: "/payChannelRoute/addUserAfterPayChannel",
            token: token,
            form: [("method", method), ("token", token)],
            isLoginAPI: false
        )
        try requireSuccess(outcome)
    }

    func isCheckLocation(token: String, categoryCode: String, imei: String) async throws {
        let outcome = await postForm(
            probeType: "qiekj_location_risk",
            title: "位置风控预检",
            path: "/orderRisk/isCheckLocation",
            token: token,
            form: [("categoryCode", categoryCode), ("imei", imei), ("token", token)],
            isLoginAPI: false
        )
        try requireSuccess(outcome)
    }

    func unlockWater(token: String, skuId: String, usePoints: Bool) async throws -> String {
        let promo = usePoints ? promotionsWithPoints : promotionsWithoutPoints
        let outcome = await postForm(
            probeType: "qiekj_unlock",
            title: "云端开阀出水",
            path: "/goods/water/unlock",
            token: token,
            form: [("skuId", skuId), ("promotions", promo), ("token", token)],
            isLoginAPI: false
        )
        try requireSuccess(outcome)
        let data = outcome.jsonObject?["data"] as? [String: Any] ?? [:]
        guard let orderNo = stringValue(data["orderNo"]), !orderNo.isEmpty else {
            throw QiekjClientError(code: -1, message: "开阀成功但未返回订单号")
        }
        return orderNo
    }

    func endWater(token: String, goodsId: String) async throws {
        let outcome = await postForm(
            probeType: "qiekj_end_water",
            title: "远程结束用水",
            path: "/goods/endWater",
            token: token,
            form: [("goodsId", goodsId), ("token", token)],
            isLoginAPI: false
        )
        try requireSuccess(outcome)
    }

    func createAfterPay(token: String, orderNo: String) async throws -> String {
        let outcome = await postForm(
            probeType: "qiekj_create_afterpay",
            title: "创建后付结算单",
            path: "/order/afterPay/creating",
            token: token,
            form: [("orderNo", orderNo), ("token", token)],
            isLoginAPI: false
        )
        try requireSuccess(outcome)
        let data = outcome.jsonObject?["data"] as? [String: Any] ?? [:]
        guard let orderId = stringValue(data["orderId"]), !orderId.isEmpty else {
            throw QiekjClientError(code: -1, message: "未返回结算 orderId")
        }
        return orderId
    }

    func fetchOrderDetail(token: String, orderId: String) async throws -> (realPrice: String, originPrice: String, payTypeName: String) {
        let outcome = await postForm(
            probeType: "qiekj_order_detail",
            title: "查询账单明细",
            path: "/order/detail",
            token: token,
            form: [("orderId", orderId), ("token", token)],
            isLoginAPI: false
        )
        try requireSuccess(outcome)
        let data = outcome.jsonObject?["data"] as? [String: Any] ?? [:]
        let items = data["tradeOrderItem"] as? [[String: Any]] ?? []
        let first = items.first ?? [:]
        let real = stringValue(first["realPrice"]) ?? stringValue(data["payPrice"]) ?? "-"
        let origin = stringValue(first["originPrice"]) ?? real
        let payType = stringValue(data["payTypeName"]) ?? "后付结算"
        return (real, origin, payType)
    }

    func runDailySignIn(token: String) async throws -> String {
        let today = await postForm(
            probeType: "qiekj_signin_check",
            title: "查询今日签到",
            path: "/signin/todaySignIn",
            token: token,
            form: [("token", token)],
            isLoginAPI: false,
            versionOverride: pointsVersion,
            signPathSeparator: "&"
        )
        try requireSuccess(today)
        if let d = today.jsonObject?["data"] as? [String: Any], boolValue(d["isSignIn"]) == true {
            return "今天已经签过到啦"
        }

        let acList = await postForm(
            probeType: "qiekj_signin_ac",
            title: "查询签到活动",
            path: "/signin/signInAcList",
            token: token,
            form: [("token", token)],
            isLoginAPI: false,
            versionOverride: pointsVersion,
            signPathSeparator: "&"
        )
        let acId = ((acList.jsonObject?["data"] as? [String: Any]).flatMap { stringValue($0["id"]) }) ?? "600001"

        let signRes = await postForm(
            probeType: "qiekj_signin_do",
            title: "执行每日签到",
            path: "/signin/doUserSignIn",
            token: token,
            form: [("token", token), ("activityId", acId)],
            isLoginAPI: false,
            versionOverride: pointsVersion,
            signPathSeparator: "&"
        )
        if signRes.businessCode == 33001 {
            return "服务端确认今日已签到"
        }
        try requireSuccess(signRes)
        if let d = signRes.jsonObject?["data"] as? [String: Any],
           let total = stringValue(d["totalIntegral"]) {
            return "签到成功！当前累计积分 \(total)"
        }
        return "胖乖每日签到成功"
    }

    // MARK: - Debug Probe Helpers (for GlassScan export)

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
                    summary: "未配置胖乖 Token，前往「我的」页登录后可查设备与历史订单"
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

        let latest = await postForm(
            probeType: "qiekj_latest_08",
            title: "胖乖最近淋浴设备 (categoryCode=08)",
            path: "/goods/latestUsed",
            token: token,
            form: [("categoryCode", "08"), ("token", token)],
            isLoginAPI: false
        )
        entries.append(latest.entry)

        return entries
    }

    // MARK: - Internal Transport & Parsing

    private struct RequestOutcome {
        let entry: ProbeEntry
        let jsonObject: [String: Any]?
        let businessCode: Int?
        let businessMessage: String?
    }

    private func requireSuccess(_ outcome: RequestOutcome) throws {
        if outcome.entry.success { return }
        throw QiekjClientError(
            code: outcome.businessCode ?? -1,
            message: outcome.businessMessage ?? outcome.entry.summary
        )
    }

    private func postForm(
        probeType: String,
        title: String,
        path: String,
        token: String?,
        form: [(String, String)],
        isLoginAPI: Bool,
        versionOverride: String? = nil,
        signPathSeparator: String = ""
    ) async -> RequestOutcome {
        let started = Date()
        let fullURLString = "\(baseURL)\(path)"
        let version = versionOverride ?? apiVersion

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
                businessMessage: "无效 URL"
            )
        }

        let timestamp = String(Int64(Date().timeIntervalSince1970 * 1000))
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue(version, forHTTPHeaderField: "Version")
        request.setValue(channel, forHTTPHeaderField: "channel")
        request.setValue("Redmi", forHTTPHeaderField: "phoneBrand")
        request.setValue("okhttp/3.14.9", forHTTPHeaderField: "User-Agent")
        request.setValue("application/x-www-form-urlencoded;charset=UTF-8", forHTTPHeaderField: "Content-Type")
        request.setValue(timestamp, forHTTPHeaderField: "timestamp")

        if let token, !token.isEmpty {
            request.setValue(token, forHTTPHeaderField: "token")
            request.setValue(token, forHTTPHeaderField: "Authorization")
            if !isLoginAPI {
                let signInput = "appSecret=\(appSecret)&channel=\(channel)&timestamp=\(timestamp)&token=\(token)&version=\(version)\(signPathSeparator)\(path)"
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
            let code = intValue(jsonObj?["code"])
            let msg = jsonObj?["msg"] as? String ?? jsonObj?["message"] as? String
            let isSuccess = (code == 0 || code == 200)

            var summary = "HTTP \(statusCode ?? 0)"
            if let code { summary += " · code=\(code)" }
            if let msg, !msg.isEmpty { summary += " · \(msg)" }

            if probeType != "qiekj_sync" || !isSuccess {
                AppLog.log(
                    isSuccess ? .net : .warn,
                    module: .shower,
                    "POST \(path) → \(summary) (\(elapsed)ms)",
                    detail: pretty
                )
            }

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
                businessMessage: msg
            )
        } catch {
            let elapsed = Int(Date().timeIntervalSince(started) * 1000)
            AppLog.log(.error, module: .shower, "POST \(path) 网络错误 (\(elapsed)ms)：\(error.localizedDescription)")
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
                businessMessage: error.localizedDescription
            )
        }
    }

    private func parseDeviceDict(_ dict: [String: Any]) -> QiekjDevice? {
        guard let goodsId = stringValue(dict["goodsId"]) ?? stringValue(dict["id"]), !goodsId.isEmpty else {
            return nil
        }
        let goodsName = stringValue(dict["goodsName"]) ?? stringValue(dict["name"]) ?? goodsId
        return QiekjDevice(
            goodsId: goodsId,
            goodsName: goodsName,
            categoryCode: stringValue(dict["categoryCode"]) ?? stringValue(dict["goodsCategory"]) ?? "08",
            shopId: stringValue(dict["shopId"]) ?? "",
            orgId: stringValue(dict["orgId"]) ?? "0",
            orgName: stringValue(dict["orgName"]) ?? "",
            parentPointName: stringValue(dict["parentPointName"]) ?? "",
            workStatus: intValue(dict["workStatus"]) ?? intValue(dict["status"]),
            skuId: stringValue(dict["skuId"]),
            imei: stringValue(dict["imei"])
        )
    }

    private func collectMachines(
        from any: Any,
        fallbackShopId: String,
        fallbackOrgId: String,
        fallbackCategory: String,
        into result: inout [QiekjDevice]
    ) {
        if let arr = any as? [Any] {
            for item in arr {
                collectMachines(from: item, fallbackShopId: fallbackShopId, fallbackOrgId: fallbackOrgId, fallbackCategory: fallbackCategory, into: &result)
            }
        } else if let dict = any as? [String: Any] {
            if let goodsId = stringValue(dict["goodsId"]), !goodsId.isEmpty {
                let device = QiekjDevice(
                    goodsId: goodsId,
                    goodsName: stringValue(dict["goodsName"]) ?? stringValue(dict["name"]) ?? goodsId,
                    categoryCode: stringValue(dict["categoryCode"]) ?? fallbackCategory,
                    shopId: stringValue(dict["shopId"]) ?? fallbackShopId,
                    orgId: stringValue(dict["orgId"]) ?? fallbackOrgId,
                    orgName: stringValue(dict["orgName"]) ?? "",
                    parentPointName: stringValue(dict["parentPointName"]) ?? stringValue(dict["pointName"]) ?? "",
                    workStatus: intValue(dict["workStatus"]) ?? intValue(dict["status"]),
                    skuId: stringValue(dict["skuId"]),
                    imei: stringValue(dict["imei"])
                )
                result.append(device)
            } else {
                for (_, value) in dict {
                    if value is [Any] || value is [String: Any] {
                        collectMachines(from: value, fallbackShopId: fallbackShopId, fallbackOrgId: fallbackOrgId, fallbackCategory: fallbackCategory, into: &result)
                    }
                }
            }
        }
    }

    private func formEncode(_ string: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return string.addingPercentEncoding(withAllowedCharacters: allowed) ?? string
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
