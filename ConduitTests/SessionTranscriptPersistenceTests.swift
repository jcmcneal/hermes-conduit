import XCTest
@testable import Conduit

@MainActor
final class SessionTranscriptPersistenceTests: XCTestCase {
    private func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("session-transcripts-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    private func identity(_ id: String, profile: String = "default") -> ConversationIdentity {
        ConversationIdentity(profile: profile, durableSessionID: id, runtimeSessionID: "runtime-\(id)",
                             acceptedSessionIDs: [id, "runtime-\(id)"])
    }

    private func message(_ id: String) -> ChatMessage {
        ChatMessage(id: id, role: .assistant, content: "Full answer \(id)", rawContent: "raw \(id)",
                    timestamp: "2026-09-12T12:00:00Z", author: "bot", reasoning: "Reasoning",
                    tool: ToolActivity(id: "tool", name: "read", input: "path", output: "contents", status: .complete),
                    attachments: [Attachment(id: "attachment", name: "photo", uri: "https://example.test/photo", mimeType: "image/png", kind: .image)])
    }

    func testFreshInstanceRestoresCompleteDisplaySnapshotAndPaginationBeforeNetwork() async throws {
        let directory = try directory()
        let first = SessionTranscriptCache(directory: directory)
        await first.configure(partition: "saved-alice")
        var window = PersistedTranscriptWindowState(
            requestedSessionID: "a", profile: "default", pageSize: 120,
            resolvedSessionID: "a", runtimeSessionID: "runtime-a", nextOffset: 240,
            canLoadEarlier: true, hasBackfilledPrefix: true)
        window.isLoadingEarlier = true
        first.save(messages: [message("a")], window: window, identity: identity("a"))
        await first.flush()
        let fresh = SessionTranscriptCache(directory: directory)
        await fresh.configure(partition: "saved-alice")
        let snapshot = try XCTUnwrap(fresh.snapshot(profile: "default", sessionID: "a"))
        XCTAssertEqual(snapshot.messages, [message("a")])
        XCTAssertEqual(snapshot.window?.nextOffset, 240)
        XCTAssertEqual(snapshot.window?.hasBackfilledPrefix, true)
        XCTAssertEqual(snapshot.window?.isLoadingEarlier, false)
        XCTAssertNil(fresh.snapshot(profile: "other", sessionID: "a"))
        await fresh.flush()
    }

    func testAccountSwitchIsolationAndClearMemoryPreserveSavedAccount() async throws {
        let directory = try directory()
        let cache = SessionTranscriptCache(directory: directory)
        await cache.configure(partition: "alice")
        cache.save(messages: [message("a")], window: nil, identity: identity("a"))
        await cache.configure(partition: "bob")
        XCTAssertNil(cache.snapshot(for: identity("a")))
        cache.save(messages: [message("b")], window: nil, identity: identity("b"))
        cache.clearMemory()
        XCTAssertNil(cache.snapshot(for: identity("b")))
        await cache.configure(partition: "alice")
        XCTAssertNotNil(cache.snapshot(for: identity("a")))
        XCTAssertNil(cache.snapshot(for: identity("b")))
        await cache.flush()
    }

    func testDeletionAndSignoutCannotBeRevivedByPreviouslyQueuedWrites() async throws {
        let directory = try directory()
        let cache = SessionTranscriptCache(directory: directory)
        await cache.configure(partition: "alice")
        cache.save(messages: [message("a")], window: nil, identity: identity("a"))
        cache.remove(sessionIDs: ["runtime-a"], profile: "default")
        await cache.flush()
        let fresh = SessionTranscriptCache(directory: directory)
        await fresh.configure(partition: "alice")
        XCTAssertNil(fresh.snapshot(for: identity("a")))
        cache.save(messages: [message("a")], window: nil, identity: identity("a"))
        cache.removeAll()
        await cache.flush()
        fresh.clearMemory()
        await fresh.configure(partition: "alice")
        XCTAssertNil(fresh.snapshot(for: identity("a")))
        cache.save(messages: [message("a")], window: nil, identity: identity("a"))
        await cache.configure(partition: "bob")
        cache.save(messages: [message("b")], window: nil, identity: identity("b"))
        cache.removeAllPartitions()
        await cache.flush()
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
    }

