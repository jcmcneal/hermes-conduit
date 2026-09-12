import XCTest
import WebKit
@testable import Conduit

final class MessagingCatalogPartitionTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func cookie(_ name: String = "hermes_session_at", value: String = "private-token",
                        domain: String = "dashboard.example", path: String = "/",
                        secure: Bool = true, expires: Date? = nil) throws -> HTTPCookie {
        var properties: [HTTPCookiePropertyKey: Any] = [
            .name: name, .value: value, .domain: domain, .path: path
        ]
        if secure { properties[.secure] = "TRUE" }
        if let expires { properties[.expires] = expires }
        return try XCTUnwrap(HTTPCookie(properties: properties))
    }

    private func partition(_ cookies: [HTTPCookie], server: String = "https://dashboard.example") -> String? {
        MessagingCatalogPartition.make(baseURL: server, cookies: cookies, now: now)
    }

    func testRequiresKnownTokenAndNeverUsesProviderOnlyOrUnrelatedCookies() throws {
        XCTAssertNil(partition([]))
        XCTAssertNil(partition([try cookie("hermes_session_provider", value: "password")]))
        XCTAssertNil(partition([try cookie("analytics", value: "tracking"), try cookie("session")]))
    }

    func testDigestDoesNotContainSecretsAndRecognizesSecureCookieVariants() throws {
        for name in ["hermes_session_at", "hermes_session_rt", "__Host-hermes_session_at", "__Secure-hermes_session_rt"] {
            let key = try XCTUnwrap(partition([try cookie(name)]))
            XCTAssertEqual(key.count, 64)
            XCTAssertTrue(key.allSatisfy { "0123456789abcdef".contains($0) })
            XCTAssertFalse(key.contains("private-token"))
        }
    }

    func testChangingEitherAccessOrRefreshTokenChangesPartition() throws {
        let access = try cookie(value: "access-a")
        let refresh = try cookie("hermes_session_rt", value: "refresh-a")
        let original = try XCTUnwrap(partition([access, refresh]))
        XCTAssertNotEqual(original, partition([try cookie(value: "access-b"), refresh]))
        XCTAssertNotEqual(original, partition([access, try cookie("hermes_session_rt", value: "refresh-b")]))
    }

    func testOrderUnrelatedCookiesAndExpiryExtensionDoNotChangePartition() throws {
        let access = try cookie(expires: now.addingTimeInterval(60))
        let refresh = try cookie("hermes_session_rt", value: "refresh")
        let original = try XCTUnwrap(partition([access, refresh]))
        XCTAssertEqual(original, partition([refresh, access, try cookie("analytics")]))
        XCTAssertEqual(original, partition([try cookie(expires: now.addingTimeInterval(120)), refresh]))
    }

    func testExpiredAndEmptyTokensCannotRestoreCatalog() throws {
        XCTAssertNil(partition([try cookie(expires: now.addingTimeInterval(-1))]))
        XCTAssertNil(partition([try cookie(expires: now)]))
        XCTAssertNil(partition([try cookie(value: "")]))
    }

    func testDomainScopeRejectsForeignSiblingAndHostOnlySubdomainCookies() throws {
        XCTAssertNil(partition([try cookie(domain: "other.example")]))
        XCTAssertNil(partition([try cookie(domain: "evil-dashboard.example")]))
        XCTAssertNil(partition([try cookie(domain: "example")]))
        XCTAssertNotNil(partition([try cookie(domain: ".example")]))
    }

    func testCookiePathUsesDirectoryBoundaryAndDashboardBasePath() throws {
        XCTAssertNotNil(partition([try cookie(path: "/hermes")], server: "https://dashboard.example/hermes"))
        XCTAssertNil(partition([try cookie(path: "/hermes")], server: "https://dashboard.example/hermes-other"))
        XCTAssertNil(partition([try cookie(path: "/unrelated")]))
        XCTAssertNotNil(partition([try cookie(path: "/api/auth")]))
    }

    func testSecureCookiesCannotScopePlainHTTPConnection() throws {
        let secure = try cookie(domain: "localhost")
        XCTAssertNil(partition([secure], server: "http://localhost"))
        XCTAssertNotNil(partition([try cookie(domain: "localhost", secure: false)], server: "http://localhost"))
    }

    func testOriginNormalizationAndServerPathPartitioning() throws {
        let cookies = [try cookie()]
        let original = try XCTUnwrap(partition(cookies))
        XCTAssertEqual(original, partition(cookies, server: "HTTPS://DASHBOARD.EXAMPLE:443/"))
        XCTAssertNotEqual(original, partition(cookies, server: "https://dashboard.example:8443"))
        XCTAssertNotEqual(original, partition(cookies, server: "https://dashboard.example/hermes"))
        XCTAssertNil(partition(cookies, server: "https://user:password@dashboard.example"))
    }

    @MainActor
    func testImmediateBridgePartitionWaitsForNativeCookieBootstrap() async throws {
        let host = "catalog-bootstrap-\(UUID().uuidString.lowercased()).invalid"
        let baseURL = "https://\(host)"
        let nativeCookie = try cookie(domain: host)
        let expected = try XCTUnwrap(MessagingCatalogPartition.make(baseURL: baseURL, cookies: [nativeCookie]))
        HTTPCookieStorage.shared.setCookie(nativeCookie)
        let bridge = DashboardTicketBridge(baseURL: baseURL)
        // No readiness wait: the bridge must finish its local cookie copy
        // before producing the same partition as the effective native token.
        let result = await bridge.catalogCachePartition()
        bridge.invalidate()
        HTTPCookieStorage.shared.deleteCookie(nativeCookie)
        await DashboardCookiePersistence.clear(
            from: bridge.webView.configuration.websiteDataStore.httpCookieStore,
            for: URL(string: baseURL)
        )
        XCTAssertEqual(result, expected)
    }

    @MainActor
    func testInvalidatedBridgeCannotReturnCatalogPartition() async {
        let bridge = DashboardTicketBridge(baseURL: "https://dashboard.example")
        bridge.invalidate()
        let result = await bridge.catalogCachePartition()
        XCTAssertNil(result)
    }
}
