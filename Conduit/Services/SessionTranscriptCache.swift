import Foundation

/// A process-local, display-only transcript cache. A hit never establishes
/// runtime freshness or bypasses resume identity admission. Whole snapshots
/// are evicted instead of trimming rows: pagination coverage must continue to
/// describe the complete visible prefix that was loaded from the server.
@MainActor
final class SessionTranscriptCache {
    struct Snapshot {
        let identity: ConversationIdentity
        let messages: [ChatMessage]
        let window: PersistedTranscriptWindowState?
    }

    private struct Entry {
        let snapshot: Snapshot
        let textBytes: Int
        var access: UInt64
    }

    private var entries: [Entry] = []
    private var clock: UInt64 = 0
    private let maximumSessions: Int
    private let maximumMessages: Int
    private let maximumTextBytes: Int

    init(maximumSessions: Int = 12, maximumMessages: Int = 6_000,
         maximumTextBytes: Int = 16 * 1_024 * 1_024) {
        self.maximumSessions = maximumSessions
        self.maximumMessages = maximumMessages
        self.maximumTextBytes = maximumTextBytes
    }

    func save(messages: [ChatMessage], window: PersistedTranscriptWindowState?,
              identity: ConversationIdentity) {
        guard identity.resumeTargetID != nil else { return }
        entries.removeAll { Self.matches($0.snapshot.identity, identity) }
        // Decision controls remain owned by the existing expiring presentation
        // cache and authoritative resume path, never an unvalidated warm hit.
        let settled = SessionPresentationCache.removingPendingDecisionPresentation(
            from: messages, matching: SessionPresentationCache.pendingDecisionKeys(in: messages)
        )
        let bytes = settled.reduce(0) { $0 + Self.textBytes(in: $1) }
        guard !settled.isEmpty, maximumSessions > 0,
              settled.count <= maximumMessages, bytes <= maximumTextBytes else { return }
        var retainedWindow = window
        retainedWindow?.isLoadingEarlier = false
        clock &+= 1
        entries.append(Entry(snapshot: Snapshot(identity: identity, messages: settled,
                                                window: retainedWindow), textBytes: bytes, access: clock))
        while entries.count > maximumSessions
                || entries.reduce(0, { $0 + $1.snapshot.messages.count }) > maximumMessages
                || entries.reduce(0, { $0 + $1.textBytes }) > maximumTextBytes {
            guard let oldest = entries.indices.min(by: { entries[$0].access < entries[$1].access }) else { break }
            entries.remove(at: oldest)
        }
    }

    func snapshot(for identity: ConversationIdentity) -> Snapshot? {
        guard let index = entries.firstIndex(where: { Self.matches($0.snapshot.identity, identity) }) else {
            return nil
        }
        clock &+= 1
        entries[index].access = clock
        return entries[index].snapshot
    }

    func remove(sessionIDs: Set<String>, profile: String) {
        entries.removeAll {
            $0.snapshot.identity.profile == profile
                && !$0.snapshot.identity.acceptedSessionIDs.isDisjoint(with: sessionIDs)
        }
    }

    func removeAll() { entries.removeAll() }

    private static func matches(_ stored: ConversationIdentity, _ requested: ConversationIdentity) -> Bool {
        guard stored.profile == requested.profile else { return false }
        // A reused runtime alias cannot override contradictory durable IDs.
        if stored.durableSessionID != nil || requested.durableSessionID != nil {
            return stored.durableSessionID != nil && stored.durableSessionID == requested.durableSessionID
        }
        return stored.runtimeSessionID != nil && stored.runtimeSessionID == requested.runtimeSessionID
    }

    private static func textBytes(in message: ChatMessage) -> Int {
        let strings: [String?] = [message.id, message.content, message.rawContent,
                                 message.timestamp, message.author, message.reasoning, message.code,
                                 message.tool?.name, message.tool?.input, message.tool?.output,
                                 message.review?.summary]
        var count = strings.reduce(0) { $0 + ($1?.utf8.count ?? 0) }
        count += (message.review?.details ?? []).reduce(0) { $0 + $1.utf8.count }
        count += (message.attachments ?? []).reduce(0) { $0 + $1.uri.utf8.count + $1.name.utf8.count }
        // Completed decision metadata can also hold large user-facing text.
        if let clarify = message.clarify { count += (try? JSONEncoder().encode(clarify).count) ?? 0 }
        if let approval = message.approval { count += (try? JSONEncoder().encode(approval).count) ?? 0 }
        return count
    }
}