    func testPendingDecisionsAreNotPersistedAndCompletedDecisionsRemain() async throws {
        let directory = try directory()
        let cache = SessionTranscriptCache(directory: directory)
        await cache.configure(partition: "alice")
        let pending = ChatMessage(id: "pending", role: .approval, content: "", timestamp: "",
                                  approval: ApprovalActivity(sessionId: "a", command: "run", description: "Allow?",
                                                             choices: nil, allowPermanent: false, smartDenied: false,
                                                             status: .pending, choice: nil, error: nil))
        var completed = pending
        completed.approval?.status = .approved
        cache.save(messages: [message("a"), pending], window: nil, identity: identity("a"))
        cache.save(messages: [completed], window: nil, identity: identity("b"))
        await cache.flush()
        let fresh = SessionTranscriptCache(directory: directory)
        await fresh.configure(partition: "alice")
        XCTAssertEqual(fresh.snapshot(for: identity("a"))?.messages.map(\.id), ["a"])
        XCTAssertEqual(fresh.snapshot(for: identity("b"))?.messages.first?.approval?.status, .approved)
        await fresh.flush()
    }

    func testTTLAndLRUSurviveFreshInstanceAndDiskRemainsBounded() async throws {
        let directory = try directory()
        var now = Date()
        let cache = SessionTranscriptCache(maximumSessions: 2, maximumTextBytes: 4_096,
                                           directory: directory, maximumPartitions: 2, ttl: 60, now: { now })
        await cache.configure(partition: "alice")
        cache.save(messages: [message("a")], window: nil, identity: identity("a"))
        cache.save(messages: [message("b")], window: nil, identity: identity("b"))
        XCTAssertNotNil(cache.snapshot(for: identity("a")))
        cache.save(messages: [message("c")], window: nil, identity: identity("c"))
        await cache.flush()
        let fresh = SessionTranscriptCache(maximumSessions: 2, maximumTextBytes: 4_096,
                                           directory: directory, maximumPartitions: 2, ttl: 60, now: { now })
        await fresh.configure(partition: "alice")
        XCTAssertNotNil(fresh.snapshot(for: identity("a")))
        XCTAssertNil(fresh.snapshot(for: identity("b")))
        XCTAssertNotNil(fresh.snapshot(for: identity("c")))
        await fresh.flush()
        now = now.addingTimeInterval(61)
        fresh.clearMemory()
        await fresh.configure(partition: "alice")
        XCTAssertNil(fresh.snapshot(for: identity("a")))
        for partition in ["one", "two", "three"] {
            await fresh.configure(partition: partition)
            fresh.save(messages: [message(partition)], window: nil, identity: identity(partition))
        }
        await fresh.flush()
        let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.fileSizeKey])
        XCTAssertEqual(files.count, 2)
        for file in files { XCTAssertLessThanOrEqual(try file.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0, 4_096) }
    }

    func testMalformedOversizedDiskFilesAndUnconfiguredCacheStayEmpty() async throws {
        let directory = try directory()
        let cache = SessionTranscriptCache(maximumTextBytes: 2_048, directory: directory)
        cache.save(messages: [message("a")], window: nil, identity: identity("a"))
        await cache.flush()
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: directory.path).isEmpty)
        await cache.configure(partition: "alice")
        cache.save(messages: [message("a")], window: nil, identity: identity("a"))
        await cache.flush()
        let file = try XCTUnwrap(FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil).first)
        try Data("not-json".utf8).write(to: file, options: .atomic)
        cache.clearMemory()
        await cache.configure(partition: "alice")
        XCTAssertNil(cache.snapshot(for: identity("a")))
        cache.save(messages: [message("a")], window: nil, identity: identity("a"))
        await cache.flush()
        try Data(repeating: 120, count: 4_096).write(to: file, options: .atomic)
        cache.clearMemory()
        await cache.configure(partition: "alice")
        XCTAssertNil(cache.snapshot(for: identity("a")))
    }
}
