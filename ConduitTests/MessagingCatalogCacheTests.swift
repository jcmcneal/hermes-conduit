import Combine
import XCTest
import WebKit
@testable import Conduit

@MainActor
final class MessagingCatalogCacheTests: XCTestCase {
    private var suites: [String] = []

    override func tearDown() async throws {
        for suite in suites { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }
        try await super.tearDown()
    }

    func testColdStoreRestoresDisplayCatalogBeforeNetworkWithoutGrantingWriteAuthority() async {
        let defaults = makeDefaults()
        let initial = await readyStore(defaults)
        XCTAssertTrue(initial.isReady)
        let requester = CatalogRequester()
        let cold = MessagingStore(defaults: defaults)
        cold.connect(requester: requester, scope: "dashboard", catalogPartition: "opaque-alice")
        XCTAssertEqual(cold.profiles.map(\.id), ["swe-id", "designer-id"])
        XCTAssertEqual(requester.requests, 0)
        XCTAssertNil(cold.capability)
        XCTAssertNil(cold.service?.capability)
        XCTAssertFalse(cold.isReady)
        XCTAssertEqual(cold.availability, .checking)
        let conversation = MessagingConversationStore(destination: .init(conversationID: nil, profileID: "swe-id"),
                                                       owner: cold, defaults: defaults)
        XCTAssertFalse(conversation.canWrite)
        _ = await conversation.send(recipients: [], text: "must not send")
        XCTAssertEqual(requester.requests, 0)
    }

    func testFreshStoreWithRealOfflineBridgeRestoresBotsWithoutCookiesOrServerResponse() async throws {
        let defaults = makeDefaults()
        let server = "https://cold-bots-\(UUID().uuidString.lowercased()).invalid"
        let namespace = try XCTUnwrap(ConnectionCacheNamespaceStore(defaults: defaults).namespace(for: server))
        let first = MessagingStore(defaults: defaults)
        first.connect(requester: CatalogRequester(), scope: server, catalogPartition: namespace)
        await first.refresh()
        XCTAssertTrue(first.isReady)

        // Recreate every cache owner from persisted defaults, as on launch.
        // No cookie is seeded and the reserved .invalid host cannot serve a
        // capability response. Restoring the catalog must be entirely local.
        let restartedDefaults = try XCTUnwrap(UserDefaults(suiteName: try XCTUnwrap(suites.last)))
        let cold = MessagingStore(defaults: restartedDefaults)
        var accountChanges = 0
        cold.onCacheIdentityChanged = { accountChanges += 1 }
        let requests = DashboardTicketBridgePendingRequests()
        let bridge = DashboardTicketBridge(baseURL: server, pendingRequests: requests, readinessPollAttempts: 0)
        defer { bridge.invalidate() }
        await cold.connectDashboard(bridge, scope: server)

        XCTAssertEqual(cold.profiles, profiles)
        XCTAssertEqual(cold.availability, .checking)
        XCTAssertFalse(cold.isReady)
        XCTAssertFalse(cold.isRefreshing)
        XCTAssertNil(cold.capability)
        XCTAssertNil(cold.service?.capability)
        XCTAssertEqual(requests.count, 0)
        XCTAssertEqual(accountChanges, 0)
        XCTAssertNil(MessagingCatalogPartition.make(baseURL: server, cookies: []),
                     "A missing cookie partition must no longer prevent cold catalog display")
        let conversation = MessagingConversationStore(destination: .init(conversationID: nil, profileID: "swe-id"),
                                                       owner: cold, defaults: restartedDefaults)
        let sent = await conversation.send(recipients: [], text: "must not send before verification")
        XCTAssertFalse(sent)
        XCTAssertFalse(conversation.canWrite)
        XCTAssertEqual(requests.count, 0)
    }

