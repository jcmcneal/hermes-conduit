#if DEBUG
import Foundation

/// Explicit, inert UI-test transport. Never connects or launches a real bot.
@MainActor
final class MessagingUITestFixture: DashboardJSONRequester {
    static let shared = MessagingUITestFixture()
    static var requested: Bool { ProcessInfo.processInfo.arguments.contains("-CONDUIT_UI_TEST_MESSAGING") }
    private var sent: [[String: Any]] = []
    private var conversation: [String: Any] {
        ["id": "dm-fixture", "kind": "dm", "title": "Designer", "profiles": ["designer-id"], "default_responder": "designer-id", "revision": 1,
         "preview": "Here's the revised session picker.", "updated_at": Date().timeIntervalSince1970 - 120, "unread": 1,
         "archived": false, "pinned": false, "muted": false]
    }
    func requestJSON(path: String, method: String, body: [String: Any]?, timeoutMilliseconds: Int, maxResponseBytes: Int) async throws -> [String: Any] {
        let path = String(path.split(separator: "?", maxSplits: 1)[0])
        if path.hasSuffix("/hub"), ProcessInfo.processInfo.arguments.contains("-CONDUIT_UI_TEST_MESSAGING_MISSING") { return ["plugins": []] }
        if path.hasSuffix("/hub") { return ["plugins": [["name": "bot-coms", "runtime_status": "enabled"]]] }
        if path == "/api/auth/me" || path.hasSuffix("/auth/me") {
            return ["user_id": "fixture-user", "provider": "fixture", "email": "fixture@example.com", "display_name": "Fixture"]
        }
        if path.hasSuffix("/capabilities") {
            return ["server_id": "fixture-server", "principal_id": "fixture-account", "api_version": 1, "state": "ready", "features": ["dm", "groups"],
                    "profiles": [["id": "designer-id", "name": "default", "displayName": "Designer"], ["id": "swe-id", "name": "research", "displayName": "SWE"]]]
        }
        if path.hasSuffix("/read-state") { return ["sequence": body?["sequence"] ?? 0] }
        if path.hasSuffix("/conversations") { return ["conversations": [conversation]] }
        if method == "POST" && path.hasSuffix("/messages") {
            let message: [String: Any] = ["id": body?["client_message_id"] ?? UUID().uuidString, "author": "user", "body": body?["body"] ?? "", "sequence": sent.count + 3, "created_at": Date().timeIntervalSince1970]
            sent.append(message)
            return ["conversation": conversation, "message": message]
        }
        return ["conversation": conversation, "messages": [
            ["id": "m1", "author": "user", "body": "Can we simplify the session picker?", "sequence": 1, "created_at": 1_788_900_000],
            ["id": "m2", "author": "designer-id", "body": "Yes. Keep an ongoing DM one tap away, with **Sessions** available separately. Groups can bring multiple profiles together.", "sequence": 2, "created_at": 1_788_900_001]
        ] + sent, "runs": []]
    }
}
#endif
