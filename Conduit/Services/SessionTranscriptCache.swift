import CryptoKit
import Foundation

/// Display snapshots only: a hit never establishes runtime freshness or skips
/// resume identity admission. Whole entries are evicted rather than trimming
/// rows, so a pagination window continues to describe its complete prefix.
@MainActor
final class SessionTranscriptCache {
    struct Snapshot: Codable {
        let identity: ConversationIdentity
        let messages: [ChatMessage]
        let window: PersistedTranscriptWindowState?
    }

    private struct Entry: Codable {
        let snapshot: Snapshot
        let textBytes: Int
        let savedAt: Date
        var access: UInt64
    }

    /// All members are value-only display records. The queue receives an
    /// immutable copy; it never reads or mutates the main-actor cache.
    private struct Store: Codable, @unchecked Sendable {
        var version = 1
        var entries: [Entry]
    }

    private struct Limits: Sendable {
        let sessions: Int
        let messages: Int
        let bytes: Int
        let partitions: Int
        let ttl: TimeInterval
    }

    // One queue also orders writes/deletions across replacement cache instances.
    private static let diskQueue = DispatchQueue(label: "conduit.session-transcript-cache", qos: .utility)
    private var entries: [Entry] = []
    private var clock: UInt64 = 0
    private let limits: Limits
    private let directory: URL
    private let now: () -> Date
    private var partition: String?
    private var configurationGeneration = UUID()
    private var mutationRevision: UInt64 = 0
    private var configurationTask: Task<Store, Never>?
    private var pendingWrite: DispatchWorkItem?

    init(maximumSessions: Int = 12, maximumMessages: Int = 6_000,
         maximumTextBytes: Int = 16 * 1_024 * 1_024,
         directory: URL? = nil, maximumPartitions: Int = 4,
         ttl: TimeInterval = 7 * 24 * 60 * 60,
         now: @escaping () -> Date = Date.init) {
        limits = Limits(sessions: max(0, maximumSessions), messages: max(0, maximumMessages),
                        bytes: max(0, maximumTextBytes), partitions: max(0, maximumPartitions), ttl: ttl)
        self.directory = directory ?? FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Conduit/SessionTranscripts/v1", isDirectory: true)
        self.now = now
    }

    /// No disk access occurs until the owner supplies a stable saved-account
    /// namespace. Await this before asking for a cold snapshot. Repeated calls
    /// share the pending read and do not reset already-loaded memory.
    func configure(partition requestedPartition: String?) async {
        let requested = requestedPartition.flatMap { $0.isEmpty ? nil : $0 }
        if partition == requested {
            if let task = configurationTask {
                let generation = configurationGeneration
                let revision = mutationRevision
                let restored = await task.value
                adopt(restored, generation: generation, revision: revision)
            }
            return
        }
        pendingWrite = nil // queued writes retain their outgoing namespace
        partition = requested
        entries = []
        clock = 0
        mutationRevision &+= 1
        let revision = mutationRevision
        let generation = UUID()
        configurationGeneration = generation
        configurationTask = nil
        guard let requested else { return }
        let url = Self.fileURL(partition: requested, directory: directory)
        let directory = directory
        let limits = limits
        let current = now()
        let task = Task<Store, Never> {
            await withCheckedContinuation { continuation in
                Self.diskQueue.async {
                    Self.pruneDirectory(directory, limits: limits, now: current)
                    continuation.resume(returning: Self.read(url, limits: limits, now: current))
                }
            }
        }
        configurationTask = task
        let restored = await task.value
        adopt(restored, generation: generation, revision: revision)
    }

    private func adopt(_ restored: Store, generation: UUID, revision: UInt64) {
        guard configurationGeneration == generation else { return }
        configurationTask = nil
        guard mutationRevision == revision else { return }
        entries = restored.entries
        clock = entries.map(\.access).max() ?? 0
    }

    /// For a transport/account handoff that must stop exposing memory without
    /// revoking the saved account. A later configure reloads its disk namespace.
    func clearMemory() {
        configurationGeneration = UUID()
        configurationTask = nil
        mutationRevision &+= 1
        entries = []
        clock = 0
        partition = nil
        pendingWrite = nil
    }

