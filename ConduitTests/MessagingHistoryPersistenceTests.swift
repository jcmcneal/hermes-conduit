import XCTest
@testable import Conduit

@MainActor
final class MessagingHistoryPersistenceTests: XCTestCase {
    private var directories: [URL] = []
    private let dm = MessagingDestination(conversationID: nil, profileID: "bot")

    override func tearDown() async throws {
        for directory in directories { try? FileManager.default.removeItem(at: directory) }
        try await super.tearDown()
    }

    func testFreshCacheRestoresMessagesAndPaginationBeforeNetworkWithoutLiveRuns() async throws {
        let directory = makeDirectory()
        let first = cache(directory)
        await first.configure(partition: "saved-account-a")
        let requester = PersistedHistoryRequester()
        let loaded = try await first.load(dm, current: nil, older: false, service: MessagingService(requester: requester))
        XCTAssertEqual(loaded.runs.count, 1)
        await first.flushPersistence()

        let restarted = cache(directory)
        await restarted.configure(partition: "saved-account-a")
        let restored = try XCTUnwrap(restarted.snapshot(for: dm))
        XCTAssertEqual(restored.messages, loaded.messages)
        XCTAssertEqual(restored.before, loaded.before)
        XCTAssertTrue(restored.runs.isEmpty, "Restored history cannot claim a run is still active")
        XCTAssertEqual(requester.requests, 1, "Cold display restoration must not require another server request")
        let data = try Data(contentsOf: directory.appendingPathComponent("snapshots-v1.json"))
        XCTAssertFalse(String(decoding: data, as: UTF8.self).contains("saved-account-a"), "Disk partition names are hashed")
    }

    func testResetFlushesPendingSnapshotButRetainsItForTheNextInstance() async {
        let directory = makeDirectory()
        let first = cache(directory)
        await first.configure(partition: "account")
        first.accept(receipt(1), for: dm, current: nil)
        first.reset()
        XCTAssertNil(first.snapshot(for: dm))
        let restarted = cache(directory)
        await restarted.configure(partition: "account")
        XCTAssertEqual(restarted.snapshot(for: dm)?.messages.map(\.sequence), [1])
    }

    func testCacheDeallocationEnqueuesPendingMessagesForTheNextInstance() async {
        let directory = makeDirectory()
        var first: MessagingHistoryCache? = cache(directory)
        await first?.configure(partition: "account")
        first?.accept(receipt(1), for: dm, current: nil)
        first = nil
        let restarted = cache(directory)
        await restarted.configure(partition: "account")
        XCTAssertEqual(restarted.snapshot(for: dm)?.messages.map(\.sequence), [1])
    }

    func testPartitionSwitchAndSignOutPurgeDoNotExposeOrDeleteAnotherAccount() async {
        let directory = makeDirectory()
        let first = cache(directory)
        await first.configure(partition: "alice")
        first.accept(receipt(1), for: dm, current: nil)
        await first.configure(partition: "bob")
        XCTAssertNil(first.snapshot(for: dm))
        first.accept(receipt(2), for: dm, current: nil)
        await first.configure(partition: "alice")
        XCTAssertEqual(first.snapshot(for: dm)?.messages.map(\.sequence), [1])
        first.purge()
        await first.flushPersistence()

        let restarted = cache(directory)
        await restarted.configure(partition: "alice")
        XCTAssertNil(restarted.snapshot(for: dm))
        await restarted.configure(partition: "bob")
        XCTAssertEqual(restarted.snapshot(for: dm)?.messages.map(\.sequence), [2])
    }

    func testDeletionIsDurableWithoutWaitingForTheCoalescingDelay() async {
        let directory = makeDirectory()
        let first = cache(directory)
        await first.configure(partition: "account")
        first.accept(receipt(1), for: dm, current: nil)
        await first.flushPersistence()
        first.invalidate(dm, removeSnapshot: true)
        let restarted = cache(directory)
        await restarted.configure(partition: "account")
        XCTAssertNil(restarted.snapshot(for: dm))
    }

    func testPurgeCancelsPendingWritesAndCannotResurrectSignedOutMessages() async {
        let directory = makeDirectory()
        let first = cache(directory)
        await first.configure(partition: "account")
        first.accept(receipt(1), for: dm, current: nil)
        await first.flushPersistence()
        first.accept(receipt(2), for: dm, current: first.snapshot(for: dm))
        first.purge()
        await first.flushPersistence()
        let restarted = cache(directory)
        await restarted.configure(partition: "account")
        XCTAssertNil(restarted.snapshot(for: dm))
    }

