import Foundation

enum Sanitizer {
    private static let sensitiveKeyNames: Set<String> = [
        "token", "authorization", "jwt", "cookie", "set-cookie",
        "sign", "signature", "secret", "appsecret", "password",
        "phone", "mobile", "verify", "captcha", "openid", "unionid",
        "sessionid", "x-auth-token", "access_token", "refresh_token"
    ]

    static func maskPhone(_ phone: String) -> String {
        let digits = phone.filter(\.isNumber)
        guard digits.count >= 7 else { return phone.isEmpty ? "" : "***" }
        return "\(digits.prefix(3))****\(digits.suffix(4))"
    }

    static func maskTokenPreview(_ token: String) -> String {
        let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "未配置" }
        if trimmed.count <= 10 {
            return "已配置 (\(trimmed.count) 字符)"
        }
        return "\(trimmed.prefix(4))…\(trimmed.suffix(4)) (\(trimmed.count) 字符)"
    }

    static func sanitizeHeaders(_ headers: [KeyValueEntry]) -> [KeyValueEntry] {
        headers.map { entry in
            let lower = entry.key.lowercased()
            if sensitiveKeyNames.contains(lower) || lower.contains("token") || lower.contains("auth") || lower.contains("cookie") {
                return KeyValueEntry(key: entry.key, value: "***")
            }
            return KeyValueEntry(key: entry.key, value: sanitizeText(entry.value))
        }
    }

    static func sanitizeText(_ text: String, enabled: Bool = true) -> String {
        guard enabled, !text.isEmpty else { return text }
        var output = text

        // 1. Mask JWT strings (eyJxxx.eyJxxx.xxx)
        output = replaceRegex(
            in: output,
            pattern: #"eyJ[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{6,}"#,
            replacement: "***JWT***"
        )

        // 2. Mask Mainland China 11-digit phone numbers
        output = replaceRegex(
            in: output,
            pattern: #"(?<!\d)(1[3-9]\d)\d{4}(\d{4})(?!\d)"#,
            replacement: "$1****$2"
        )

        // 3. Mask sensitive JSON key values
        output = replaceRegex(
            in: output,
            pattern: #""(token|accessToken|refreshToken|authorization|jwt|mobile|phone|userPhone|realName|idCard|sign|alipayOrderStr|orderStr)"\s*:\s*"[^"]*""#,
            replacement: "\"$1\":\"***\"",
            caseInsensitive: true
        )

        // 4. Mask Bearer headers in text
        output = replaceRegex(
            in: output,
            pattern: #"Bearer\s+[A-Za-z0-9._-]{8,}"#,
            replacement: "Bearer ***",
            caseInsensitive: true
        )

        return output
    }

    static func prettyJSONString(from data: Data, maxBytes: Int = 16_384) -> String {
        let clipped = data.count > maxBytes ? data.prefix(maxBytes) : data
        if let object = try? JSONSerialization.jsonObject(with: clipped, options: []),
           let pretty = try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys]),
           let str = String(data: pretty, encoding: .utf8) {
            return data.count > maxBytes ? str + "\n/* ...已截断，原始长度 \(data.count) bytes */" : str
        }
        let raw = String(data: clipped, encoding: .utf8) ?? "<Binary \(data.count) bytes>"
        return data.count > maxBytes ? raw + "\n...（已截断，原始长度 \(data.count) bytes）" : raw
    }

    private static func replaceRegex(
        in input: String,
        pattern: String,
        replacement: String,
        caseInsensitive: Bool = false
    ) -> String {
        let options: NSRegularExpression.Options = caseInsensitive ? [.caseInsensitive] : []
        guard let regex = try? NSRegularExpression(pattern: pattern, options: options) else {
            return input
        }
        let range = NSRange(input.startIndex..., in: input)
        return regex.stringByReplacingMatches(in: input, options: [], range: range, withTemplate: replacement)
    }
}
