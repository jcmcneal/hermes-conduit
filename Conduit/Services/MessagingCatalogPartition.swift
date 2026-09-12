import CryptoKit
import Foundation

/// A display-cache key, never authentication evidence. Cookie values are only
/// inputs to the digest and are never returned or stored with catalog metadata.
enum MessagingCatalogPartition {
    static func make(baseURL: String, cookies: [HTTPCookie], now: Date = Date()) -> String? {
        guard let normalized = try? ConnectionURLPolicy.normalizedBaseURL(baseURL),
              var origin = URLComponents(string: normalized),
              let scheme = origin.scheme?.lowercased(),
              let host = origin.host?.lowercased() else { return nil }
        origin.scheme = scheme
        origin.host = host
        if (scheme == "https" && origin.port == 443) || (scheme == "http" && origin.port == 80) {
            origin.port = nil
        }
        guard let server = origin.string else { return nil }
        let basePath = origin.percentEncodedPath
        let requestPaths = [basePath + "/api/auth/me", basePath + "/api/plugins/bot-coms-messaging/v1/capabilities"]
        var hasToken = false
        let identities: [[String]] = cookies.compactMap { cookie in
            let name = unprefixed(cookie.name)
            guard ["hermes_session_at", "hermes_session_rt", "hermes_session_provider"].contains(name),
                  !cookie.value.isEmpty,
                  cookie.expiresDate.map({ $0 > now }) ?? true,
                  !cookie.isSecure || scheme == "https" else { return nil }
            let domain = cookie.domain.lowercased()
            let bareDomain = domain.hasPrefix(".") ? String(domain.dropFirst()) : domain
            guard host == bareDomain || (domain.hasPrefix(".") && host.hasSuffix("." + bareDomain)),
                  requestPaths.contains(where: { pathMatches(cookie.path, requestPath: $0) }) else { return nil }
            if name == "hermes_session_at" || name == "hermes_session_rt" { hasToken = true }
            return [cookie.name, domain, cookie.path, cookie.isSecure ? "secure" : "plain", cookie.value]
        }
        guard hasToken,
              let data = try? JSONEncoder().encode([["messaging-catalog-v1", server]] + identities.sorted(by: { $0.lexicographicallyPrecedes($1) })) else { return nil }
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static func unprefixed(_ name: String) -> String {
        for prefix in ["__Host-", "__Secure-"] where name.hasPrefix(prefix) {
            return String(name.dropFirst(prefix.count))
        }
        return name
    }

    private static func pathMatches(_ cookiePath: String, requestPath: String) -> Bool {
        requestPath == cookiePath || (requestPath.hasPrefix(cookiePath)
            && (cookiePath.hasSuffix("/") || requestPath.dropFirst(cookiePath.count).hasPrefix("/")))
    }
}
