import Foundation

/// An opaque cache namespace for one saved logical dashboard connection.
/// Tickets and cookies are transport credentials and deliberately do not enter
/// this identity. Callers revoke it at explicit sign-out/account replacement.
@MainActor
final class ConnectionCacheNamespaceStore {
    private struct Record: Codable {
        var version = 1
        let server: String
        let id: UUID
        var verifiedPrincipal: String?

        var namespace: String { "connection-v1-" + id.uuidString.lowercased() }
    }

    static let storageKey = "conduit.connection.cacheNamespace.v1"
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    /// Reuses the namespace across process launches and credential refreshes.
    /// Switching server/base path starts a new logical connection; returning
    /// to an older server cannot resurrect its retired namespace.
    func namespace(for baseURL: String) -> String? {
        guard let server = Self.normalizedServer(baseURL) else { return nil }
        if let current = load(), current.server == server { return current.namespace }
        return persist(Record(server: server, id: UUID()))
    }

    /// Use only when an explicit accepted login/repair can replace the account,
    /// never for automatic ticket/cookie renewal or restoring saved credentials.
    func replace(for baseURL: String) -> String? {
        guard let server = Self.normalizedServer(baseURL) else { return nil }
        return persist(Record(server: server, id: UUID()))
    }

    /// Binds the gateway's verified capability.scope to the logical connection.
    /// A changed server/principal identity retires all caches under the old key.
    /// The optional expected namespace fences replies crossing an explicit
    /// replacement even when the replacement uses the same server URL.
    func verify(principal: String, for baseURL: String, expectedNamespace: String? = nil) -> String? {
        guard !principal.isEmpty,
              let server = Self.normalizedServer(baseURL),
              var current = load(), current.server == server,
              expectedNamespace == nil || expectedNamespace == current.namespace else { return nil }
        if let previous = current.verifiedPrincipal, previous != principal {
            return persist(Record(server: server, id: UUID(), verifiedPrincipal: principal))
        }
        if current.verifiedPrincipal == nil {
            current.verifiedPrincipal = principal
            return persist(current)
        }
        return current.namespace
    }

    @discardableResult
    func revoke() -> String? {
        let retired = load()?.namespace
        defaults.removeObject(forKey: Self.storageKey)
        return retired
    }

    // Read on every operation: AppState and MessagingStore may hold distinct
    // instances backed by the same defaults. Neither may revive a stale key.
    private func load() -> Record? {
        guard let data = defaults.data(forKey: Self.storageKey) else { return nil }
        guard data.count <= 16_384,
              let record = try? JSONDecoder().decode(Record.self, from: data),
              record.version == 1,
              Self.normalizedServer(record.server) == record.server,
              record.verifiedPrincipal?.isEmpty != true else {
            defaults.removeObject(forKey: Self.storageKey)
            return nil
        }
        return record
    }

    private func persist(_ record: Record) -> String? {
        guard let data = try? JSONEncoder().encode(record), data.count <= 16_384 else { return nil }
        defaults.set(data, forKey: Self.storageKey)
        return record.namespace
    }

    private static func normalizedServer(_ baseURL: String) -> String? {
        guard let normalized = try? ConnectionURLPolicy.normalizedBaseURL(baseURL),
              var components = URLComponents(string: normalized),
              let scheme = components.scheme?.lowercased(),
              let host = components.host?.lowercased() else { return nil }
        components.scheme = scheme
        components.host = host
        if (scheme == "https" && components.port == 443) || (scheme == "http" && components.port == 80) {
            components.port = nil
        }
        return components.string
    }
}
