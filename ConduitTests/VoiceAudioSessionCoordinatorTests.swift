//
//  VoiceAudioSessionCoordinatorTests.swift
//  ConduitTests
//
//  Deterministic ownership semantics for the audio-session coordinator.
//  These run against a mocked session seam — never the process-global
//  AVAudioSession — so they assert exactly which policy won, how often the
//  session was (de)activated, and that cleanup is idempotent.
//

import AVFAudio
import XCTest
@testable import Conduit

@MainActor
final class VoiceAudioSessionCoordinatorTests: XCTestCase {
    private var session: MockVoiceAudioSession!
    private var coordinator: VoiceAudioSessionCoordinator!

    override func setUp() {
        super.setUp()
        session = MockVoiceAudioSession()
        coordinator = VoiceAudioSessionCoordinator(session: session)
    }

    func testConversationCaptureActivatesConversationPolicy() throws {
        let lease = try coordinator.acquire(.conversationCapture)

        XCTAssertEqual(session.categoryCalls.count, 1)
        XCTAssertEqual(session.categoryCalls.last?.category, .playAndRecord)
        XCTAssertEqual(session.categoryCalls.last?.mode, .voiceChat)
        XCTAssertTrue(session.categoryCalls.last?.options.contains(.allowBluetoothHFP) ?? false)
        XCTAssertEqual(coordinator.appliedPolicy, .conversation)
        XCTAssertEqual(session.activationCount, 1)
        _ = lease
    }

    func testConversationPlaybackJoinsCaptureWithoutReconfiguring() throws {
        _ = try coordinator.acquire(.conversationCapture)
        session.resetRecordings()

        _ = try coordinator.acquire(.conversationPlayback)

        XCTAssertEqual(session.categoryCalls.count, 0, "conversation playback must join the capture-owned session")
        XCTAssertEqual(session.activationCount, 0)
        XCTAssertEqual(coordinator.appliedPolicy, .conversation)
    }

    func testPlaybackReleaseKeepsCaptureOwnedSessionActive() throws {
        let captureLease = try coordinator.acquire(.conversationCapture)
        let playbackLease = try coordinator.acquire(.conversationPlayback)

        coordinator.release(playbackLease)

        XCTAssertEqual(session.deactivationCount, 0, "playback release must not deactivate while capture owns the session")
        XCTAssertEqual(coordinator.appliedPolicy, .conversation)
        _ = captureLease
    }

    func testLastConversationOwnerDeactivatesWithNotifyOthers() throws {
        let captureLease = try coordinator.acquire(.conversationCapture)
        let playbackLease = try coordinator.acquire(.conversationPlayback)

        coordinator.release(playbackLease)
        coordinator.release(captureLease)

        XCTAssertEqual(session.deactivationCount, 1, "the session deactivates exactly once when the last owner releases")
        XCTAssertEqual(session.lastDeactivationOptions, .notifyOthersOnDeactivation)
        XCTAssertNil(coordinator.appliedPolicy)
    }

    func testConversationPlaybackWithoutCaptureKeepsConversationPolicy() throws {
        // A voice conversation whose microphone is paused can still be
        // speaking: the route must not churn mid-playback, so conversation
        // playback alone keeps the conversation policy.
        _ = try coordinator.acquire(.conversationPlayback)

        XCTAssertEqual(coordinator.appliedPolicy, .conversation)
        XCTAssertEqual(session.categoryCalls.last?.category, .playAndRecord)
    }

    func testStandalonePlaybackUsesOutputOnlyPolicy() throws {
        _ = try coordinator.acquire(.standalonePlayback)

        XCTAssertEqual(session.categoryCalls.last?.category, .playback)
        XCTAssertTrue(session.categoryCalls.last?.options.contains(.mixWithOthers) ?? false)
        XCTAssertTrue(session.categoryCalls.last?.options.contains(.duckOthers) ?? false)
        XCTAssertEqual(session.categoryCalls.last?.mode, .default)
        XCTAssertEqual(coordinator.appliedPolicy, .standalonePlayback)
        XCTAssertEqual(session.activationCount, 1)
    }

    func testStandaloneReleaseDeactivatesImmediately() throws {
        let lease = try coordinator.acquire(.standalonePlayback)

        coordinator.release(lease)

        XCTAssertEqual(session.deactivationCount, 1)
        XCTAssertEqual(session.lastDeactivationOptions, .notifyOthersOnDeactivation)
        XCTAssertNil(coordinator.appliedPolicy)
    }

    func testPolicySwitchDeactivatesThenAppliesNewPolicy() throws {
        let conversationLease = try coordinator.acquire(.conversationPlayback)
        coordinator.release(conversationLease)
        session.resetRecordings()

        _ = try coordinator.acquire(.standalonePlayback)

        XCTAssertEqual(session.categoryCalls.last?.category, .playback)
        XCTAssertEqual(session.activationCount, 1)
    }

