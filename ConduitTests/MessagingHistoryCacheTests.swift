import Combine
import XCTest
@testable import Conduit

@MainActor
final class MessagingHistoryCacheTests: XCTestCase {
    private let dm = MessagingDestination(conversationID: nil, profileID: "swe-id")

    func testReopenRestoresHistoryBeforeRefreshAndIdenticalPollDoesNotPublish() async {
        let requester = CacheRequester { _, _, _ in self.history([1, 2]) }
        let owner = await owner(requester)
        let first = model(owner)
        await first.load()
        let reopened = model(owner)
        XCTAssertEqual(reopened.history?.messages.map(\.sequence), [1, 2])
        var changes = 0
        let subscription = reopened.objectWillChange.sink { changes += 1 }
        await reopened.load()
        await reopened.load()
        XCTAssertEqual(changes, 0, "An unchanged poll must not invalidate the entire conversation view")
        withExtendedLifetime(subscription) {}
    }

    func testConcurrentReadersShareOneRequestAndBothReceiveResult() async {
        let requester = CacheRequester { _, _, _ in
            try await Task.sleep(for: .milliseconds(30))
            return self.history([1])
        }
        let owner = await owner(requester)
        let first = model(owner), second = model(owner)
        async let a: Void = first.load()
        async let b: Void = second.load()
        _ = await (a, b)
        XCTAssertEqual(requester.historyRequests, 1)
        XCTAssertEqual(first.history?.messages, second.history?.messages)
        XCTAssertEqual(second.history?.messages.count, 1)
    }

    func testPaginationSurvivesLatestRefreshAndGapBackfill() async {
        var latest = 0
        let requester = CacheRequester { path, _, _ in
            let cursor = self.cursor(path)
            if cursor == 3 { return self.history([1, 2]) }
            if cursor == 7 { return self.history([4, 5, 6], before: 4) }
            latest += 1
            return latest == 1 ? self.history([3, 4], before: 3) : self.history([7, 8], before: 7)
        }
        let owner = await owner(requester)
        let reader = model(owner)
        await reader.load()
        await reader.load(older: true)
        await reader.load()
        XCTAssertEqual(reader.history?.messages.map(\.sequence), Array(1...8))
        XCTAssertNil(reader.history?.before)
        XCTAssertEqual(model(owner).history?.messages.count, 8)
    }

    func testEvictedSnapshotAndSecondReaderCannotDropOpenReadersPages() async throws {
        let requester = CacheRequester { path, _, _ in
            self.cursor(path) == 3 ? self.history([1, 2]) : self.history([3, 4], before: 3)
        }
        let owner = await owner(requester)
        let reader = model(owner)
        await reader.load()
        await reader.load(older: true)
        // More than the default 24 snapshots evicts this reader's warm entry.
        for index in 0..<25 {
            let destination = MessagingDestination(conversationID: "g-\(index)", profileID: nil)
            let conversation = decodedConversation(id: "g-\(index)", kind: "group")
            owner.historyCache.accept(MessagingSendReceipt(conversation: conversation, message: message(index + 1)),
                                      for: destination, current: nil)
        }
        XCTAssertNil(owner.historyCache.snapshot(for: dm))
        let second = model(owner)
        XCTAssertNil(second.history)
        await second.load()
        XCTAssertEqual(second.history?.messages.map(\.sequence), [3, 4])
        XCTAssertEqual(reader.history?.messages.map(\.sequence), [1, 2, 3, 4])
        XCTAssertNil(reader.history?.before)
    }

    func testAccountChangeClearsSnapshotsAndOldReaderRejectsNewAccountBroadcast() async {
        let requester = CacheRequester { _, _, _ in self.history([1]) }
        let owner = await owner(requester)
        let oldReader = model(owner)
        await oldReader.load()
        requester.principal = "bob"
        await owner.refresh()
        XCTAssertNil(oldReader.history)
        let newReader = model(owner)
        XCTAssertNil(newReader.history)
        await newReader.load()
        XCTAssertNotNil(newReader.history)
        XCTAssertNil(oldReader.history)
        XCTAssertFalse(oldReader.canWrite)
    }

    func testReceiptAppearsBeforeRefreshAndCancelledPollCannotOverwriteIt() async throws {
        var staleResponse: CheckedContinuation<[String: Any], Error>?
        let started = expectation(description: "stale poll started")
        let requester = CacheRequester { _, _, _ in
            try await withCheckedThrowingContinuation { continuation in
                staleResponse = continuation
                started.fulfill()
            }
        }
        let owner = await owner(requester)
        let reader = model(owner)
        let poll = Task { await reader.load() }
        await fulfillment(of: [started], timeout: 2)
        let receipt = MessagingSendReceipt(conversation: decodedConversation(), message: message(10))
        owner.historyCache.accept(receipt, for: dm, current: nil)
        XCTAssertEqual(reader.history?.messages.map(\.sequence), [10])
        staleResponse?.resume(returning: history([1]))
        await poll.value
        XCTAssertEqual(reader.history?.messages.map(\.sequence), [10])
        XCTAssertNil(reader.error)
    }

    func testFirstReceiptDoesNotPreventDiscoveringExistingOlderHistory() async throws {
        let requester = CacheRequester { _, _, _ in self.history([8, 9, 10], before: 8) }
        let owner = await owner(requester)
        let reader = model(owner)
        owner.historyCache.accept(MessagingSendReceipt(conversation: decodedConversation(), message: message(10)),
                                  for: dm, current: nil)
        await reader.load()
        XCTAssertEqual(reader.history?.messages.map(\.sequence), [8, 9, 10])
        XCTAssertEqual(reader.history?.before, 8)
    }

