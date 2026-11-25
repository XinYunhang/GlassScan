import Foundation
import UIKit

enum AlipayLaunchResult {
    case launched
    case alipayNotInstalled
    case encodingFailed
}

@MainActor
enum AlipayLauncher {
    static let callbackScheme = "glassscan"

    /// Launches the official Alipay iOS app with server-signed `orderInfo` via SafePay URL Scheme (zero third-party SDK).
    static func launch(orderInfo: String) async -> AlipayLaunchResult {
        let payload: [String: String] = [
            "fromAppUrlScheme": callbackScheme,
            "requestType": "SafePay",
            "dataString": orderInfo
        ]

        guard let jsonData = try? JSONSerialization.data(withJSONObject: payload, options: []),
              let jsonStr = String(data: jsonData, encoding: .utf8),
              let encoded = jsonStr.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
              let url = URL(string: "alipay://alipayclient/?\(encoded)") else {
            return .encodingFailed
        }

        guard let probeURL = URL(string: "alipay://"),
              UIApplication.shared.canOpenURL(probeURL) else {
            return .alipayNotInstalled
        }

        let opened = await UIApplication.shared.open(url)
        return opened ? .launched : .alipayNotInstalled
    }
}
