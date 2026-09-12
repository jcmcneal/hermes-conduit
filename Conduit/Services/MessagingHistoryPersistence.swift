import CryptoKit
import Foundation

/// Serial disk I/O keeps encoding and atomic replacement off the main actor, and orders
/// removals after previously submitted writes so sign-out cannot resurrect a snapshot.
final class MessagingHistoryPersistence: @unchecked Sendable {
    struct Record: Codable {
        let history: MessagingHistory
        let savedAt: Date
        let access: UInt64
    }
    private struct Store: Codable {
        var version = 1
        var partitions: [String: [String: Record]] = [:]
    }

    private static let queue = DispatchQueue(label: "conduit.messaging-history.persistence", qos: .utility)
    private let fileURL: URL
    private let ttl: TimeInterval
    private let maxConversations: Int
    private let maxBytes: Int

    init(directory: URL? = nil, ttl: TimeInterval, maxConversations: Int, maxBytes: Int) {
        let caches = directory ?? FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Conduit/MessagingHistory", isDirectory: true)
        fileURL = caches.appendingPathComponent("snapshots-v1.json")
        self.ttl = ttl
        self.maxConversations = maxConversations
        self.maxBytes = maxBytes
    }

    func load(partition: String) async -> [String: Record] {
        await withCheckedContinuation { continuation in
            Self.queue.async { [self] in
                let store = read()
                continuation.resume(returning: store.partitions[key(partition)] ?? [:])
            }
        }
    }

    /// Enqueue synchronously: a subsequent purge is guaranteed to run after this operation.
    func save(partition: String, records: [String: Record]) {
        Self.queue.async { [self] in
            var store = read()
            store.partitions[key(partition)] = records.isEmpty ? nil : records
            writeBounded(store)
        }
    }

    func purge(partition: String) {
        Self.queue.async { [self] in
            var store = read()
            store.partitions.removeValue(forKey: key(partition))
            writeBounded(store)
        }
    }

    func flush() async {
        await withCheckedContinuation { continuation in
            Self.queue.async { continuation.resume() }
        }
    }

    private func key(_ partition: String) -> String {
        SHA256.hash(data: Data(partition.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    private func read() -> Store {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: fileURL.path) else { return Store() }
        guard let size = attributes[.size] as? NSNumber, size.intValue <= maxBytes else {
            try? FileManager.default.removeItem(at: fileURL)
            return Store()
        }
        // Protected data may be temporarily unavailable before the first device unlock.
        // An I/O failure is not evidence that a valid cache should be erased.
        guard let data = try? Data(contentsOf: fileURL) else { return Store() }
        guard var store = try? JSONDecoder().decode(Store.self, from: data), store.version == 1 else {
            try? FileManager.default.removeItem(at: fileURL)
            return Store()
        }
        let now = Date()
        var removed = false
        for partition in Array(store.partitions.keys) {
            let before = store.partitions[partition] ?? [:]
            let fresh = before.filter { destination, record in
                let age = now.timeIntervalSince(record.savedAt)
                let validDestination: Bool
                if destination.hasPrefix("conversation:") {
                    validDestination = String(destination.dropFirst("conversation:".count)) == record.history.conversation.id
                } else if destination.hasPrefix("dm:") {
                    validDestination = record.history.conversation.kind == "dm"
                        && record.history.conversation.profiles == [String(destination.dropFirst("dm:".count))]
                } else { validDestination = false }
                return age >= 0 && age < ttl && validDestination
                    && Set(record.history.messages.map(\.id)).count == record.history.messages.count
            }
            if fresh.count != before.count { removed = true }
            store.partitions[partition] = fresh.isEmpty ? nil : fresh
        }
        if removed { writeBounded(store) }
        return store
    }

    private func writeBounded(_ value: Store) {
        var store = value
        while !store.partitions.isEmpty {
            guard let data = try? JSONEncoder().encode(store) else { return }
            let count = store.partitions.values.reduce(0) { $0 + $1.count }
            if count <= maxConversations, data.count <= maxBytes {
                do {
                    var directory = fileURL.deletingLastPathComponent()
                    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                    var values = URLResourceValues()
                    values.isExcludedFromBackup = true
                    try? directory.setResourceValues(values)
                    try data.write(to: fileURL, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
                } catch { /* Disk caching is optional; keep the live transcript available. */ }
                return
            }
            let candidates = store.partitions.flatMap { partition, records in
                records.map { (partition: partition, destination: $0.key, record: $0.value) }
            }
            guard let oldest = candidates.min(by: {
                if $0.record.savedAt != $1.record.savedAt { return $0.record.savedAt < $1.record.savedAt }
                return $0.record.access < $1.record.access
            }) else { break }
            store.partitions[oldest.partition]?.removeValue(forKey: oldest.destination)
            if store.partitions[oldest.partition]?.isEmpty == true { store.partitions.removeValue(forKey: oldest.partition) }
        }
        try? FileManager.default.removeItem(at: fileURL)
    }
}