    func testRealBridgeCredentialRotationKeepsPersistedLogicalConnectionCatalog() async throws {
        let defaults = makeDefaults()
        let host = "rotating-bots-\(UUID().uuidString.lowercased()).invalid"
        let server = "https://\(host)"
        let namespace = try XCTUnwrap(ConnectionCacheNamespaceStore(defaults: defaults).namespace(for: server))
        MessagingCatalogCache(defaults: defaults).save(profiles: profiles, verifiedScope: "server/alice", for: namespace)
        let oldToken = try XCTUnwrap(HTTPCookie(properties: [
            .name: "hermes_session_at", .value: "synthetic-old-token", .domain: host, .path: "/", .secure: "TRUE"
        ]))
        let newToken = try XCTUnwrap(HTTPCookie(properties: [
            .name: "hermes_session_at", .value: "synthetic-renewed-token", .domain: host, .path: "/", .secure: "TRUE"
        ]))
        XCTAssertNotEqual(MessagingCatalogPartition.make(baseURL: server, cookies: [oldToken]),
                          MessagingCatalogPartition.make(baseURL: server, cookies: [newToken]))
        HTTPCookieStorage.shared.setCookie(oldToken)
        let firstBridge = DashboardTicketBridge(baseURL: server, readinessPollAttempts: 0)
        let first = MessagingStore(defaults: defaults)
        await first.connectDashboard(firstBridge, scope: server)
        _ = await firstBridge.catalogCachePartition()
        firstBridge.invalidate()
        HTTPCookieStorage.shared.setCookie(newToken)
        let renewedBridge = DashboardTicketBridge(baseURL: server, readinessPollAttempts: 0)
        let restarted = MessagingStore(defaults: defaults)
        var accountChanges = 0
        restarted.onCacheIdentityChanged = { accountChanges += 1 }
        await restarted.connectDashboard(renewedBridge, scope: server)
        _ = await renewedBridge.catalogCachePartition()
        renewedBridge.invalidate()
        HTTPCookieStorage.shared.deleteCookie(newToken)
        await DashboardCookiePersistence.clear(from: renewedBridge.webView.configuration.websiteDataStore.httpCookieStore,
                                               for: URL(string: server))

        XCTAssertEqual(first.profiles, profiles)
        XCTAssertEqual(restarted.profiles, profiles)
        XCTAssertFalse(restarted.isReady)
        XCTAssertEqual(accountChanges, 0)
        XCTAssertEqual(ConnectionCacheNamespaceStore(defaults: defaults).namespace(for: server), namespace)
        XCTAssertNotNil(MessagingCatalogCache(defaults: defaults).snapshot(for: namespace))
    }

    func testNilDashboardBridgePurgesColdCatalogAtSignOut() async throws {
        let defaults = makeDefaults()
        let server = "https://signout-bots-\(UUID().uuidString.lowercased()).invalid"
        let namespaces = ConnectionCacheNamespaceStore(defaults: defaults)
        let namespace = try XCTUnwrap(namespaces.namespace(for: server))
        MessagingCatalogCache(defaults: defaults).save(profiles: profiles, verifiedScope: "server/alice", for: namespace)
        let bridge = DashboardTicketBridge(baseURL: server, readinessPollAttempts: 0)
        defer { bridge.invalidate() }
        let store = MessagingStore(defaults: defaults)
        await store.connectDashboard(bridge, scope: server)
        XCTAssertEqual(store.profiles, profiles)

        namespaces.revoke() // AppState's explicit sign-out lifecycle boundary.
        await store.connectDashboard(nil, scope: server)
        XCTAssertTrue(store.profiles.isEmpty)
        XCTAssertFalse(store.isReady)
        XCTAssertNil(MessagingCatalogCache(defaults: defaults).snapshot(for: namespace))
        XCTAssertNotEqual(namespaces.namespace(for: server), namespace)
    }

    func testColdCatalogRestoresPinsFromVerifiedScope() async {
        let defaults = makeDefaults()
        let initial = await readyStore(defaults)
        initial.toggleBotPinned("designer-id")
        let cold = MessagingStore(defaults: defaults)
        cold.connect(requester: CatalogRequester(), scope: "dashboard", catalogPartition: "opaque-alice")
        XCTAssertEqual(cold.pinnedBotIDs, ["designer-id"])
        XCTAssertEqual(cold.pinnedShelfItems.map(\.id), ["designer-id"])
        XCTAssertFalse(cold.isReady)
        cold.toggleBotPinned("newer-bot-not-in-stale-catalog")
        let reopened = MessagingStore(defaults: defaults)
        reopened.connect(requester: CatalogRequester(), scope: "dashboard", catalogPartition: "opaque-alice")
        XCTAssertTrue(reopened.pinnedBotIDs.contains("newer-bot-not-in-stale-catalog"),
                      "Cached display metadata is not authority to prune persisted pins")
    }

    func testPartitionsDoNotExposeAnotherAccountsCatalog() async {
        let defaults = makeDefaults()
        _ = await readyStore(defaults)
        let other = MessagingStore(defaults: defaults)
        other.connect(requester: CatalogRequester(), scope: "dashboard", catalogPartition: "opaque-bob")
        XCTAssertTrue(other.profiles.isEmpty)
        let withoutPartition = MessagingStore(defaults: defaults)
        withoutPartition.connect(requester: CatalogRequester(), scope: "dashboard")
        XCTAssertTrue(withoutPartition.profiles.isEmpty)
    }

