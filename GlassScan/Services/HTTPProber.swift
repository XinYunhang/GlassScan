import Foundation

private final class RedirectCaptureDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var hops: [String] = []
    private let maxHops = 6

    var redirectChain: [String] {
        lock.lock()
        defer { lock.unlock() }
        return hops
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        let nextURL = request.url?.absoluteString ?? ""
        lock.lock()
        let count = hops.count
        if !nextURL.isEmpty {
            hops.append("[\(response.statusCode)] \(nextURL)")
        }
        lock.unlock()

        if count < maxHops {
            completionHandler(request)
        } else {
            completionHandler(nil)
        }
    }
}

enum HTTPProber {
    private static let interestingHeaders: Set<String> = [
        "content-type", "location", "server", "cache-control",
        "x-powered-by", "x-request-id", "date"
    ]

    static func probe(urlString: String) async -> ProbeEntry {
        let started = Date()
        guard let url = URL(string: urlString),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https" else {
            return ProbeEntry(
                probeType: "http_get",
                title: "HTTP 只读探测",
                method: "GET",
                endpoint: urlString,
                success: false,
                durationMs: 0,
                summary: "非 HTTP(S) 链接，已跳过网页探测",
                errorMessage: "Unsupported URL scheme"
            )
        }

        let delegate = RedirectCaptureDelegate()
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 10
        config.timeoutIntervalForResource = 15
        config.httpShouldSetCookies = false
        let session = URLSession(configuration: config, delegate: delegate, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue(
            "Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Mobile/15E148",
            forHTTPHeaderField: "User-Agent"
        )
        request.setValue("text/html,application/json,*/*", forHTTPHeaderField: "Accept")

        do {
            let (data, response) = try await session.data(for: request)
            let elapsed = Int(Date().timeIntervalSince(started) * 1000)
            guard let http = response as? HTTPURLResponse else {
                return ProbeEntry(
                    probeType: "http_get",
                    title: "HTTP 只读探测",
                    method: "GET",
                    endpoint: urlString,
                    success: false,
                    durationMs: elapsed,
                    summary: "未收到有效 HTTP 响应"
                )
            }

            let headers: [KeyValueEntry] = http.allHeaderFields.compactMap { key, value in
                let k = String(describing: key)
                guard interestingHeaders.contains(k.lowercased()) else { return nil }
                return KeyValueEntry(key: k, value: String(describing: value))
            }.sorted { $0.key.lowercased() < $1.key.lowercased() }

            let contentType = http.value(forHTTPHeaderField: "Content-Type") ?? ""
            let formattedBody = Sanitizer.prettyJSONString(from: data, maxBytes: 8_192)
            let finalURL = http.url?.absoluteString ?? urlString

            var summaryParts: [String] = ["HTTP \(http.statusCode)"]
            if !contentType.isEmpty {
                summaryParts.append(contentType.components(separatedBy: ";").first ?? contentType)
            }
            if let htmlTitle = extractHTMLTitle(from: formattedBody) {
                summaryParts.append("标题：\(htmlTitle)")
            }
            if !delegate.redirectChain.isEmpty {
                summaryParts.append("跳转 \(delegate.redirectChain.count) 次")
            }

            return ProbeEntry(
                probeType: "http_get",
                title: "HTTP 只读探测",
                method: "GET",
                endpoint: finalURL,
                statusCode: http.statusCode,
                success: (200...399).contains(http.statusCode),
                durationMs: elapsed,
                redirectChain: delegate.redirectChain,
                headers: Sanitizer.sanitizeHeaders(headers),
                summary: summaryParts.joined(separator: " · "),
                rawBody: formattedBody
            )
        } catch {
            let elapsed = Int(Date().timeIntervalSince(started) * 1000)
            return ProbeEntry(
                probeType: "http_get",
                title: "HTTP 只读探测",
                method: "GET",
                endpoint: urlString,
                success: false,
                durationMs: elapsed,
                redirectChain: delegate.redirectChain,
                summary: "请求失败：\(error.localizedDescription)",
                errorMessage: error.localizedDescription
            )
        }
    }

    private static func extractHTMLTitle(from text: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: #"<title[^>]*>(.*?)</title>"#, options: [.caseInsensitive, .dotMatchesLineSeparators]) else {
            return nil
        }
        let range = NSRange(text.startIndex..., in: text)
        guard let match = regex.firstMatch(in: text, options: [], range: range),
              let titleRange = Range(match.range(at: 1), in: text) else {
            return nil
        }
        let title = text[titleRange].trimmingCharacters(in: .whitespacesAndNewlines)
        return title.isEmpty ? nil : String(title.prefix(60))
    }
}
