import XCTest
@testable import Conduit

@MainActor
final class MessagingTests: XCTestCase {
    private func capability(server: String = "server", principal: String = "alice", version: Int = 1) -> [String: Any] {
        ["server_id": server, "principal_id": principal, "api_version": version, "state": "ready",
         "features": ["dm", "groups"], "profiles": [["id": "swe-id", "name": "swe", "displayName": "SWE"]]]
    }
    private func hub(_ status: String = "enabled") -> [String: Any] {
        ["plugins": [["name": "bot-coms", "runtime_status": status]]]
    }
    func testMissingAndDisabledNeverProbeMessaging() async {
        for response in [["plugins": []], hub("disabled")] as [[String: Any]] {
            let requester = MessagingRequester { path, _, _ in
                XCTAssertTrue(["/api/dashboard/plugins/hub", "/api/auth/me"].contains(path))
                return response
            }
            let store = MessagingStore()
            store.connect(requester: requester, scope: "server")
            await store.refresh()
            XCTAssertFalse(store.isReady)
            XCTAssertEqual(requester.paths.count, 2)
        }
    }
    func testInstalledWithoutAdapterNeedsConfiguration() async {
        let requester = MessagingRequester { path, _, _ in
            if path.hasSuffix("/hub") { return self.hub() }
            throw DashboardTicketBridgeError.http(status: 404, detail: "missing")
        }
        let store = MessagingStore()
        store.connect(requester: requester, scope: "server")
        await store.refresh()
        XCTAssertEqual(store.availability, .needsConfiguration)
    }
    func testNetworkFailureIsNotMissingPlugin() async {
        let requester = MessagingRequester { _, _, _ in throw URLError(.timedOut) }
        let store = MessagingStore()
        store.connect(requester: requester, scope: "server")
        await store.refresh()
        XCTAssertEqual(store.availability, .unavailable)
        XCTAssertFalse(store.isRefreshing)
    }
    func testIncompatibleVersionDoesNotListConversations() async {
        let requester = MessagingRequester { path, _, _ in
            if path.hasSuffix("/hub") { return self.hub() }
            if path == "/api/auth/me" { return [:] }
            XCTAssertTrue(path.hasSuffix("/capabilities"))
            return self.capability(version: 2)
        }
        let store = MessagingStore()
        store.connect(requester: requester, scope: "server")
        await store.refresh()
        XCTAssertEqual(store.availability, .needsUpdate)
    }
    func testForbiddenClearsStateAndRefreshCanRetry() async {
        var forbidden = false
        let requester = MessagingRequester { path, _, _ in
            if forbidden { throw DashboardTicketBridgeError.http(status: 403, detail: "revoked") }
            if path.hasSuffix("/hub") { return self.hub() }
            if path.hasSuffix("/capabilities") { return self.capability() }
            return ["conversations": []]
        }
        let store = MessagingStore()
        store.connect(requester: requester, scope: "server")
        await store.refresh()
        XCTAssertTrue(store.isReady)
        forbidden = true
        await store.refresh()
        XCTAssertNil(store.capability)
        XCTAssertEqual(store.availability, .forbidden)
        XCTAssertFalse(store.isRefreshing)
        forbidden = false
        await store.refresh()
        XCTAssertTrue(store.isReady)
    }
    func testOldConnectionResponseCannotReplaceNewState() async {
        var resume: CheckedContinuation<[String: Any], Error>?
        let first = MessagingRequester { _, _, _ in try await withCheckedThrowingContinuation { resume = $0 } }
        let second = MessagingRequester { _, _, _ in ["plugins": []] }
        let store = MessagingStore()
        store.connect(requester: first, scope: "first")
        let fetch = Task { await store.refresh() }
        while resume == nil { await Task.yield() }
        store.connect(requester: second, scope: "second")
        await store.refresh()
        resume?.resume(returning: hub())
        await fetch.value
        XCTAssertEqual(store.availability, .missing)
        XCTAssertNil(store.capability)
    }
    func testOpenDMDoesNotWriteAndLostSendReusesClientID() async {
        var writes: [[String: Any]] = []
        let requester = MessagingRequester { path, method, body in
            if path.hasSuffix("/hub") { return self.hub() }
            if path.hasSuffix("/capabilities") { return self.capability() }
            if path.hasSuffix("/conversations") { return ["conversations": []] }
            if method == "POST" {
                writes.append(body ?? [:])
                throw URLError(.timedOut)
            }
            throw DashboardTicketBridgeError.http(status: 404, detail: "absent")
        }
        let store = MessagingStore()
        store.connect(requester: requester, scope: "server")
        await store.refresh()
        let defaults = UserDefaults(suiteName: UUID().uuidString)!
        let model = MessagingConversationStore(destination: .init(conversationID: nil, profileID: "swe-id"), owner: store, defaults: defaults)
        await model.load()
        XCTAssertTrue(writes.isEmpty)
        model.draft = "hello"
        await model.send(recipients: [])
        XCTAssertNotNil(model.pending)
        await model.checkDelivery()
        XCTAssertEqual(writes.count, 2)
        XCTAssertEqual(writes[0]["client_message_id"] as? String, writes[1]["client_message_id"] as? String)
        XCTAssertEqual(model.draft, "hello")
    }
    func testRefreshKeepsEarlierPagesAndRejectsWrongDMIdentity() async {
        var loads = 0
        var wrongIdentity = false
        let requester = MessagingRequester { path, _, _ in
            if path.hasSuffix("/hub") { return self.hub() }
            if path.hasSuffix("/capabilities") { return self.capability() }
            if path == "/api/auth/me" { return [:] }
            if path.hasSuffix("/conversations") { return ["conversations": []] }
            loads += 1
            let sequences = loads == 1 ? [3, 4] : (loads == 2 ? [1, 2] : [3, 4, 5])
            var result: [String: Any] = [
                "conversation": ["id": "dm", "kind": "dm", "title": "SWE", "profiles": [wrongIdentity ? "other" : "swe-id"],
                    "default_responder": "swe-id", "revision": 1, "preview": "", "updated_at": 1, "unread": 0, "archived": false, "pinned": false, "muted": false],
                "messages": sequences.map { ["id": "m\($0)", "sequence": $0, "author": "user", "body": "Message \($0)", "created_at": 1] as [String: Any] },
                "runs": []
            ]
            if loads != 2 { result["before"] = 3 }
            return result
        }
        let owner = MessagingStore()
        owner.connect(requester: requester, scope: "server")
        await owner.refresh()
        let model = MessagingConversationStore(destination: .init(conversationID: nil, profileID: "swe-id"), owner: owner, defaults: UserDefaults(suiteName: UUID().uuidString)!)
        await model.load()
        await model.load(older: true)
        await model.load()
        XCTAssertEqual(model.history?.messages.map(\.sequence), [1, 2, 3, 4, 5])
        XCTAssertNil(model.history?.before)
        wrongIdentity = true
        await model.load()
        XCTAssertNotNil(model.error)
        XCTAssertEqual(model.history?.conversation.profiles, ["swe-id"])
    }

