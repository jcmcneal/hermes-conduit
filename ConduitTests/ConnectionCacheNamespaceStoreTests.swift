import XCTest
@testable import Conduit

@MainActor
final class ConnectionCacheNamespaceStoreTests: XCTestCase {
    private func defaults() throws -> UserDefaults {
        let suite = "ConnectionCacheNamespaceStoreTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        return defaults
    }

    func testFreshInstancesRestoreSameNamespaceWithoutAnyCredentialInputs() throws {
        let defaults = try defaults()
        let first = ConnectionCacheNamespaceStore(defaults: defaults)
        let namespace = try XCTUnwrap(first.namespace(for: "http://localhost:9119"))
        let afterRestart = ConnectionCacheNamespaceStore(defaults: defaults)
        XCTAssertEqual(afterRestart.namespace(for: "http://localhost:9119"), namespace)
        XCTAssertEqual(first.namespace(for: "http://localhost:9119"), namespace)
    }

    func testServerNormalizationPreservesConnectionWhilePathAndPortChangesRetireIt() throws {
        let store = ConnectionCacheNamespaceStore(defaults: try defaults())
        let initial = try XCTUnwrap(store.namespace(for: "HTTPS://DASHBOARD.EXAMPLE:443/"))
        XCTAssertEqual(store.namespace(for: "https://dashboard.example"), initial)
        let moved = try XCTUnwrap(store.namespace(for: "https://dashboard.example/hermes"))
        XCTAssertNotEqual(moved, initial)
        XCTAssertNotEqual(store.namespace(for: "https://dashboard.example:8443/hermes"), moved)
        XCTAssertNotEqual(store.namespace(for: "https://dashboard.example"), initial)
    }

    func testExplicitAccountReplacementIsImmediatelyVisibleToOtherStoreInstances() throws {
        let defaults = try defaults()
        let first = ConnectionCacheNamespaceStore(defaults: defaults)
        let second = ConnectionCacheNamespaceStore(defaults: defaults)
        let original = try XCTUnwrap(first.namespace(for: "https://dashboard.example"))
        let replacement = try XCTUnwrap(second.replace(for: "https://dashboard.example"))
        XCTAssertNotEqual(original, replacement)
        XCTAssertEqual(first.namespace(for: "https://dashboard.example"), replacement)
        XCTAssertNil(first.verify(principal: "old-principal", for: "https://dashboard.example", expectedNamespace: original))
    }

    func testVerifiedCapabilityPrincipalBindsThenRotatesOnAccountChange() throws {
        let store = ConnectionCacheNamespaceStore(defaults: try defaults())
        let original = try XCTUnwrap(store.namespace(for: "https://dashboard.example"))
        XCTAssertEqual(store.verify(principal: "server/alice", for: "https://dashboard.example"), original)
        XCTAssertEqual(store.verify(principal: "server/alice", for: "https://dashboard.example"), original)
        let changed = try XCTUnwrap(store.verify(principal: "server/bob", for: "https://dashboard.example", expectedNamespace: original))
        XCTAssertNotEqual(changed, original)
        XCTAssertEqual(store.verify(principal: "server/bob", for: "https://dashboard.example"), changed)
        XCTAssertNil(store.verify(principal: "server/alice", for: "https://dashboard.example", expectedNamespace: original))
    }

    func testVerifiedPrincipalPersistsAcrossFreshStoreInstances() throws {
        let defaults = try defaults()
        let first = ConnectionCacheNamespaceStore(defaults: defaults)
        let original = try XCTUnwrap(first.namespace(for: "https://dashboard.example"))
        _ = first.verify(principal: "server/alice", for: "https://dashboard.example")
        let afterRestart = ConnectionCacheNamespaceStore(defaults: defaults)
        XCTAssertEqual(afterRestart.verify(principal: "server/alice", for: "https://dashboard.example"), original)
        XCTAssertNotEqual(afterRestart.verify(principal: "server/bob", for: "https://dashboard.example"), original)
    }

    func testSignOutRevokesNamespaceAndStaleVerificationCannotRecreateIt() throws {
        let defaults = try defaults()
        let first = ConnectionCacheNamespaceStore(defaults: defaults)
        let other = ConnectionCacheNamespaceStore(defaults: defaults)
        let original = try XCTUnwrap(first.namespace(for: "https://dashboard.example"))
        XCTAssertEqual(other.revoke(), original)
        XCTAssertNil(defaults.data(forKey: ConnectionCacheNamespaceStore.storageKey))
        XCTAssertNil(first.verify(principal: "server/alice", for: "https://dashboard.example", expectedNamespace: original))
        XCTAssertNotEqual(first.namespace(for: "https://dashboard.example"), original)
    }

    func testForeignServerVerificationDoesNotReplaceCurrentConnection() throws {
        let store = ConnectionCacheNamespaceStore(defaults: try defaults())
        let current = try XCTUnwrap(store.namespace(for: "https://second.example"))
        XCTAssertNil(store.verify(principal: "server/alice", for: "https://first.example"))
        XCTAssertEqual(store.namespace(for: "https://second.example"), current)
    }

    func testMalformedStoredRecordIsNotTrusted() throws {
        let defaults = try defaults()
        defaults.set(Data("not a record".utf8), forKey: ConnectionCacheNamespaceStore.storageKey)
        let store = ConnectionCacheNamespaceStore(defaults: defaults)
        XCTAssertNil(store.verify(principal: "server/alice", for: "https://dashboard.example"))
        XCTAssertNil(defaults.data(forKey: ConnectionCacheNamespaceStore.storageKey))
        XCTAssertNotNil(store.namespace(for: "https://dashboard.example"))
    }

    func testInvalidServerAndEmptyPrincipalDoNotMutateNamespace() throws {
        let store = ConnectionCacheNamespaceStore(defaults: try defaults())
        let current = try XCTUnwrap(store.namespace(for: "https://dashboard.example"))
        XCTAssertNil(store.replace(for: "https://user:password@dashboard.example"))
        XCTAssertNil(store.namespace(for: "not a URL"))
        XCTAssertNil(store.verify(principal: "", for: "https://dashboard.example"))
        XCTAssertEqual(store.namespace(for: "https://dashboard.example"), current)
    }
}