    func testBridgeReplacementWithSamePartitionRetainsCatalogDuringTransientFailure() async {
        let defaults = makeDefaults()
        let store = await readyStore(defaults)
        let replacement = CatalogRequester()
        replacement.mode = .transient
        store.connect(requester: replacement, scope: "dashboard", catalogPartition: "opaque-alice")
        XCTAssertEqual(store.profiles.count, 2)
        await store.refresh()
        XCTAssertEqual(store.availability, .unavailable)
        XCTAssertEqual(store.profiles.count, 2)
        XCTAssertNotNil(MessagingCatalogCache(defaults: defaults).snapshot(for: "opaque-alice"))
    }

    func testAuthorizationFailurePurgesPersistedAndDisplayedCatalog() async {
        let defaults = makeDefaults()
        let requester = CatalogRequester()
        let store = await readyStore(defaults, requester: requester)
        requester.mode = .forbidden
        await store.refresh()
        XCTAssertEqual(store.availability, .forbidden)
        XCTAssertTrue(store.profiles.isEmpty)
        XCTAssertNil(MessagingCatalogCache(defaults: defaults).snapshot(for: "opaque-alice"))
    }

    func testDisconnectPurgesThePreviouslyAuthenticatedCatalog() async {
        let defaults = makeDefaults()
        let store = await readyStore(defaults)
        store.connect(requester: nil, scope: "dashboard")
        XCTAssertTrue(store.profiles.isEmpty)
        XCTAssertNil(MessagingCatalogCache(defaults: defaults).snapshot(for: "opaque-alice"))
    }

    func testCancelledDashboardConnectionDoesNotTreatNilPartitionAsSignOut() async {
        let defaults = makeDefaults()
        let store = await readyStore(defaults)
        let bridge = DashboardTicketBridge(baseURL: "https://catalog-cancellation.example")
        defer { bridge.invalidate() }
        // Main-actor scheduling makes cancellation deterministic before the helper
        // reaches its partition lookup. The real bridge returns nil to a cancelled caller.
        let task = Task { @MainActor in await store.connectDashboard(bridge, scope: "dashboard") }
        task.cancel()
        await task.value
        XCTAssertNotNil(MessagingCatalogCache(defaults: defaults).snapshot(for: "opaque-alice"),
                        "A cancelled local lookup is not evidence that the account signed out")
    }

    func testConfirmedMissingDisabledAndIncompatibleCapabilitiesClearCatalog() async {
        for mode: CatalogRequester.Mode in [.missing, .disabled, .incompatible, .unconfigured] {
            let defaults = makeDefaults()
            let requester = CatalogRequester()
            let store = await readyStore(defaults, requester: requester)
            requester.mode = mode
            await store.refresh()
            XCTAssertFalse(store.isReady)
            XCTAssertTrue(store.profiles.isEmpty)
            XCTAssertNil(MessagingCatalogCache(defaults: defaults).snapshot(for: "opaque-alice"))
        }
    }

    func testChangedPrincipalPurgesOldCatalogEvenWhenCapabilityRefreshFails() async {
        let defaults = makeDefaults()
        let requester = CatalogRequester()
        let store = await readyStore(defaults, requester: requester)
        requester.principal = "bob"
        requester.mode = .capabilityFailure
        await store.refresh()
        XCTAssertTrue(store.profiles.isEmpty)
        XCTAssertNil(MessagingCatalogCache(defaults: defaults).snapshot(for: "opaque-alice"))
    }

    func testIdenticalCapabilityRefreshDoesNotPublishCapabilityOrDisplayProfiles() async {
        let defaults = makeDefaults()
        let store = await readyStore(defaults)
        var capabilities = 0
        var catalogs = 0
        let capabilitySubscription = store.$capability.dropFirst().sink { _ in capabilities += 1 }
        let catalogSubscription = store.$cachedDisplayProfiles.dropFirst().sink { _ in catalogs += 1 }
        await store.refresh()
        await store.refresh()
        XCTAssertEqual(capabilities, 0)
        XCTAssertEqual(catalogs, 0)
        withExtendedLifetime((capabilitySubscription, catalogSubscription)) {}
    }

    func testExpiredAndCorruptSnapshotsAreRemoved() {
        let defaults = makeDefaults()
        var now = Date(timeIntervalSince1970: 1_000)
        let cache = MessagingCatalogCache(defaults: defaults, ttl: 60, now: { now })
        cache.save(profiles: profiles, verifiedScope: "scope", for: "opaque")
        XCTAssertNotNil(cache.snapshot(for: "opaque"))
        now.addTimeInterval(60)
        XCTAssertNil(cache.snapshot(for: "opaque"))
        XCTAssertNil(defaults.data(forKey: MessagingCatalogCache.storageKey))
        defaults.set(Data("invalid JSON".utf8), forKey: MessagingCatalogCache.storageKey)
        XCTAssertNil(cache.snapshot(for: "opaque"))
        XCTAssertNil(defaults.data(forKey: MessagingCatalogCache.storageKey))
    }

