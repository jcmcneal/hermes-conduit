//
//  HapticsVoiceIsolationTests.swift
//  ConduitTests
//
//  Pins that ordinary response haptics never interact with the voice audio
//  session: no acquisition, no policy change, no activation or deactivation.
//  VoiceAudioSessionCoordinator stays the sole authority over the shared
//  session (PR #141); response haptics must not couple to it (issue #140).
//

import AVFAudio
import XCTest
@testable import Conduit

@MainActor
final class HapticsVoiceIsolationTests: XCTestCase {
    private var session: RecordingVoiceAudioSession!
    private var coordinator: VoiceAudioSessionCoordinator!

    override func setUp() {
        super.setUp()
        Haptics.resetCoreHapticsStateForTesting()
        session = RecordingVoiceAudioSession()
        coordinator = VoiceAudioSessionCoordinator(session: session)
    }

    override func tearDown() {
        Haptics.resetCoreHapticsStateForTesting()
        super.tearDown()
    }

    func testResponseHapticLifecycleLeavesVoiceAudioSessionUntouched() {
        let previousHandler = Haptics.testEmissionHandler
        let previousSuppressesHardware = Haptics.testSuppressesHardware
        defer {
            Haptics.testEmissionHandler = previousHandler
            Haptics.testSuppressesHardware = previousSuppressesHardware
        }
        Haptics.testEmissionHandler = { _ in }
        Haptics.testSuppressesHardware = false

        Haptics.responseStarted(coreHapticsAllowed: true)
        Haptics.toolStarted()
        Haptics.responseConcluded()
        Haptics.cancelLifecyclePattern()

        XCTAssertEqual(session.categoryCalls.count, 0)
        XCTAssertEqual(session.activationCalls.count, 0)
        XCTAssertNil(coordinator.appliedPolicy)
    }

    func testResponseHapticsLeaveActiveVoiceOwnershipIntact() throws {
        let previousHandler = Haptics.testEmissionHandler
        let previousSuppressesHardware = Haptics.testSuppressesHardware
        defer {
            Haptics.testEmissionHandler = previousHandler
            Haptics.testSuppressesHardware = previousSuppressesHardware
        }
        Haptics.testEmissionHandler = { _ in }
        Haptics.testSuppressesHardware = false

        let lease = try coordinator.acquire(.conversationCapture)
        session.resetRecordings()

        Haptics.responseStarted(coreHapticsAllowed: false)
        Haptics.cancelLifecyclePattern()

        XCTAssertEqual(session.categoryCalls.count, 0)
        XCTAssertEqual(session.activationCalls.count, 0)
        XCTAssertEqual(session.deactivationCount, 0)
        XCTAssertEqual(coordinator.appliedPolicy, .conversation)

        coordinator.release(lease)
        XCTAssertEqual(session.deactivationCount, 1, "only the explicit owner release may deactivate the session")
    }

    func testAppStateSuppressesCoreHapticsWhileVoiceSessionIsActive() async {
        let suiteName = "HapticsVoiceIsolation.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            XCTFail("Failed to create test UserDefaults suite")
            return
        }
        addTeardownBlock { defaults.removePersistentDomain(forName: suiteName) }

        let appState = AppState(defaults: defaults, loadSavedConnection: false)
        let controller = VoiceConversationController(
            capture: StubPermissionCapture(),
            playback: StubPlayback(),
            gateway: StubVoiceGateway(),
            submit: { _ in true },
            interrupt: {}
        )
        appState.voiceConversationController = controller

        // No voice session: ordinary response haptics may use Core Haptics.
        XCTAssertTrue(appState.responseHapticsMayUseCoreHaptics)

        // A live voice conversation means capture or playback ownership may
        // be held, so the custom Core Haptics pattern is suppressed in
        // favour of the UIKit fallback.
        await controller.startListening()
        XCTAssertFalse(appState.responseHapticsMayUseCoreHaptics)

        // A paused mic keeps the voice session logically open (and the
        // conversation state non-idle), so suppression holds.
        controller.pauseMicrophone()
        XCTAssertFalse(appState.responseHapticsMayUseCoreHaptics)

