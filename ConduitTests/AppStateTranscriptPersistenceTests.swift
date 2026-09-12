import SwiftUI
import XCTest
@testable import Conduit

@MainActor
final class AppStateTranscriptPersistenceTests: XCTestCase {
    func testColdConnectWithRenewedTicketShowsDiskTranscriptBeforeTransportAndRevalidates() async throws {
        let fixture = try fixture()
        let saved = SessionTranscriptCache(directory: fixture.directory)
        await saved.configure(partition: fixture.namespace)
        saved.save(messages: [message("remembered answer")], window: nil, identity: identity)
        await saved.flush()
        let cold = SessionTranscriptCache(directory: fixture.directory)
        let gate = ConnectGate()
        let reachedTransport = expectation(description: "connect reached suspended transport")
        var resumed = false
        let operations = ChatResumeLifecycleOperations(
            connectClient: { _ in
                reachedTransport.fulfill()
                await gate.wait()
            },
            loadCatalog: { _, _ in [self.session] },
            openSession: { _, _, _ in
                resumed = true
                return SessionResumeResult(sessionId: "runtime-a", storedSessionId: "stored-a",
                                           messages: [],
                                           snapshot: SessionRuntimeSnapshot(object: ["running": .bool(false)]))
            },
            persistedTranscript: { _, _ in
                .payload([
                    "session_id": "stored-a",
                    "messages": [["id": "message-a", "role": "assistant", "content": "authoritative answer",
                                  "timestamp": "2026-09-12T12:00:00Z"]],
                    "pagination": ["limit": 120, "offset": 0, "order": "latest", "returned": 1]
                ])
            },
            refreshContext: { _, _ in }, loadProfiles: {}, loadBusyInputMode: { _ in },
            loadProfileDisplayPreferences: {}, loadSlashCommands: {}
        )
        let app = state(fixture, cache: cold, operations: operations)
        let connect = Task {
            await app.connect(with: HermesConnection(baseUrl: fixture.server, ticket: "renewed-ticket"))
        }
        await fulfillment(of: [reachedTransport], timeout: 5)
        XCTAssertEqual(app.messages.map(\.content), ["remembered answer"])
        XCTAssertEqual(app.activeSessionId, "stored-a")
        XCTAssertEqual(app.turnState, .synchronizing)
        XCTAssertFalse(app.isConnected)
        XCTAssertFalse(resumed, "Cached text must appear before any authoritative resume response")
        gate.release()
        await connect.value
        XCTAssertTrue(resumed)
        XCTAssertEqual(app.messages.map(\.content), ["authoritative answer"])
        await cold.flush()
    }

    func testBackgroundFlushPersistsLastVisibleConversationWithoutNavigatingAway() async throws {
        let fixture = try fixture()
        let cache = SessionTranscriptCache(directory: fixture.directory)
        await cache.configure(partition: fixture.namespace)
        let app = state(fixture, cache: cache)
        app.connection = HermesConnection(baseUrl: fixture.server, ticket: "ticket")
        app.sessions = [session]
        XCTAssertTrue(app.applyChatResume(SessionResumeResult(
            sessionId: "runtime-a", storedSessionId: "stored-a", messages: [message("initial answer")],
            snapshot: SessionRuntimeSnapshot(object: ["running": .bool(false)]))))
        app.messages[0].content = "latest visible answer"
        _ = app.handleScenePhase(.background)
        await cache.flush()
        let restarted = SessionTranscriptCache(directory: fixture.directory)
        await restarted.configure(partition: fixture.namespace)
        XCTAssertEqual(restarted.snapshot(profile: "default", sessionID: "stored-a")?.messages.first?.content,
                       "latest visible answer")
        await restarted.flush()
    }

    private let identity = ConversationIdentity(profile: "default", durableSessionID: "stored-a",
                                                runtimeSessionID: "runtime-a", acceptedSessionIDs: ["stored-a", "runtime-a"])

    private var session: SessionSummary {
        SessionSummary(id: "stored-a", alternateIds: ["runtime-a"], title: "Conversation", model: "Hermes",
                       updatedLabel: "now", profile: "default", source: .chat, isActive: false,
                       isArchived: false, lineageRootId: nil)
    }

    private func message(_ content: String) -> ChatMessage {
        ChatMessage(id: "message-a", role: .assistant, content: content, timestamp: "2026-09-12T12:00:00Z")
    }

    private struct Fixture {
        let defaults: UserDefaults
        let directory: URL
        let coordinator: ChatResumeCoordinator
        let namespace: String
        let server: String
    }

    private func fixture() throws -> Fixture {
        let suite = "AppStateTranscriptPersistenceTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(suite)
        let server = "https://transcript-cache.invalid"
        addTeardownBlock {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: directory)
        }
        let store = ChatResumeStore(defaults: defaults)
        store.setBehavior(.continueWhereLeftOff)
        let coordinator = ChatResumeCoordinator(store: store)
        coordinator.rememberSessionID("stored-a", for: "default")
        let namespace = try XCTUnwrap(ConnectionCacheNamespaceStore(defaults: defaults).namespace(for: server))
        return Fixture(defaults: defaults, directory: directory, coordinator: coordinator,
                       namespace: namespace, server: server)
    }

    private func state(_ fixture: Fixture, cache: SessionTranscriptCache,
                       operations: ChatResumeLifecycleOperations = .live) -> AppState {
        AppState(defaults: fixture.defaults, chatResumeCoordinator: fixture.coordinator,
                 recoverySequence: ChatResumeRecoverySequence(), loadSavedConnection: false,
                 clearSessionPresentationCache: {}, chatResumeLifecycleOperations: operations,
                 sessionPresentationCache: SessionPresentationCache(defaults: fixture.defaults),
                 sessionTranscriptCache: cache)
    }

    private final class ConnectGate {
        private var continuation: CheckedContinuation<Void, Never>?
        private var released = false
        func wait() async {
            guard !released else { return }
            await withCheckedContinuation { continuation = $0 }
        }
        func release() {
            released = true
            continuation?.resume()
            continuation = nil
        }
    }
}
