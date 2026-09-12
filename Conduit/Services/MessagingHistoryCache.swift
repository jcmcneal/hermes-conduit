import Combine
import Foundation

/// A connection-owned query cache. The owner resets it whenever its verified identity changes.
/// Eviction only removes warm snapshots: an open reader keeps all of its loaded pages.
@MainActor
final class MessagingHistoryCache {
    let changes = PassthroughSubject<(key: String?, history: MessagingHistory?), Never>()
    private struct Entry {
        let history: MessagingHistory
        let cost: Int
        var access: UInt64
    }
    private struct RequestKey: Hashable {
        let destination: String
        let before: Int?
    }
    private struct Flight {
        let id: UUID
        let task: Task<MessagingHistory, Error>
    }
    private var entries: [String: Entry] = [:]
    private var flights: [RequestKey: Flight] = [:]
    private var access: UInt64 = 0
    private var epoch = UUID()
    private var revisions: [String: UUID] = [:]
    private let maxConversations: Int
    private let maxBytes: Int

    init(maxConversations: Int = 24, maxBytes: Int = 8_000_000) {
        self.maxConversations = maxConversations
        self.maxBytes = maxBytes
    }

    func snapshot(for destination: MessagingDestination) -> MessagingHistory? {
        guard var entry = entries[destination.id] else { return nil }
        access &+= 1
        entry.access = access
        entries[destination.id] = entry
        return entry.history
    }

    func reset() {
        epoch = UUID()
        flights.values.forEach { $0.task.cancel() }
        flights.removeAll()
        entries.removeAll()
        revisions.removeAll()
        changes.send((nil, nil))
    }

    /// Invalidate outstanding reads before a mutation refresh so a pre-mutation response cannot win.
    func invalidate(_ destination: MessagingDestination, removeSnapshot: Bool = false) {
        let key = destination.id
        revisions[key] = UUID()
        for request in flights.keys.filter({ $0.destination == key }) {
            flights.removeValue(forKey: request)?.task.cancel()
        }
        if removeSnapshot {
            entries.removeValue(forKey: key)
            changes.send((key, nil))
        }
    }

    func accept(_ receipt: MessagingSendReceipt, for destination: MessagingDestination, current: MessagingHistory?) {
        invalidate(destination)
        let previous = snapshot(for: destination) ?? current
        let incoming = MessagingHistory(conversation: receipt.conversation, messages: [receipt.message],
                                        runs: previous?.runs ?? [], before: previous?.before)
        publish(Self.merge(previous, incoming: incoming), for: destination)
    }

    func load(_ destination: MessagingDestination, current: MessagingHistory?, older: Bool,
              service: MessagingService) async throws -> MessagingHistory {
        let cached = snapshot(for: destination)
        // A reader may hold more pages than the bounded warm cache retains.
        let seed = cached.map { Self.merge(current, incoming: $0) } ?? current
        let cursor = older ? seed?.before : nil
        let key = RequestKey(destination: destination.id, before: cursor)
        if let flight = flights[key] { return try await flight.task.value }
        let requestEpoch = epoch
        let revision = revisions[destination.id]
        let id = UUID()
        let task = Task { @MainActor [self] in
            do {
                let result = try await service.history(destination, before: cursor)
                try validate(result, for: destination)
                try checkContext(requestEpoch, revision: revision, destination: destination)
                var incoming = result
                if !older, let last = seed?.messages.last {
                    var messages = result.messages
                    var before = result.before
                    while let first = messages.first, first.sequence > last.sequence + 1, let pageCursor = before {
                        let page = try await service.history(destination, before: pageCursor)
                        try checkContext(requestEpoch, revision: revision, destination: destination)
                        try validate(page, for: destination)
                        guard page.conversation.id == result.conversation.id, !page.messages.isEmpty,
                              page.before == nil || page.before! < pageCursor else { throw MessagingError.invalidResponse }
                        messages = page.messages + messages
                        before = page.before
                    }
                    incoming = MessagingHistory(conversation: result.conversation, messages: messages, runs: result.runs, before: before)
                }
                try checkContext(requestEpoch, revision: revision, destination: destination)
                let previous = snapshot(for: destination).map { Self.merge(seed, incoming: $0) } ?? seed
                // Pagination may finish after a newer latest-page poll. Keep the live metadata.
                let merged = Self.merge(previous, incoming: incoming, keepCurrentMetadata: older)
                publish(merged, for: destination)
                return merged
            } catch {
                // Superseded reads cannot publish auth failures from an older request either.
                try checkContext(requestEpoch, revision: revision, destination: destination)
                throw error
            }
        }
        flights[key] = Flight(id: id, task: task)
        defer { if flights[key]?.id == id { flights.removeValue(forKey: key) } }
        return try await task.value
    }