    func save(messages: [ChatMessage], window: PersistedTranscriptWindowState?,
              identity: ConversationIdentity) {
        guard identity.resumeTargetID != nil else { return }
        entries.removeAll { Self.matches($0.snapshot.identity, identity) }
        // Decision controls remain owned by the existing expiring presentation
        // cache and authoritative resume path, never an unvalidated disk hit.
        let settled = SessionPresentationCache.removingPendingDecisionPresentation(
            from: messages, matching: SessionPresentationCache.pendingDecisionKeys(in: messages)
        )
        let bytes = settled.reduce(0) { $0 + Self.textBytes(in: $1) }
        if !settled.isEmpty, limits.sessions > 0,
           settled.count <= limits.messages, bytes <= limits.bytes {
            var retainedWindow = window
            retainedWindow?.isLoadingEarlier = false
            clock &+= 1
            entries.append(Entry(snapshot: Snapshot(identity: identity, messages: settled, window: retainedWindow),
                                 textBytes: bytes, savedAt: now(), access: clock))
        }
        entries = Self.pruned(entries, limits: limits, now: now())
        persist()
    }

    func snapshot(for identity: ConversationIdentity) -> Snapshot? {
        entries = Self.pruned(entries, limits: limits, now: now())
        guard let index = entries.firstIndex(where: { Self.matches($0.snapshot.identity, identity) }) else { return nil }
        clock &+= 1
        entries[index].access = clock
        // Snapshot reads happen at navigation/restore boundaries, not per row.
        persist()
        return entries[index].snapshot
    }

    /// Cold startup already has a durable key from ChatResumeStore, but no
    /// freshly loaded catalog to rebuild its runtime aliases. Match that key
    /// directly against the admitted identity persisted with the snapshot.
    func snapshot(profile: String, sessionID: String) -> Snapshot? {
        guard let identity = entries.first(where: {
            $0.snapshot.identity.profile == profile
                && ($0.snapshot.identity.durableSessionID == sessionID
                    || ($0.snapshot.identity.durableSessionID == nil
                        && $0.snapshot.identity.runtimeSessionID == sessionID))
        })?.snapshot.identity else { return nil }
        return snapshot(for: identity)
    }

    func remove(sessionIDs: Set<String>, profile: String) {
        entries.removeAll {
            $0.snapshot.identity.profile == profile
                && !$0.snapshot.identity.acceptedSessionIDs.isDisjoint(with: sessionIDs)
        }
        persist()
    }

    /// Purges this account's disk snapshot as well as memory. The serialized
    /// delete runs after any in-progress write, so a late write cannot revive it.
    func removeAll() {
        entries = []
        persist()
    }

    /// Explicit sign-out can revoke all remembered accounts on this device.
    func removeAllPartitions() {
        configurationGeneration = UUID()
        configurationTask = nil
        mutationRevision &+= 1
        entries = []
        partition = nil
        pendingWrite?.cancel()
        pendingWrite = nil
        let directory = directory
        Self.diskQueue.async { try? FileManager.default.removeItem(at: directory) }
    }

    /// Waits for this process's queued atomic writes/deletions, useful at the
    /// background boundary and in tests. No synchronous disk I/O on MainActor.
    func flush() async {
        await withCheckedContinuation { continuation in
            Self.diskQueue.async { continuation.resume() }
        }
    }

    private func persist() {
        mutationRevision &+= 1
        guard let partition else { return }
        pendingWrite?.cancel()
        let store = Store(entries: entries)
        let directory = directory
        let url = Self.fileURL(partition: partition, directory: directory)
        let limits = limits
        let current = now()
        let work = DispatchWorkItem {
            Self.write(store, to: url, directory: directory, limits: limits, now: current)
        }
        pendingWrite = work
        Self.diskQueue.async(execute: work)
    }

    nonisolated private static func fileURL(partition: String, directory: URL) -> URL {
        let digest = SHA256.hash(data: Data(partition.utf8)).map { String(format: "%02x", $0) }.joined()
        return directory.appendingPathComponent(digest + ".json")
    }

    nonisolated private static func read(_ url: URL, limits: Limits, now: Date) -> Store {
        guard let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize else { return Store(entries: []) }
        guard size <= limits.bytes else {
            try? FileManager.default.removeItem(at: url)
            return Store(entries: [])
        }
        // A protected file may temporarily be unreadable before device unlock;
        // that is not evidence of corruption and must not revoke the snapshot.
        guard let data = try? Data(contentsOf: url) else { return Store(entries: []) }
        guard data.count <= limits.bytes,
              let store = try? JSONDecoder().decode(Store.self, from: data), store.version == 1 else {
            try? FileManager.default.removeItem(at: url)
            return Store(entries: [])
        }
        return Store(entries: pruned(store.entries, limits: limits, now: now))
    }

