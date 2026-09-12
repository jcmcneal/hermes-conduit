import XCTest
@testable import Conduit

@MainActor
final class SessionTranscriptCacheTests: XCTestCase {
    func testReturningToSessionDisplaysCachedMessagesBeforeRefreshAndAdoptsServerChanges() async throws {
        var state: AppState!
        var calls: [String: Int] = [:]
        state = try makeState(openSession: { _, id, _ in
            calls[id, default: 0] += 1
            if id == "a", calls[id] == 2 {
                XCTAssertEqual(state.messages.map(\.content), ["a response 1"])
                XCTAssertEqual(state.activeSessionId, "a")
                XCTAssertTrue(state.activeChatScrollSessionIdentity.isReconciling)
            }
            return self.result(id, content: "\(id) response \(calls[id]!)")
        })
        let first = await state.openSession("a")
        let second = await state.openSession("b")
        let returned = await state.openSession("a")
        XCTAssertTrue(first && second && returned)
        XCTAssertEqual(calls, ["a": 2, "b": 1])
        XCTAssertEqual(state.messages.map(\.content), ["a response 2"])
    }

    func testChangedCredentialsClearWarmHistoryEvenOnSameServer() async throws {
        var state: AppState!
        var calls = 0
        state = try makeState(openSession: { _, id, _ in
            if id == "a" {
                calls += 1
                if calls == 2 { XCTAssertTrue(state.messages.isEmpty) }
            }
            return self.result(id, content: "private \(id)")
        })
        _ = await state.openSession("a")
        _ = await state.openSession("b")
        state.connection = HermesConnection(baseUrl: "https://one.example", ticket: "other-principal")
        _ = await state.openSession("a")
        XCTAssertEqual(calls, 2)
    }

    func testDeletionRevokesWarmSnapshotUnderAllAliases() async throws {
        var state: AppState!
        var calls = 0
        state = try makeState(openSession: { _, id, _ in
            if id == "a" {
                calls += 1
                if calls == 2 { XCTAssertTrue(state.messages.isEmpty) }
            }
            return self.result(id, content: id)
        })
        _ = await state.openSession("a")
        _ = await state.openSession("b")
        state.revokeDeletedConversationIdentity(sessionIDs: ["a"], profile: "default")
        _ = await state.openSession("a")
        XCTAssertEqual(calls, 2)
    }

    func testFailedRefreshKeepsPreviouslyAdmittedTextVisible() async throws {
        enum RefreshFailure: Error { case offline }
        var state: AppState!
        var calls = 0
        state = try makeState(openSession: { _, id, _ in
            if id == "a" {
                calls += 1
                if calls == 2 { throw RefreshFailure.offline }
            }
            return self.result(id, content: id)
        })
        _ = await state.openSession("a")
        _ = await state.openSession("b")
        let refreshed = await state.openSession("a")
        XCTAssertFalse(refreshed)
        XCTAssertEqual(state.messages.map(\.content), ["a"])
    }

    func testSnapshotPreservesBackfilledWindowButClearsInFlightRequest() {
        let cache = SessionTranscriptCache()
        var window = PersistedTranscriptWindowState(
            requestedSessionID: "stored-a", profile: "default", pageSize: 120,
            resolvedSessionID: "stored-a", runtimeSessionID: "runtime-a", nextOffset: 240,
            canLoadEarlier: true, hasBackfilledPrefix: true
        )
        window.isLoadingEarlier = true
        let rows = [message("older"), message("tail")]
        cache.save(messages: rows, window: window, identity: identity("stored-a", runtime: "runtime-a"))
        let hit = cache.snapshot(for: identity("stored-a", runtime: "runtime-new"))
        XCTAssertEqual(hit?.messages, rows)
        XCTAssertEqual(hit?.window?.nextOffset, 240)
        XCTAssertEqual(hit?.window?.hasBackfilledPrefix, true)
        XCTAssertEqual(hit?.window?.isLoadingEarlier, false)
    }

    func testWarmReopenPreservesOlderPagesThroughAuthoritativeTailRefresh() async throws {
        var state: AppState!
        var opens = 0
        state = try makeState(openSession: { _, id, _ in
            if id == "a" {
                opens += 1
                if opens == 2 {
                    XCTAssertEqual(state.messages.count, 240)
                    XCTAssertEqual(state.persistedTranscriptWindow?.hasBackfilledPrefix, true)
                    XCTAssertFalse(state.canLoadEarlierMessagesForActiveConversation)
                }
            }
            return SessionResumeResult(sessionId: id, storedSessionId: id, messages: [],
                                       snapshot: SessionRuntimeSnapshot(object: ["running": .bool(false)]))
        }, persistedTranscript: { id, _ in
            self.page(id, range: 120..<240, offset: 0)
        }, loadEarlierTranscriptPage: { id, _, offset in
            self.page(id, range: 0..<120, offset: offset)
        })
        let initialOpen = await state.openSession("a")
        XCTAssertTrue(initialOpen)
        XCTAssertTrue(state.canLoadEarlierMessagesForActiveConversation)
        let backfilled = await state.loadEarlierMessages()
        XCTAssertTrue(backfilled)
        XCTAssertEqual(state.messages.count, 240)
        _ = await state.openSession("b")
        let reopened = await state.openSession("a")
        XCTAssertTrue(reopened)
        XCTAssertEqual(state.messages.count, 240)
        XCTAssertEqual(state.messages.first?.content, "row 0")
        XCTAssertEqual(state.messages.last?.content, "row 239")
        XCTAssertEqual(state.persistedTranscriptWindow?.hasBackfilledPrefix, true)
    }

