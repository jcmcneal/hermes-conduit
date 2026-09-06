import XCTest
@testable import Conduit

/// The login card's in-memory Cloudflare service-token state must never be
/// carried to a dashboard origin it was not entered for. The setup wizard
/// hands back a validated address; these tests pin the keep-vs-clear decision
/// at that handoff boundary. Origin identity follows the canonical
/// scheme/host/effective-port semantics of `ConnectionURLPolicy`, so
/// path-only changes are same-origin while any scheme, host, or port change
/// clears the retained in-memory token. The persisted Keychain token is
/// origin-scoped and deliberately outside this decision's scope.
final class LoginCloudflareHandoffTests: XCTestCase {
    private let current = LoginCloudflareState(isEnabled: true, clientID: "cf-id", clientSecret: "cf-secret")
    private let cleared = LoginCloudflareState(isEnabled: false, clientID: "", clientSecret: "")

    func testSameOriginDifferentPathKeepsCloudflareState() {
        let state = LoginCloudflareHandoff.state(
            from: "https://foo.example/hermes",
            to: "https://foo.example/other-path",
            keeping: current
        )
        XCTAssertEqual(state, current, "A path-only change stays same-origin; the retained token may be kept")
    }

    func testDefaultPortEquivalenceKeepsCloudflareState() {
        XCTAssertEqual(
            LoginCloudflareHandoff.state(from: "https://foo.example", to: "https://foo.example:443/hermes", keeping: current),
            current,
            "Explicit default port vs no port is the same origin under existing policy"
        )
        XCTAssertEqual(
            LoginCloudflareHandoff.state(from: "http://192.168.1.28:9119/prefix", to: "http://192.168.1.28:9119", keeping: current),
            current
        )
    }

    func testDifferentHostClearsCloudflareState() {
        let state = LoginCloudflareHandoff.state(
            from: "https://foo.example/hermes",
            to: "https://bar.example/hermes",
            keeping: current
        )
        XCTAssertEqual(state, cleared)
    }

    func testDifferentPortClearsCloudflareState() {
        let state = LoginCloudflareHandoff.state(
            from: "https://foo.example:8443/hermes",
            to: "https://foo.example:9443/hermes",
            keeping: current
        )
        XCTAssertEqual(state, cleared)
    }

    func testDifferentSchemeClearsCloudflareState() {
        let state = LoginCloudflareHandoff.state(
            from: "https://foo.example/hermes",
            to: "http://foo.example/hermes",
            keeping: current
        )
        XCTAssertEqual(state, cleared)
    }

    func testUnknownPreviousOriginClearsCloudflareState() {
        // With no established previous origin (blank login card), the token's
        // origin is unknown — it must not be silently applied to the new one.
        XCTAssertEqual(LoginCloudflareHandoff.state(from: "", to: "https://foo.example", keeping: current), cleared)
        XCTAssertEqual(LoginCloudflareHandoff.state(from: "   ", to: "https://foo.example", keeping: current), cleared)
    }
}