    func testRequestsCarryTheVerifiedAccountAndEscapePlusSigns() async {
        let requester = MessagingRequester { path, _, _ in
            if path.hasSuffix("/hub") { return self.hub() }
            if path.hasSuffix("/capabilities") { return self.capability(principal: "alice+one") }
            return ["conversations": []]
        }
        let owner = MessagingStore()
        owner.connect(requester: requester, scope: "server")
        await owner.refresh()
        let path = requester.paths.last ?? ""
        XCTAssertTrue(path.contains("expected_principal=alice%2Bone"))
        XCTAssertTrue(path.contains("expected_server=server"))
    }

    func testPendingSendSurvivesViewRecreationAndDraftsAreIsolated() async {
        let requester = MessagingRequester { path, _, _ in
            if path.hasSuffix("/hub") { return self.hub() }
            if path.hasSuffix("/capabilities") { return self.capability() }
            if path.hasSuffix("/conversations") { return ["conversations": []] }
            throw URLError(.timedOut)
        }
        let store = MessagingStore()
        store.connect(requester: requester, scope: "server")
        await store.refresh()
        let defaults = UserDefaults(suiteName: UUID().uuidString)!
        let dm = MessagingDestination(conversationID: nil, profileID: "swe-id")
        let first = MessagingConversationStore(destination: dm, owner: store, defaults: defaults)
        first.draft = "keep me"; first.saveDraft()
        await first.send(recipients: [])
        let restored = MessagingConversationStore(destination: dm, owner: store, defaults: defaults)
        XCTAssertEqual(restored.pending, first.pending)
        XCTAssertEqual(restored.draft, "keep me")
        let other = MessagingConversationStore(destination: .init(conversationID: "group", profileID: nil), owner: store, defaults: defaults)
        XCTAssertTrue(other.draft.isEmpty)
        XCTAssertNil(other.pending)
    }

