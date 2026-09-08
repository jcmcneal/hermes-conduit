import Foundation
import SwiftUI

/// Compact shell presentation owner for the authenticated root.
///
/// Owns whether Inbox or Conversation is the compact destination, the current
/// conversation-open request, and list transient presentation state. It does
/// not own selected session identity, recovery, transport, or turn state —
/// those remain on `AppState`.
@MainActor
final class AppShellState: ObservableObject {
    enum CompactRoute: Equatable, Hashable {
        case inbox
        case conversation
    }

    struct ConversationOpenRequest: Equatable {
        let generation: UInt64
        let sessionID: String?
        let reason: Reason

        enum Reason: Equatable {
            case rowSelection
            case newConversation
            case notification
            case voice
            case branch
            case project
            case scheduled
            case resume
            case returnSurface
        }
    }

    @Published private(set) var compactRoute: CompactRoute = .inbox
    @Published var isConversationSearchActive = false
    @Published var conversationSearchText = ""
    @Published var isCreatingConversation = false

    private(set) var openRequestGeneration: UInt64 = 0
    private(set) var pendingOpen: ConversationOpenRequest?

    /// Transient list UI that must reset when the active profile changes.
    func resetListTransientState() {
        isConversationSearchActive = false
        conversationSearchText = ""
    }

    /// Begins an explicit conversation presentation. Returns the generation
    /// that must be admitted before the route may change.
    @discardableResult
    func beginConversationOpen(
        sessionID: String?,
        reason: ConversationOpenRequest.Reason
    ) -> UInt64 {
        openRequestGeneration &+= 1
        let request = ConversationOpenRequest(
            generation: openRequestGeneration,
            sessionID: sessionID,
            reason: reason
        )
        pendingOpen = request
        return request.generation
    }

    /// Admits a completed open against the current request. A superseded
    /// asynchronous open must not push an old destination.
    @discardableResult
    func admitConversationOpen(
        generation: UInt64,
        sessionID: String?
    ) -> Bool {
        guard let pending = pendingOpen, pending.generation == generation else {
            return false
        }
        if let expected = pending.sessionID, let sessionID,
           expected != sessionID {
            return false
        }
        pendingOpen = nil
        compactRoute = .conversation
        isCreatingConversation = false
        return true
    }

    /// Rejects a pending open without changing the current route.
    func rejectConversationOpen(generation: UInt64) {
        guard pendingOpen?.generation == generation else { return }
        pendingOpen = nil
        isCreatingConversation = false
    }

    func showInbox() {
        pendingOpen = nil
        isCreatingConversation = false
        compactRoute = .inbox
    }

    func showConversationWithoutOpenRequest() {
        // Persistent iPad already shows chat beside inbox; compact callers
        // that only need to reveal an already-selected conversation use this.
        compactRoute = .conversation
    }

    /// Prefer Inbox for return-surface presentation without inventing a
    /// second foreground observer. Persistent layouts consume without a push.
    static func shouldPresentInboxForReturnSurface(
        persistentSidebarActive: Bool,
        alreadyShowingInbox: Bool
    ) -> Bool {
        if persistentSidebarActive { return false }
        return !alreadyShowingInbox
    }
}