    nonisolated private static func write(_ value: Store, to url: URL, directory: URL, limits: Limits, now: Date) {
        var store = Store(entries: pruned(value.entries, limits: limits, now: now))
        do {
            // Serialized bytes, not only text estimates, bound disk usage.
            while !store.entries.isEmpty {
                let data = try JSONEncoder().encode(store)
                if data.count <= limits.bytes, limits.partitions > 0 {
                    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                    var excluded = directory
                    var values = URLResourceValues()
                    values.isExcludedFromBackup = true
                    try? excluded.setResourceValues(values)
                    #if os(iOS)
                    try data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
                    #else
                    try data.write(to: url, options: .atomic)
                    #endif
                    try? FileManager.default.setAttributes([.modificationDate: now], ofItemAtPath: url.path)
                    pruneDirectory(directory, limits: limits, now: now)
                    return
                }
                store.entries.remove(at: oldestIndex(store.entries))
            }
            try? FileManager.default.removeItem(at: url)
        } catch {
            // This is a disposable display cache. Disk/protection failures do
            // not replace the authoritative conversation with an error state.
        }
    }

    nonisolated private static func pruneDirectory(_ directory: URL, limits: Limits, now: Date) {
        let keys: Set<URLResourceKey> = [.fileSizeKey, .contentModificationDateKey]
        guard let urls = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: Array(keys)) else { return }
        var retained: [(url: URL, modified: Date)] = []
        for url in urls where url.pathExtension == "json" {
            guard let values = try? url.resourceValues(forKeys: keys),
                  let size = values.fileSize, size <= limits.bytes,
                  let modified = values.contentModificationDate,
                  now.timeIntervalSince(modified) < limits.ttl else {
                try? FileManager.default.removeItem(at: url)
                continue
            }
            retained.append((url, modified))
        }
        // Each retained file is byte-bounded, so partition count also bounds
        // global disk consumption (defaults: four files, at most 64 MiB).
        for value in retained.sorted(by: { $0.modified > $1.modified }).dropFirst(limits.partitions) {
            try? FileManager.default.removeItem(at: value.url)
        }
    }

    nonisolated private static func pruned(_ entries: [Entry], limits: Limits, now: Date) -> [Entry] {
        var result = entries.filter {
            let age = now.timeIntervalSince($0.savedAt)
            return age >= 0 && age < limits.ttl && !$0.snapshot.messages.isEmpty
                && $0.snapshot.identity.resumeTargetID != nil
                && $0.textBytes >= 0 && $0.textBytes <= limits.bytes
                && $0.snapshot.messages.count <= limits.messages
        }
        while !result.isEmpty && (result.count > limits.sessions
                || result.reduce(0, { $0 + $1.snapshot.messages.count }) > limits.messages
                || result.reduce(0, { $0 + $1.textBytes }) > limits.bytes) {
            result.remove(at: oldestIndex(result))
        }
        return result
    }

    nonisolated private static func oldestIndex(_ entries: [Entry]) -> Int {
        entries.indices.min(by: { entries[$0].access < entries[$1].access })!
    }

    nonisolated private static func matches(_ stored: ConversationIdentity, _ requested: ConversationIdentity) -> Bool {
        guard stored.profile == requested.profile else { return false }
        if stored.durableSessionID != nil || requested.durableSessionID != nil {
            return stored.durableSessionID != nil && stored.durableSessionID == requested.durableSessionID
        }
        return stored.runtimeSessionID != nil && stored.runtimeSessionID == requested.runtimeSessionID
    }

    nonisolated private static func textBytes(in message: ChatMessage) -> Int {
        let strings: [String?] = [message.id, message.content, message.rawContent,
                                 message.timestamp, message.author, message.reasoning, message.code,
                                 message.tool?.name, message.tool?.input, message.tool?.output,
                                 message.review?.summary]
        var count = strings.reduce(0) { $0 + ($1?.utf8.count ?? 0) }
        count += (message.review?.details ?? []).reduce(0) { $0 + $1.utf8.count }
        count += (message.attachments ?? []).reduce(0) { $0 + $1.uri.utf8.count + $1.name.utf8.count }
        if let clarify = message.clarify { count += (try? JSONEncoder().encode(clarify).count) ?? 0 }
        if let approval = message.approval { count += (try? JSONEncoder().encode(approval).count) ?? 0 }
        return count
    }
}