    func testExpiredAndCorruptFilesDoNotRestoreSnapshots() async throws {
        let directory = makeDirectory()
        let first = cache(directory)
        await first.configure(partition: "account")
        first.accept(receipt(1), for: dm, current: nil)
        await first.flushPersistence()
        let expired = MessagingHistoryCache(persistenceDirectory: directory, persistenceTTL: 0)
        await expired.configure(partition: "account")
        XCTAssertNil(expired.snapshot(for: dm))
        let file = directory.appendingPathComponent("snapshots-v1.json")
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
        try Data("corrupt snapshot".utf8).write(to: file)
        let corrupt = cache(directory)
        await corrupt.configure(partition: "account")
        XCTAssertNil(corrupt.snapshot(for: dm))
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
    }

    func testConversationAndEncodedByteBoundsApplyAcrossDiskPartitions() async throws {
        let directory = makeDirectory()
        let first = MessagingHistoryCache(maxConversations: 2, maxBytes: 4_096,
                                          persistenceDirectory: directory, persistenceDelay: .seconds(60))
        for index in 1...3 {
            await first.configure(partition: "account-\(index)")
            first.accept(receipt(index), for: dm, current: nil)
            await first.flushPersistence()
        }
        let restarted = MessagingHistoryCache(maxConversations: 2, maxBytes: 4_096, persistenceDirectory: directory)
        await restarted.configure(partition: "account-1")
        XCTAssertNil(restarted.snapshot(for: dm))
        await restarted.configure(partition: "account-3")
        XCTAssertEqual(restarted.snapshot(for: dm)?.messages.map(\.sequence), [3])
        let data = try Data(contentsOf: directory.appendingPathComponent("snapshots-v1.json"))
        XCTAssertLessThanOrEqual(data.count, 4_096)
    }

    func testOversizedHistoryIsNotRetainedOnDisk() async {
        let directory = makeDirectory()
        let first = MessagingHistoryCache(maxBytes: 1_024, persistenceDirectory: directory)
        await first.configure(partition: "account")
        first.accept(receipt(1, body: String(repeating: "x", count: 4_096)), for: dm, current: nil)
        await first.flushPersistence()
        let restarted = MessagingHistoryCache(maxBytes: 1_024, persistenceDirectory: directory)
        await restarted.configure(partition: "account")
        XCTAssertNil(restarted.snapshot(for: dm))
    }

    func testUnconfiguredCacheDoesNotWriteMessagesToDisk() async {
        let directory = makeDirectory()
        let first = cache(directory)
        first.accept(receipt(1), for: dm, current: nil)
        await first.flushPersistence()
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent("snapshots-v1.json").path))
    }

    private func cache(_ directory: URL) -> MessagingHistoryCache {
        MessagingHistoryCache(persistenceDirectory: directory, persistenceDelay: .seconds(60))
    }

    private func makeDirectory() -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("MessagingHistoryPersistenceTests-" + UUID().uuidString)
        directories.append(directory)
        return directory
    }

    private func receipt(_ sequence: Int, body: String = "saved message") -> MessagingSendReceipt {
        MessagingSendReceipt(conversation: MessagingConversation(id: "dm", kind: "dm", title: "Bot", profiles: ["bot"],
            defaultResponder: "bot", revision: 1, preview: body, updatedAt: 1, unread: 0, archived: false, pinned: false, muted: false),
            message: MessagingMessage(id: "m\(sequence)", sequence: sequence, author: "user", body: body, createdAt: 1))
    }
}

@MainActor
private final class PersistedHistoryRequester: DashboardJSONRequester {
    var requests = 0
    func requestJSON(path: String, method: String, body: [String: Any]?, timeoutMilliseconds: Int,
                     maxResponseBytes: Int) async throws -> [String: Any] {
        requests += 1
        return [
            "conversation": ["id": "dm", "kind": "dm", "title": "Bot", "profiles": ["bot"], "default_responder": "bot",
                             "revision": 1, "preview": "reply", "updated_at": 1, "unread": 0,
                             "archived": false, "pinned": false, "muted": false],
            "messages": [["id": "m4", "sequence": 4, "author": "user", "body": "question", "created_at": 1],
                         ["id": "m5", "sequence": 5, "author": "bot", "body": "reply", "created_at": 2]],
            "runs": [["id": "r", "profile": "bot", "status": "running", "detail": "active before restart"]],
            "before": 4,
        ]
    }
}