    private func checkContext(_ expected: UUID, revision: UUID?, destination: MessagingDestination) throws {
        try Task.checkCancellation()
        guard epoch == expected, revisions[destination.id] == revision else { throw MessagingError.staleContext }
    }

    private func validate(_ result: MessagingHistory, for destination: MessagingDestination) throws {
        if let expected = destination.conversationID, result.conversation.id != expected { throw MessagingError.invalidResponse }
        if let profile = destination.profileID,
           result.conversation.kind != "dm" || result.conversation.profiles != [profile] { throw MessagingError.invalidResponse }
    }

    static func equivalent(_ lhs: MessagingHistory?, _ rhs: MessagingHistory?) -> Bool {
        switch (lhs, rhs) {
        case (nil, nil): return true
        case let (lhs?, rhs?):
            return lhs.conversation == rhs.conversation && lhs.messages == rhs.messages
                && lhs.runs == rhs.runs && lhs.before == rhs.before
        default: return false
        }
    }

    static func merge(_ current: MessagingHistory?, incoming: MessagingHistory,
                              keepCurrentMetadata: Bool = false) -> MessagingHistory {
        guard let current else { return incoming }
        if equivalent(current, incoming) { return incoming }
        let messages = Dictionary((current.messages + incoming.messages).map { ($0.id, $0) },
                                  uniquingKeysWith: { _, new in new }).values.sorted { $0.sequence < $1.sequence }
        let retainsEarlierPage = (current.messages.first?.sequence ?? Int.max) < (incoming.messages.first?.sequence ?? Int.max)
        return MessagingHistory(conversation: keepCurrentMetadata ? current.conversation : incoming.conversation,
                                messages: messages, runs: keepCurrentMetadata ? current.runs : incoming.runs,
                                before: retainsEarlierPage ? current.before : incoming.before)
    }

    private func publish(_ history: MessagingHistory, for destination: MessagingDestination) {
        let changed = !Self.equivalent(entries[destination.id]?.history, history)
        access &+= 1
        // Account for payload plus approximate value/index overhead; never persist transcripts to disk.
        let conversation = history.conversation
        let metadataCost = [conversation.id, conversation.kind, conversation.title, conversation.defaultResponder,
                            conversation.preview].reduce(512) { $0 + $1.utf8.count }
            + conversation.profiles.reduce(0) { $0 + $1.utf8.count + 32 }
        let runsCost = history.runs.reduce(0) { $0 + $1.id.utf8.count + $1.profile.utf8.count
            + $1.status.utf8.count + $1.detail.utf8.count + 128 }
        let cost = history.messages.reduce(metadataCost + runsCost) {
            $0 + $1.body.utf8.count + $1.id.utf8.count + $1.author.utf8.count + 192
        }
        entries[destination.id] = Entry(history: history, cost: cost, access: access)
        var total = entries.values.reduce(0) { $0 + $1.cost }
        while entries.count > maxConversations || total > maxBytes {
            guard let oldest = entries.min(by: { $0.value.access < $1.value.access }) else { break }
            total -= oldest.value.cost
            entries.removeValue(forKey: oldest.key)
        }
        if changed { changes.send((destination.id, history)) }
    }
}