    func testReleaseIsIdempotentAndCannotUnderflow() throws {
        let lease = try coordinator.acquire(.standalonePlayback)
        coordinator.release(lease)
        session.resetRecordings()

        coordinator.release(lease)

        XCTAssertEqual(session.deactivationCount, 0, "releasing an already-released lease must be a no-op")
        XCTAssertNil(coordinator.appliedPolicy)
    }

    func testUnknownLeaseReleaseIsNoOp() {
        coordinator.release(VoiceAudioLease(id: UUID()))

        XCTAssertEqual(session.deactivationCount, 0)
    }

    func testAcquireFailureDoesNotLeakOwnership() throws {
        session.categoryError = VoiceAudioSessionMockError.configurationFailed

        XCTAssertThrowsError(try coordinator.acquire(.conversationCapture))
        XCTAssertNil(coordinator.appliedPolicy)

        session.categoryError = nil
        let lease = try coordinator.acquire(.conversationCapture)

        XCTAssertEqual(session.activationCount, 1)
        coordinator.release(lease)
        XCTAssertEqual(session.deactivationCount, 1)
    }

    func testEngineStartFailureAfterAcquireReleasesOwnership() throws {
        // Models the playback service path: acquire succeeds, engine start
        // fails, the service must release so the session can deactivate.
        let lease = try coordinator.acquire(.standalonePlayback)
        coordinator.release(lease)

        XCTAssertNil(coordinator.appliedPolicy)
        XCTAssertEqual(session.deactivationCount, 1)
    }

    func testDeactivationFailureDoesNotCrashAndIsRetriedOnNextTransition() throws {
        let lease = try coordinator.acquire(.standalonePlayback)
        session.deactivateError = VoiceAudioSessionMockError.deactivationFailed

        coordinator.release(lease)

        // The failed deactivation must not crash or misreport the session as
        // inactive while the system session is actually still applied.
        XCTAssertEqual(session.deactivationCount, 1)
        XCTAssertEqual(coordinator.appliedPolicy, .standalonePlayback)

        // The next ownership transition retries the deactivation instead of
        // assuming the session went inactive.
        session.deactivateError = nil
        let retryLease = try coordinator.acquire(.standalonePlayback)
        coordinator.release(retryLease)

        XCTAssertEqual(session.deactivationCount, 2)
        XCTAssertEqual(session.lastDeactivationOptions, .notifyOthersOnDeactivation)
        XCTAssertNil(coordinator.appliedPolicy)
    }

    func testReassertReappliesPolicyForLiveOwners() throws {
        _ = try coordinator.acquire(.conversationCapture)
        session.resetRecordings()

        try coordinator.reassert()

        XCTAssertEqual(session.categoryCalls.count, 1, "reassert must reconfigure a live owner's session")
        XCTAssertEqual(session.activationCount, 1)
        XCTAssertEqual(coordinator.appliedPolicy, .conversation)
    }

    func testReassertWithoutOwnersDoesNothing() throws {
        try coordinator.reassert()

        XCTAssertEqual(session.categoryCalls.count, 0)
        XCTAssertEqual(session.activationCount, 0)
    }
}

@MainActor
private final class MockVoiceAudioSession: VoiceAudioSessionControlling {
    struct CategoryCall: Equatable {
        let category: AVAudioSession.Category
        let mode: AVAudioSession.Mode
        let options: AVAudioSession.CategoryOptions
    }

    private(set) var categoryCalls: [CategoryCall] = []
    private(set) var activationCalls: [(active: Bool, options: AVAudioSession.SetActiveOptions)] = []
    var categoryError: Error?
    var deactivateError: Error?

    var activationCount: Int { activationCalls.filter(\.active).count }
    var deactivationCount: Int { activationCalls.filter { !$0.active }.count }
    var lastDeactivationOptions: AVAudioSession.SetActiveOptions? {
        activationCalls.last(where: { !$0.active })?.options
    }

    func resetRecordings() {
        categoryCalls.removeAll()
        activationCalls.removeAll()
    }

    func setCategory(
        _ category: AVAudioSession.Category,
        mode: AVAudioSession.Mode,
        options: AVAudioSession.CategoryOptions
    ) throws {
        if let categoryError { throw categoryError }
        categoryCalls.append(CategoryCall(category: category, mode: mode, options: options))
    }

    func setActive(_ active: Bool, options: AVAudioSession.SetActiveOptions) throws {
        if !active, let deactivateError { throw deactivateError }
        activationCalls.append((active, options))
    }
}

private enum VoiceAudioSessionMockError: Error {
    case configurationFailed
    case deactivationFailed
}