        controller.stop()
        XCTAssertTrue(appState.responseHapticsMayUseCoreHaptics)
    }

    func testAppStateForwardingSuppressesEngineCreationWhileVoiceSessionIsLive() async {
        // End-to-end pin of the forwarding seam: while a voice session is
        // live, performResponseHapticEffects must degrade response-start to
        // the UIKit fallback (no engine creation); once the session ends, the
        // custom pattern is allowed again. Reverting the forwarding line to
        // an unconditionally-allowed call fails this test.
        let suiteName = "HapticsVoiceIsolation.Forwarding.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            XCTFail("Failed to create test UserDefaults suite")
            return
        }
        addTeardownBlock { defaults.removePersistentDomain(forName: suiteName) }

        let appState = AppState(defaults: defaults, loadSavedConnection: false)
        let controller = VoiceConversationController(
            capture: StubPermissionCapture(),
            playback: StubPlayback(),
            gateway: StubVoiceGateway(),
            submit: { _ in true },
            interrupt: {}
        )
        appState.voiceConversationController = controller

        await controller.startListening()
        appState.performResponseHapticEffects([.responseStarted])
        XCTAssertEqual(
            Haptics.coreHapticsEngineCreationCount, 0,
            "response-start haptics during a live voice session must not create a Core Haptics engine"
        )

        controller.stop()
        appState.performResponseHapticEffects([.responseStarted])
        XCTAssertEqual(
            Haptics.coreHapticsEngineCreationCount, 1,
            "response-start haptics outside a voice session may use the custom pattern"
        )
    }
}

@MainActor
private final class RecordingVoiceAudioSession: VoiceAudioSessionControlling {
    struct CategoryCall: Equatable {
        let category: AVAudioSession.Category
        let mode: AVAudioSession.Mode
        let options: AVAudioSession.CategoryOptions
    }

    private(set) var categoryCalls: [CategoryCall] = []
    private(set) var activationCalls: [(active: Bool, options: AVAudioSession.SetActiveOptions)] = []

    var deactivationCount: Int { activationCalls.filter { !$0.active }.count }

    func resetRecordings() {
        categoryCalls.removeAll()
        activationCalls.removeAll()
    }

    func setCategory(
        _ category: AVAudioSession.Category,
        mode: AVAudioSession.Mode,
        options: AVAudioSession.CategoryOptions
    ) throws {
        categoryCalls.append(CategoryCall(category: category, mode: mode, options: options))
    }

    func setActive(_ active: Bool, options: AVAudioSession.SetActiveOptions) throws {
        activationCalls.append((active, options))
    }
}

@MainActor
private final class StubPermissionCapture: AudioCaptureService {
    let events: AsyncStream<VoiceCaptureEvent>

    init() {
        events = AsyncStream { _ in }
    }

    func requestPermission() async -> Bool { true }
    func startListening(includePreRoll: Bool) throws {}
    func beginBargeInMonitoring() throws {}
    func pause() {}
    func resume() throws {}
    func finishUtterance() throws -> VoiceCapturedAudio {
        VoiceCapturedAudio(wavData: Data([1]), pcm16Data: Data([1, 0]), sampleRate: 16_000, duration: 0.01)
    }
    func stop() {}
}

@MainActor
private final class StubPlayback: SpeechPlaybackService {
    var isPlaying = false
    var ownershipIntent: VoiceAudioIntent = .standalonePlayback

    func start(sampleRate: Double) throws { isPlaying = true }
    func enqueuePCM16(_ data: Data, sampleRate: Double) throws -> Int { data.count / 2 }
    func playEncodedAudioData(_ data: Data) throws { isPlaying = true }
    func finish() throws {}
    func drain() async { isPlaying = false }
    func stop() { isPlaying = false }
}

@MainActor
private final class StubVoiceGateway: VoiceGatewayService {
    let profile = "default"

    func transcribe(_ audio: VoiceCapturedAudio) async throws -> String { "" }

    func openSpeechStream(
        onStart: @escaping @MainActor (Double) throws -> Void,
        onPCM16: @escaping @MainActor (Data, Double) throws -> Void,
        onEncodedAudio: @escaping @MainActor (Data) throws -> Void
    ) async throws -> VoiceSpeechStream {
        throw VoiceAudioError.unavailable("Unused in haptics isolation tests.")
    }
}