    func testSetupPromptPrincipalFormatting() {
        XCTAssertEqual(
            MessagingSetupPrompt.principal(from: ["provider": "nous", "user_id": "abc"]),
            "nous:abc"
        )
        XCTAssertEqual(
            MessagingSetupPrompt.principal(from: ["provider": "basic", "user_id": "u1", "org_id": "org9"]),
            "basic:u1:org9"
        )
        XCTAssertNil(MessagingSetupPrompt.principal(from: ["provider": "nous"]))
        XCTAssertNil(MessagingSetupPrompt.principal(from: ["user_id": "abc"]))
    }

    func testSetupPromptEmbedsPrincipalAndSkipsBrowserScavengerHunt() {
        let withPrincipal = MessagingSetupPrompt.text(principal: "nous:abc", activeProfile: "hermes")
        XCTAssertTrue(withPrincipal.contains("Operator principal (authenticated in this client): nous:abc"))
        XCTAssertTrue(withPrincipal.contains("auto_enroll_profiles"))
        XCTAssertTrue(withPrincipal.contains("Do NOT ask me to open a browser"))
        XCTAssertTrue(withPrincipal.contains("Active Hermes profile in this client: hermes"))

        let without = MessagingSetupPrompt.text(principal: nil, activeProfile: "default")
        XCTAssertTrue(without.contains("could not read your signed-in account id"))
        XCTAssertTrue(without.contains("Do NOT ask me to open a browser"))
        XCTAssertFalse(without.contains("Operator principal (authenticated in this client):"))
    }

    func testBotPinsTogglePersistAndPruneUnknownIds() async throws {
        let suite = "messaging-bot-pins-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        let requester = MessagingRequester { path, _, _ in
            if path.hasSuffix("/hub") { return self.hub() }
            if path.hasSuffix("/capabilities") {
                return [
                    "server_id": "server", "principal_id": "alice", "api_version": 1, "state": "ready",
                    "features": ["dm", "groups"],
                    "profiles": [
                        ["id": "swe-id", "name": "swe", "displayName": "SWE"],
                        ["id": "designer-id", "name": "designer", "displayName": "Designer"],
                    ],
                ]
            }
            return ["conversations": []]
        }
        let store = MessagingStore(defaults: defaults)
        store.connect(requester: requester, scope: "server")
        await store.refresh()
        XCTAssertTrue(store.isReady)

        store.toggleBotPinned("swe-id")
        store.toggleBotPinned("ghost-id")
        XCTAssertEqual(store.pinnedBotIDs, ["swe-id", "ghost-id"])
        XCTAssertTrue(store.isBotPinned("swe-id"))

        await store.refresh()
        XCTAssertEqual(store.pinnedBotIDs, ["swe-id"], "Unknown bot ids are pruned after capability refresh")