    func testDurableIdentityAndProfileWinOverReusedRuntimeAlias() {
        let cache = SessionTranscriptCache()
        cache.save(messages: [message("private")], window: nil,
                   identity: identity("a", runtime: "runtime-shared"))
        XCTAssertNil(cache.snapshot(for: identity("b", runtime: "runtime-shared")))
        XCTAssertNil(cache.snapshot(for: identity("a", profile: "other", runtime: "runtime-shared")))
        XCTAssertNotNil(cache.snapshot(for: identity("a", runtime: "runtime-new")))
    }

    func testLeastRecentlyUsedEvictionAndOversizedSnapshotNeverTruncatePagination() {
        let cache = SessionTranscriptCache(maximumSessions: 2, maximumMessages: 3, maximumTextBytes: 1_024)
        cache.save(messages: [message("a")], window: nil, identity: identity("a"))
        cache.save(messages: [message("b")], window: nil, identity: identity("b"))
        XCTAssertNotNil(cache.snapshot(for: identity("a")))
        cache.save(messages: [message("c")], window: nil, identity: identity("c"))
        XCTAssertNil(cache.snapshot(for: identity("b")))
        XCTAssertNotNil(cache.snapshot(for: identity("a")))
        cache.save(messages: (0..<4).map { message("row-\($0)") }, window: nil, identity: identity("a"))
        XCTAssertNil(cache.snapshot(for: identity("a")), "An oversized replacement must also revoke the older snapshot")
        cache.save(messages: [message(String(repeating: "x", count: 2_048))], window: nil, identity: identity("large"))
        XCTAssertNil(cache.snapshot(for: identity("large")))
    }

    func testWarmCacheDoesNotRearmPendingDecisionCards() {
        let cache = SessionTranscriptCache()
        let pending = ChatMessage(id: "approval", role: .approval, content: "", timestamp: "",
                                  approval: ApprovalActivity(sessionId: "a", command: "run", description: "Allow?",
                                                             choices: nil, allowPermanent: false, smartDenied: false,
                                                             status: .pending, choice: nil, error: nil))
        cache.save(messages: [message("text"), pending], window: nil, identity: identity("a"))
        XCTAssertEqual(cache.snapshot(for: identity("a"))?.messages.map(\.id), ["text"])
    }

    private func identity(_ id: String, profile: String = "default", runtime: String? = nil) -> ConversationIdentity {
        ConversationIdentity(profile: profile, durableSessionID: id, runtimeSessionID: runtime,
                             acceptedSessionIDs: Set([id, runtime].compactMap { $0 }))
    }

    private func message(_ text: String) -> ChatMessage {
        ChatMessage(id: text, role: .assistant, content: text, timestamp: "2026-09-12T10:00:00Z")
    }

    private func result(_ id: String, content: String) -> SessionResumeResult {
        SessionResumeResult(sessionId: id, storedSessionId: id, messages: [message(content)],
                            snapshot: SessionRuntimeSnapshot(object: ["running": .bool(false)]))
    }

    private func makeState(
        openSession: @escaping @MainActor (HermesClient, String, Bool) async throws -> SessionResumeResult,
        persistedTranscript: (@MainActor (String, String) async -> PersistedTranscriptFetchOutcome)? = nil,
        loadEarlierTranscriptPage: (@MainActor (String, String, Int) async -> PersistedTranscriptFetchOutcome)? = nil
    ) throws -> AppState {
        let suite = "SessionTranscriptCacheTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        let state = AppState(
            defaults: defaults,
            chatResumeCoordinator: ChatResumeCoordinator(store: ChatResumeStore(defaults: defaults)),
            recoverySequence: ChatResumeRecoverySequence(), loadSavedConnection: false,
            clearSessionPresentationCache: {},
            chatResumeLifecycleOperations: ChatResumeLifecycleOperations(
                openSession: openSession, persistedTranscript: persistedTranscript,
                loadEarlierTranscriptPage: loadEarlierTranscriptPage, refreshContext: { _, _ in }
            ),
            sessionPresentationCache: SessionPresentationCache(defaults: defaults)
        )
        let connection = HermesConnection(baseUrl: "https://one.example", ticket: "ticket")
        state.connection = connection
        state.client = HermesClient(connection: connection, profile: "default")
        state.sessions = ["a", "b"].map {
            SessionSummary(id: $0, alternateIds: [], title: $0, model: "Hermes", updatedLabel: "now",
                           profile: "default", source: .chat, isActive: false, isArchived: false, lineageRootId: nil)
        }
        return state
    }

    private func page(_ id: String, range: Range<Int>, offset: Int) -> PersistedTranscriptFetchOutcome {
        .payload([
            "session_id": id,
            "messages": range.map { row in
                ["id": row + 1, "role": "assistant", "content": "row \(row)",
                 "timestamp": "2026-09-12T10:00:00Z"] as [String: Any]
            },
            "pagination": ["limit": 120, "offset": offset, "order": "latest", "returned": range.count]
        ])
    }
}
