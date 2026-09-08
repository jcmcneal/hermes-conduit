import Foundation
import SwiftUI

/// Owned by a connection, independent of the currently selected session profile.
@MainActor
final class MessagingStore: ObservableObject {
    @Published private(set) var availability: MessagingAvailability = .checking
    @Published private(set) var capability: MessagingCapability?
    @Published private(set) var conversations: [MessagingConversation] = []
    @Published private(set) var error: String?
    @Published private(set) var isRefreshing = false
    @Published private(set) var cardDismissed = false
    private(set) var service: MessagingService?
    private(set) var generation = UUID()
    private var bridgeID: ObjectIdentifier?
    private var presentationScope = ""
    private var dismissalScope = ""
    private var verifiedIdentityScope: String?
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) { self.defaults = defaults }
    var isReady: Bool { availability == .ready && capability?.isReady == true }
    var showInbox: Bool { isReady || !conversations.isEmpty }
    var profiles: [MessagingProfile] { capability?.profiles ?? [] }

    func connect(requester: (any DashboardJSONRequester)?, scope: String) {
        let identity = requester.map { ObjectIdentifier($0) }
        guard identity != bridgeID || scope != presentationScope else { return }
        generation = UUID()
        bridgeID = identity
        presentationScope = scope
        dismissalScope = scope
        verifiedIdentityScope = nil
        service = requester.map(MessagingService.init)
        capability = nil
        conversations = []
        error = nil
        isRefreshing = false
        availability = requester == nil ? .unavailable : .checking
        cardDismissed = defaults.bool(forKey: dismissalKey)
    }
    private var dismissalKey: String { "conduit.messaging.discovery.v1." + dismissalScope }
    func dismissCard() { cardDismissed = true; defaults.set(true, forKey: dismissalKey) }

    func refresh() async {
        guard let service, !isRefreshing else { return }
        var epoch = generation
        isRefreshing = true
        defer { if generation == epoch { isRefreshing = false } }
        do {
            let hub = try await service.hub()
            guard epoch == generation else { return }
            do {
                let identity = try await service.identity()
                guard epoch == generation else { return }
                if let user = identity["user_id"] as? String {
                    let parts = [presentationScope, identity["provider"] as? String ?? "", user, identity["org_id"] as? String ?? ""]
                    dismissalScope = (try? JSONEncoder().encode(parts).base64EncodedString()) ?? presentationScope
                    if let previous = verifiedIdentityScope, previous != dismissalScope {
                        generation = UUID(); epoch = generation
                        capability = nil; service.capability = nil; conversations = []
                    }
                    verifiedIdentityScope = dismissalScope
                    cardDismissed = defaults.bool(forKey: dismissalKey)
                }
            } catch DashboardTicketBridgeError.signInRequired { throw DashboardTicketBridgeError.signInRequired }
            catch DashboardTicketBridgeError.http(let status, let detail) where status == 401 || status == 403 {
                throw DashboardTicketBridgeError.http(status: status, detail: detail)
            } catch { /* Older servers can omit the identity probe; capability identity still fences data. */ }
            guard epoch == generation else { return }
            let rows = hub["plugins"] as? [[String: Any]] ?? []
            guard let plugin = rows.first(where: { $0["name"] as? String == "bot-coms" }) else {
                availability = .missing
                return
            }
            guard plugin["runtime_status"] as? String == "enabled" else {
                availability = .disabled
                return
            }
            do {
                let result = try await service.request(MessagingCapability.self, "/capabilities")
                guard epoch == generation else { return }
                if result.serverID.isEmpty || result.principalID.isEmpty {
                    availability = .needsConfiguration
                    return
                }
                if let old = capability, old.scope != result.scope {
                    conversations = []
                    generation = UUID()
                    isRefreshing = false
                }
                capability = result
                service.capability = result
                availability = result.apiVersion != 1 ? .needsUpdate : (result.isReady ? .ready : .needsConfiguration)
                error = nil
                if isReady { await refreshConversations() }
            } catch DashboardTicketBridgeError.http(let status, _) where status == 404 {
                if epoch == generation { availability = .needsConfiguration }
            }
        } catch {
            guard epoch == generation else { return }
            if case DashboardTicketBridgeError.http(let status, _) = error, status == 404 {
                availability = .legacy
            } else {
                handle(error)
            }
        }
    }

    func handle(_ failure: Error) {
        isRefreshing = false
        if case DashboardTicketBridgeError.signInRequired = failure {
            availability = .forbidden; capability = nil; conversations = []; generation = UUID()
        } else if case DashboardTicketBridgeError.http(let status, _) = failure, status == 401 || status == 403 {
            availability = .forbidden; capability = nil; conversations = []; generation = UUID()
        } else { availability = .unavailable }
        error = failure.localizedDescription
    }

    func refreshConversations() async {
        guard isReady, let service else { return }
        struct Page: Decodable { let conversations: [MessagingConversation]; let cursor: String? }
        let epoch = generation
        do {
            var collected: [MessagingConversation] = []
            var cursor: String?
            var seen = Set<String>()
            repeat {
                let path = try cursor.map { "/conversations?cursor=" + (try service.component($0)) } ?? "/conversations"
                let page = try await service.request(Page.self, path)
                guard epoch == generation else { return }
                collected.append(contentsOf: page.conversations)
                cursor = page.cursor
                if let cursor, !seen.insert(cursor).inserted { throw MessagingError.invalidResponse }
            } while cursor != nil
            conversations = collected
            error = nil
        } catch { if epoch == generation { handle(error) } }
    }

    func createGroup(name: String, members: [String], responder: String, requestID: String) async throws -> MessagingConversation {
        guard isReady, capability?.supportsGroups == true, let service else { throw MessagingError.unavailable }
        let epoch = generation
        let result = try await service.request(MessagingConversation.self, "/conversations", method: "POST", body: [
            "title": name, "profiles": members, "default_responder": responder, "client_request_id": requestID
        ])
        guard epoch == generation else { throw MessagingError.staleContext }
        await refreshConversations()
        return result
    }
}