    func testPartitionAndEncodedByteBounds() {
        let defaults = makeDefaults()
        var now = Date(timeIntervalSince1970: 1_000)
        let cache = MessagingCatalogCache(defaults: defaults, maxPartitions: 4, maxBytes: 1_024, now: { now })
        for index in 0..<5 {
            now.addTimeInterval(1)
            cache.save(profiles: [profiles[0]], verifiedScope: "scope", for: "opaque-\(index)")
        }
        XCTAssertNil(cache.snapshot(for: "opaque-0"))
        XCTAssertNotNil(cache.snapshot(for: "opaque-4"))
        XCTAssertLessThanOrEqual(defaults.data(forKey: MessagingCatalogCache.storageKey)?.count ?? 0, 1_024)
        cache.save(profiles: [.init(id: "large", name: "large", displayName: String(repeating: "x", count: 2_000))],
                   verifiedScope: "scope", for: "oversize")
        XCTAssertNil(cache.snapshot(for: "oversize"))
        XCTAssertNotNil(cache.snapshot(for: "opaque-4"), "An oversized entry must not evict useful bounded snapshots")
        XCTAssertLessThanOrEqual(defaults.data(forKey: MessagingCatalogCache.storageKey)?.count ?? 0, 1_024)
    }

    func testDuplicateProfilesAreNeverRestoredAndPayloadContainsNoAuthorityOrMessages() {
        let defaults = makeDefaults()
        let cache = MessagingCatalogCache(defaults: defaults)
        cache.save(profiles: [profiles[0], profiles[0]], verifiedScope: "scope", for: "duplicate")
        XCTAssertNil(cache.snapshot(for: "duplicate"))
        cache.save(profiles: profiles, verifiedScope: "scope", for: "opaque")
        let data = defaults.data(forKey: MessagingCatalogCache.storageKey)!
        let json = String(decoding: data, as: UTF8.self)
        XCTAssertFalse(json.contains("features"))
        XCTAssertFalse(json.contains("api_version"))
        XCTAssertFalse(json.contains("messages"))
        XCTAssertFalse(json.contains("preview"))
        XCTAssertFalse(json.contains("cookie"))
    }

    private var profiles: [MessagingProfile] {
        [.init(id: "swe-id", name: "swe", displayName: "SWE"),
         .init(id: "designer-id", name: "designer", displayName: "Designer")]
    }

    private func makeDefaults() -> UserDefaults {
        let suite = "MessagingCatalogCacheTests." + UUID().uuidString
        suites.append(suite)
        return UserDefaults(suiteName: suite)!
    }

    private func readyStore(_ defaults: UserDefaults, requester: CatalogRequester? = nil) async -> MessagingStore {
        let requester = requester ?? CatalogRequester()
        let store = MessagingStore(defaults: defaults)
        store.connect(requester: requester, scope: "dashboard", catalogPartition: "opaque-alice")
        await store.refresh()
        XCTAssertTrue(store.isReady)
        return store
    }
}

@MainActor
private final class CatalogRequester: DashboardJSONRequester {
    enum Mode { case ready, missing, disabled, incompatible, unconfigured, transient, forbidden, capabilityFailure }
    var mode = Mode.ready
    var principal = "alice"
    var requests = 0

    func requestJSON(path: String, method: String, body: [String: Any]?, timeoutMilliseconds: Int,
                     maxResponseBytes: Int) async throws -> [String: Any] {
        requests += 1
        if mode == .transient { throw URLError(.notConnectedToInternet) }
        if mode == .forbidden { throw DashboardTicketBridgeError.http(status: 401, detail: "expired") }
        let base = String(path.split(separator: "?", maxSplits: 1)[0])
        if base.hasSuffix("/hub") {
            return ["plugins": mode == .missing ? [] : [["name": "bot-coms", "runtime_status": mode == .disabled ? "disabled" : "enabled"]]]
        }
        if base == "/api/auth/me" { return ["user_id": principal] }
        if base.hasSuffix("/capabilities") {
            if mode == .capabilityFailure { throw URLError(.timedOut) }
            return ["server_id": "server", "principal_id": principal, "api_version": mode == .incompatible ? 2 : 1,
                    "state": mode == .unconfigured ? "setup" : "ready", "features": ["dm", "groups"],
                    "profiles": [["id": "swe-id", "name": "swe", "displayName": "SWE"],
                                 ["id": "designer-id", "name": "designer", "displayName": "Designer"]]]
        }
        if base.hasSuffix("/conversations") { return ["conversations": []] }
        throw DashboardTicketBridgeError.http(status: 404, detail: "absent")
    }
}
