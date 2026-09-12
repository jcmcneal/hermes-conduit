import XCTest
@testable import Conduit

@MainActor
final class DashboardCookiePersistenceTests: XCTestCase {
    func testInsecureCookieRemainsUsableOnHTTPAfterPersistenceRoundTrip() throws {
        let original = try cookie(secure: false)
        let restored = try roundTrip(original)
        XCTAssertFalse(restored.isSecure)
        XCTAssertEqual(restored.name, original.name)
        XCTAssertEqual(restored.value, original.value)
        XCTAssertEqual(restored.domain, original.domain)
        XCTAssertEqual(restored.path, original.path)
        XCTAssertEqual(
            MessagingCatalogPartition.make(baseURL: "http://localhost", cookies: [restored]),
            try XCTUnwrap(MessagingCatalogPartition.make(baseURL: "http://localhost", cookies: [original]))
        )
    }

    func testSecureCookieRemainsRestrictedToHTTPSAfterPersistenceRoundTrip() throws {
        let original = try cookie(secure: true)
        let restored = try roundTrip(original)
        XCTAssertTrue(restored.isSecure)
        XCTAssertNil(MessagingCatalogPartition.make(baseURL: "http://localhost", cookies: [restored]))
        XCTAssertEqual(
            MessagingCatalogPartition.make(baseURL: "https://localhost", cookies: [restored]),
            try XCTUnwrap(MessagingCatalogPartition.make(baseURL: "https://localhost", cookies: [original]))
        )
    }

    private func cookie(secure: Bool) throws -> HTTPCookie {
        var properties: [HTTPCookiePropertyKey: Any] = [
            .name: "hermes_session_at", .value: "synthetic-cookie", .domain: "localhost", .path: "/"
        ]
        if secure { properties[.secure] = "TRUE" }
        return try XCTUnwrap(HTTPCookie(properties: properties))
    }

    private func roundTrip(_ cookie: HTTPCookie) throws -> HTTPCookie {
        let encoded = try JSONEncoder().encode(DashboardCookiePersistence.StoredCookie(cookie))
        let stored = try JSONDecoder().decode(DashboardCookiePersistence.StoredCookie.self, from: encoded)
        return try XCTUnwrap(stored.cookie)
    }
}