        let reloaded = MessagingStore(defaults: defaults)
        reloaded.connect(requester: requester, scope: "server")
        await reloaded.refresh()
        XCTAssertEqual(reloaded.pinnedBotIDs, ["swe-id"])
        reloaded.toggleBotPinned("swe-id")
        XCTAssertFalse(reloaded.isBotPinned("swe-id"))
        XCTAssertTrue(reloaded.pinnedBotIDs.isEmpty)
    }

    func testGroupPinsPersistSurviveRefreshAndPruneAfterConversationsLoad() async throws {
        let suite = "messaging-group-pins-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        var includeHot = true
        let requester = MessagingRequester { path, _, _ in
            if path.hasSuffix("/hub") { return self.hub() }
            if path.hasSuffix("/capabilities") {
                return [
                    "server_id": "server", "principal_id": "alice", "api_version": 1, "state": "ready",
                    "features": ["dm", "groups"],
                    "profiles": [
                        ["id": "swe-id", "name": "swe", "displayName": "SWE"],
                        ["id": "designer-id", "name": "designer", "displayName": "Designer"],
                    ],
                ]
            }
            var rows: [[String: Any]] = [
                ["id": "g-hot", "kind": "group", "title": "Hot crew", "profiles": ["swe-id", "designer-id"], "default_responder": "swe-id", "revision": 1, "preview": "now", "updated_at": 80, "unread": 1, "archived": false, "pinned": false, "muted": false],
                ["id": "g-arch", "kind": "group", "title": "Archived crew", "profiles": ["swe-id", "designer-id"], "default_responder": "swe-id", "revision": 1, "preview": "gone", "updated_at": 100, "unread": 0, "archived": true, "pinned": false, "muted": false],
            ]
            if !includeHot {
                rows.removeAll { ($0["id"] as? String) == "g-hot" }
            }
            return ["conversations": rows]
        }
        let store = MessagingStore(defaults: defaults)
        store.connect(requester: requester, scope: "server")
        await store.refresh()

        store.toggleGroupPinned("g-hot")
        store.toggleGroupPinned("g-gone")
        store.toggleBotPinned("swe-id")
        XCTAssertTrue(store.isGroupPinned("g-hot"))
        XCTAssertEqual(
            store.pinnedBotIDs,
            ["group:g-hot", "group:g-gone", "swe-id"],
            "Group pins use a group: prefix alongside bot ids"
        )

        await store.refresh()
        XCTAssertEqual(
            store.pinnedBotIDs,
            ["group:g-hot", "swe-id"],
            "Unknown/archived group pins prune only after conversations load; bot pins stay"
        )
        XCTAssertEqual(store.pinnedShelfItems.map(\.id), ["group:g-hot", "swe-id"])

        includeHot = false
        await store.refresh()
        XCTAssertEqual(store.pinnedBotIDs, ["swe-id"], "Missing groups prune after the next conversations fetch")
        XCTAssertFalse(store.isGroupPinned("g-hot"))
    }

    func testUnpinnedShelfSkipsDMsAndArchivedAndInterleavesPinOrder() async {
        let requester = MessagingRequester { path, _, _ in
            if path.hasSuffix("/hub") { return self.hub() }
            if path.hasSuffix("/capabilities") {
                return [
                    "server_id": "server", "principal_id": "alice", "api_version": 1, "state": "ready",
                    "features": ["dm", "groups"],
                    "profiles": [
                        ["id": "swe-id", "name": "swe", "displayName": "SWE"],
                        ["id": "designer-id", "name": "designer", "displayName": "Designer"],
                    ],
                ]
            }
            return [
                "conversations": [
                    ["id": "dm-1", "kind": "dm", "title": "SWE", "profiles": ["swe-id"], "default_responder": "swe-id", "revision": 1, "preview": "hi", "updated_at": 90, "unread": 0, "archived": false, "pinned": false, "muted": false],
                    ["id": "g-old", "kind": "group", "title": "Old crew", "profiles": ["swe-id", "designer-id"], "default_responder": "swe-id", "revision": 1, "preview": "later", "updated_at": 40, "unread": 0, "archived": false, "pinned": false, "muted": false],
                    ["id": "g-hot", "kind": "group", "title": "Hot crew", "profiles": ["swe-id", "designer-id"], "default_responder": "swe-id", "revision": 1, "preview": "now", "updated_at": 80, "unread": 1, "archived": false, "pinned": false, "muted": false],
                    ["id": "g-arch", "kind": "group", "title": "Archived crew", "profiles": ["swe-id", "designer-id"], "default_responder": "swe-id", "revision": 1, "preview": "gone", "updated_at": 100, "unread": 0, "archived": true, "pinned": true, "muted": false],
                ]
            ]
        }
        let store = MessagingStore()
        store.connect(requester: requester, scope: "server")
        await store.refresh()

        store.toggleGroupPinned("g-old")
        store.toggleBotPinned("designer-id")
        XCTAssertEqual(store.pinnedShelfItems.map(\.id), ["group:g-old", "designer-id"])
        XCTAssertEqual(
            store.unpinnedShelfItems.map(\.id),
            ["swe-id", "group:g-hot"],
            "Unpinned: remaining bots in capability order, then active groups by recency; DMs and archived stay out"
        )
    }

    func testDeleteGroupIssuesDeleteAndClearsHistory() async {
        var deletedPath: String?
        var methods: [String] = []
        let requester = MessagingRequester { path, method, _ in
            methods.append(method)
            if path.hasSuffix("/hub") { return self.hub() }
            if path.hasSuffix("/capabilities") {
                return [
                    "server_id": "server", "principal_id": "alice", "api_version": 1, "state": "ready",
                    "features": ["dm", "groups"],
                    "profiles": [
                        ["id": "swe-id", "name": "swe", "displayName": "SWE"],
                        ["id": "designer-id", "name": "designer", "displayName": "Designer"],
                    ],
                ]
            }
            if path.hasSuffix("/conversations") { return ["conversations": []] }
            // MessagingService.component percent-encodes non-alphanumerics (hyphen → %2D).
            if path.contains("/conversations/g%2D1") && method == "GET" {
                return [
                    "conversation": [
                        "id": "g-1", "kind": "group", "title": "Room",
                        "profiles": ["swe-id", "designer-id"], "default_responder": "swe-id",
                        "revision": 1, "preview": "hi", "updated_at": 1, "unread": 0,
                        "archived": false, "pinned": false, "muted": false,
                    ],
                    "messages": [["id": "m1", "sequence": 1, "author": "user", "body": "hi", "created_at": 1]],
                    "runs": [],
                ]
            }
            if path.contains("/conversations/g%2D1") && method == "DELETE" {
                deletedPath = path
                return ["ok": true]
            }
            return [:]
        }
        let owner = MessagingStore()
        owner.connect(requester: requester, scope: "server")
        await owner.refresh()
        let model = MessagingConversationStore(
            destination: .init(conversationID: "g-1", profileID: nil),
            owner: owner,
            defaults: UserDefaults(suiteName: UUID().uuidString)!
        )
        await model.load()
        XCTAssertEqual(model.history?.conversation.id, "g-1")
        let ok = await model.deleteGroup()
        XCTAssertTrue(ok)
        XCTAssertNil(model.history)
        XCTAssertNotNil(deletedPath)
        XCTAssertTrue(deletedPath?.contains("/conversations/") == true)
        XCTAssertTrue(methods.contains("DELETE"))
    }

    func testMentionDisplayRewritesProfileIdsOnly() {
        let profiles = [
            MessagingProfile(id: "designer-id", name: "designer", displayName: "Designer"),
            MessagingProfile(id: "swe-id", name: "swe", displayName: "SWE"),
        ]
        let body = "Ask @designer-id and @Designer; also `@swe-id` stays code-like but still rewrites outside fences."
        let rewritten = MessagingMentionDisplay.rewriteBody(body, profiles: profiles)
        XCTAssertEqual(
            rewritten,
            "Ask @Designer and @Designer; also `@SWE` stays code-like but still rewrites outside fences."
        )
        XCTAssertEqual(
            MessagingMentionDisplay.rewriteBody("Ping @unknown-bot please", profiles: profiles),
            "Ping @unknown-bot please"
        )
        XCTAssertEqual(
            MessagingMentionDisplay.rewriteBody("Hand to @{swe-id} please", profiles: profiles),
            "Hand to @SWE please"
        )
    }
}

@MainActor
private final class MessagingRequester: DashboardJSONRequester {
    let handler: (String, String, [String: Any]?) async throws -> [String: Any]
    var paths: [String] = []
    init(_ handler: @escaping (String, String, [String: Any]?) async throws -> [String: Any]) { self.handler = handler }
    func requestJSON(path: String, method: String, body: [String: Any]?, timeoutMilliseconds: Int, maxResponseBytes: Int) async throws -> [String: Any] {
        paths.append(path)
        return try await handler(String(path.split(separator: "?", maxSplits: 1)[0]), method, body)
    }
}