    func testDeleteInvalidationCannotBeResurrectedByOutstandingRead() async throws {
        var response: CheckedContinuation<[String: Any], Error>?
        let started = expectation(description: "poll started")
        let requester = CacheRequester { _, _, _ in
            try await withCheckedThrowingContinuation { continuation in response = continuation; started.fulfill() }
        }
        let owner = await owner(requester)
        let reader = model(owner)
        let task = Task { await reader.load() }
        await fulfillment(of: [started], timeout: 2)
        owner.historyCache.invalidate(dm, removeSnapshot: true)
        response?.resume(returning: history([1]))
        await task.value
        XCTAssertNil(reader.history)
        XCTAssertNil(owner.historyCache.snapshot(for: dm))
    }

    func testInvalidatedReadCannotApplyStaleAuthorizationFailure() async {
        var response: CheckedContinuation<[String: Any], Error>?
        let started = expectation(description: "poll started")
        let requester = CacheRequester { _, _, _ in
            try await withCheckedThrowingContinuation { continuation in response = continuation; started.fulfill() }
        }
        let owner = await owner(requester)
        let reader = model(owner)
        let task = Task { await reader.load() }
        await fulfillment(of: [started], timeout: 2)
        owner.historyCache.invalidate(dm)
        response?.resume(throwing: DashboardTicketBridgeError.http(status: 403, detail: "old request"))
        await task.value
        XCTAssertTrue(owner.isReady)
        XCTAssertNil(reader.error)
    }

    func testActiveRunsKeepFastPollingAfterAwaitingIndicatorClears() async {
        var status = "running"
        let requester = CacheRequester { _, _, _ in
            self.history([1], runs: [["id": "r", "profile": "swe-id", "status": status, "detail": ""]])
        }
        let owner = await owner(requester)
        let reader = model(owner)
        await reader.load()
        XCTAssertFalse(reader.prefersUrgentPolling)
        XCTAssertEqual(reader.historyPollInterval, .seconds(1))
        status = "completed"
        await reader.load()
        XCTAssertEqual(reader.historyPollInterval, .seconds(4))
    }

    func testByteBoundEvictsOversizeSnapshotWithoutDiscardingActiveResult() async throws {
        let cache = MessagingHistoryCache(maxConversations: 2, maxBytes: 32)
        var delivered: MessagingHistory?
        let subscription = cache.changes.sink { delivered = $0.history }
        cache.accept(MessagingSendReceipt(conversation: decodedConversation(), message: message(1)), for: dm, current: nil)
        XCTAssertNil(cache.snapshot(for: dm))
        XCTAssertEqual(delivered?.messages.count, 1)
        withExtendedLifetime(subscription) {}
    }

    private func owner(_ requester: CacheRequester) async -> MessagingStore {
        let owner = MessagingStore(defaults: UserDefaults(suiteName: UUID().uuidString)!)
        owner.connect(requester: requester, scope: "test")
        await owner.refresh()
        XCTAssertTrue(owner.isReady)
        return owner
    }

    private func model(_ owner: MessagingStore) -> MessagingConversationStore {
        MessagingConversationStore(destination: dm, owner: owner, defaults: UserDefaults(suiteName: UUID().uuidString)!)
    }

    private func cursor(_ path: String) -> Int? {
        URLComponents(string: path)?.queryItems?.first { $0.name == "before" }?.value.flatMap(Int.init)
    }

    private func message(_ sequence: Int) -> MessagingMessage {
        MessagingMessage(id: "m\(sequence)", sequence: sequence, author: "user", body: "Message \(sequence)", createdAt: 1)
    }

    private func decodedConversation(id: String = "dm", kind: String = "dm") -> MessagingConversation {
        MessagingConversation(id: id, kind: kind, title: "SWE", profiles: ["swe-id"], defaultResponder: "swe-id",
                              revision: 1, preview: "", updatedAt: 1, unread: 0, archived: false, pinned: false, muted: false)
    }

    private func history(_ sequences: [Int], before: Int? = nil, runs: [[String: Any]] = []) -> [String: Any] {
        var json: [String: Any] = [
            "conversation": ["id": "dm", "kind": "dm", "title": "SWE", "profiles": ["swe-id"],
                "default_responder": "swe-id", "revision": 1, "preview": "", "updated_at": 1,
                "unread": 0, "archived": false, "pinned": false, "muted": false],
            "messages": sequences.map { ["id": "m\($0)", "sequence": $0, "author": "user", "body": "Message \($0)", "created_at": 1] as [String: Any] },
            "runs": runs,
        ]
        if let before { json["before"] = before }
        return json
    }
}

@MainActor
private final class CacheRequester: DashboardJSONRequester {
    var principal = "alice"
    var historyRequests = 0
    let handler: (String, String, [String: Any]?) async throws -> [String: Any]
    init(_ handler: @escaping (String, String, [String: Any]?) async throws -> [String: Any]) { self.handler = handler }

    func requestJSON(path: String, method: String, body: [String: Any]?, timeoutMilliseconds: Int,
                     maxResponseBytes: Int) async throws -> [String: Any] {
        let base = String(path.split(separator: "?", maxSplits: 1)[0])
        if base.hasSuffix("/hub") { return ["plugins": [["name": "bot-coms", "runtime_status": "enabled"]]] }
        if base == "/api/auth/me" { return ["user_id": principal] }
        if base.hasSuffix("/capabilities") {
            return ["server_id": "test", "principal_id": principal, "api_version": 1, "state": "ready", "features": ["dm", "groups"],
                    "profiles": [["id": "swe-id", "name": "swe", "displayName": "SWE"]]]
        }
        if base.hasSuffix("/conversations"), method == "GET" { return ["conversations": []] }
        historyRequests += 1
        return try await handler(path, method, body)
    }
}
