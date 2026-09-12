import Foundation

/// A small disk cache of display metadata, never messaging authority or conversation content.
/// Partition names are opaque digests supplied by the authenticated dashboard bridge.
@MainActor
final class MessagingCatalogCache {
    struct Snapshot: Codable, Equatable {
        let profiles: [MessagingProfile]
        let verifiedScope: String
        let savedAt: Date
        var conversations: [MessagingConversation]? = nil
    }
    private struct Store: Codable {
        var version = 1
        var partitions: [String: Snapshot] = [:]
    }

    static let storageKey = "conduit.messaging.displayCatalog.v1"
    private let defaults: UserDefaults
    private let now: () -> Date
    private let ttl: TimeInterval
    private let maxPartitions: Int
    private let maxBytes: Int

    init(defaults: UserDefaults = .standard, ttl: TimeInterval = 7 * 24 * 60 * 60,
         maxPartitions: Int = 4, maxBytes: Int = 256 * 1024, now: @escaping () -> Date = Date.init) {
        self.defaults = defaults
        self.ttl = ttl
        self.maxPartitions = maxPartitions
        self.maxBytes = maxBytes
        self.now = now
    }

    func snapshot(for partition: String) -> Snapshot? {
        load().partitions[partition]
    }

    func save(profiles: [MessagingProfile], verifiedScope: String, for partition: String, conversations: [MessagingConversation] = []) {
        guard !partition.isEmpty, !verifiedScope.isEmpty, valid(profiles) else { return }
        let snapshot = Snapshot(profiles: profiles, verifiedScope: verifiedScope, savedAt: now(), conversations: conversations)
        guard let entryData = try? JSONEncoder().encode(Store(partitions: [partition: snapshot])),
              entryData.count <= maxBytes else { return }
        var store = load()
        store.partitions[partition] = snapshot
        persist(store)
    }

    func remove(_ partition: String) {
        var store = load()
        guard store.partitions.removeValue(forKey: partition) != nil else { return }
        persist(store)
    }

    private func valid(_ profiles: [MessagingProfile]) -> Bool {
        !profiles.isEmpty && profiles.allSatisfy { !$0.id.isEmpty }
            && Set(profiles.map(\.id)).count == profiles.count
    }

    private func load() -> Store {
        guard let data = defaults.data(forKey: Self.storageKey) else { return Store() }
        guard data.count <= maxBytes, let store = try? JSONDecoder().decode(Store.self, from: data), store.version == 1 else {
            defaults.removeObject(forKey: Self.storageKey)
            return Store()
        }
        let current = now()
        let fresh = store.partitions.filter {
            !$0.key.isEmpty && !$0.value.verifiedScope.isEmpty && valid($0.value.profiles)
                && current.timeIntervalSince($0.value.savedAt) >= 0
                && current.timeIntervalSince($0.value.savedAt) < ttl
        }
        let result = Store(partitions: fresh)
        if fresh.count != store.partitions.count || fresh.count > maxPartitions { persist(result) }
        if fresh.count > maxPartitions {
            let newest = fresh.sorted { $0.value.savedAt > $1.value.savedAt }.prefix(max(0, maxPartitions))
            return Store(partitions: Dictionary(uniqueKeysWithValues: newest.map { ($0.key, $0.value) }))
        }
        return result
    }

    private func persist(_ value: Store) {
        var store = value
        while !store.partitions.isEmpty {
            guard let data = try? JSONEncoder().encode(store) else { return }
            if store.partitions.count <= maxPartitions, data.count <= maxBytes {
                defaults.set(data, forKey: Self.storageKey)
                return
            }
            guard let oldest = store.partitions.min(by: { $0.value.savedAt < $1.value.savedAt }) else { break }
            store.partitions.removeValue(forKey: oldest.key)
        }
        defaults.removeObject(forKey: Self.storageKey)
    }
}
