import XCTest
@testable import Conduit

@MainActor
final class VoiceConversationControllerTests: XCTestCase {
    func testFloatMicrophoneSamplesEncodeAsLittleEndianPCM16() {
        let input: [Float] = [-1, -0.5, 0, 0.5, 1, .nan]
        let encoded = input.withUnsafeBufferPointer { buffer in
            VoicePCMEncoding.encode(buffer.baseAddress!, count: buffer.count)
        }
        let samples = encoded.data.withUnsafeBytes { bytes in
            bytes.bindMemory(to: Int16.self).map { Int16(littleEndian: $0) }
        }

        XCTAssertEqual(samples, [-32_768, -16_384, 0, 16_384, 32_767, 0])
        XCTAssertEqual(encoded.peak, 1)
    }

    func testOlderVoicePreferencesDefaultToHermesTranscription() throws {
        let data = try XCTUnwrap(#"{"outputMuted":false,"continuousConversation":true,"continueWakeConversation":false,"spokenStopPhrases":["stop"]}"#.data(using: .utf8))
        let preferences = try JSONDecoder().decode(VoiceProfilePreferences.self, from: data)

        XCTAssertEqual(preferences.resolvedTranscriptionMode, .hermes)
    }

    func testStartsListeningOnlyAfterPermission() async {
        let capture = MockCapture(permissionGranted: true)
        let controller = VoiceConversationController(
            capture: capture,
            playback: MockPlayback(),
            gateway: MockGateway(),
            submit: { _ in true },
            interrupt: {}
        )

        await controller.startListening()

        XCTAssertEqual(controller.state, .listening)
        XCTAssertTrue(capture.didStart)
    }

    func testResumeFromInitialIdleStartsFirstCapture() async {
        let capture = MockCapture(permissionGranted: true)
        let controller = VoiceConversationController(
            capture: capture,
            playback: MockPlayback(),
            gateway: MockGateway(),
            submit: { _ in true },
            interrupt: {}
        )

        await controller.resumeMicrophone()

        XCTAssertEqual(controller.state, .listening)
        XCTAssertEqual(capture.startCount, 1)
    }

    func testPermissionDenialDoesNotStartCapture() async {
        let capture = MockCapture(permissionGranted: false)
        let controller = VoiceConversationController(
            capture: capture,
            playback: MockPlayback(),
            gateway: MockGateway(),
            submit: { _ in true },
            interrupt: {}
        )

        await controller.startListening()

        XCTAssertEqual(controller.state, .failed("Microphone access is required for voice conversations."))
        XCTAssertFalse(capture.didStart)
    }

    func testTranscriptionTestReportsMicrophonePermissionFailure() async {
        let controller = VoiceConversationController(
            capture: MockCapture(permissionGranted: false),
            playback: MockPlayback(),
            gateway: MockGateway(),
            submit: { _ in true },
            interrupt: {}
        )

        let result = await controller.runTranscriptionTest(duration: 0)

        XCTAssertFalse(result.passed)
        XCTAssertEqual(result.message, "Microphone access is required for voice conversations.")
    }

    func testTranscriptionTestReportsCaptureStartFailureBeforeProviderCall() async {
        let capture = MockCapture(
            permissionGranted: true,
            startError: VoiceAudioError.unavailable("Microphone capture could not start.")
        )
        let gateway = MockGateway()
        let controller = VoiceConversationController(
            capture: capture,
            playback: MockPlayback(),
            gateway: gateway,
            submit: { _ in true },
            interrupt: {}
        )

        let result = await controller.runTranscriptionTest(duration: 0)

        XCTAssertFalse(result.passed)
        XCTAssertEqual(result.message, "Microphone capture could not start.")
        XCTAssertEqual(gateway.transcriptionCount, 0)
    }

    func testTranscriptionTestReturnsCapturedTranscript() async {
        let controller = VoiceConversationController(
            capture: MockCapture(permissionGranted: true),
            playback: MockPlayback(),
            gateway: MockGateway(transcript: "Captured locally"),
            submit: { _ in true },
            interrupt: {}
        )

        let result = await controller.runTranscriptionTest(duration: 0)

        XCTAssertTrue(result.passed)
        XCTAssertEqual(result.message, "Transcribed: Captured locally")
    }

    func testOnDevicePermissionPreparationReportsSpeechDenial() async {
        let controller = VoiceConversationController(
            capture: MockCapture(permissionGranted: true),
            playback: MockPlayback(),
            deviceTranscriber: MockDeviceTranscriber(transcript: "", permissionGranted: false),
            gateway: MockGateway(),
            submit: { _ in true },
            interrupt: {}
        )

        let result = await controller.requestOnDeviceTranscriptionPermissions()

        XCTAssertFalse(result.passed)
        XCTAssertEqual(result.message, "Speech Recognition permission is required for on-device transcription.")
    }

    func testOnDevicePermissionPreparationReportsMicrophoneDenial() async {
        let deviceTranscriber = MockDeviceTranscriber(transcript: "", permissionGranted: true)
        let controller = VoiceConversationController(
            capture: MockCapture(permissionGranted: false),
            playback: MockPlayback(),
            deviceTranscriber: deviceTranscriber,
            gateway: MockGateway(),
            submit: { _ in true },
            interrupt: {}
        )

        let result = await controller.requestOnDeviceTranscriptionPermissions()

        XCTAssertFalse(result.passed)
        XCTAssertEqual(result.message, "Microphone access is required for voice conversations.")
        XCTAssertEqual(deviceTranscriber.permissionRequestCount, 0, "Speech permission should not be requested after microphone denial")
    }

    func testOnDevicePermissionPreparationSucceedsWhenBothGranted() async {
        let deviceTranscriber = MockDeviceTranscriber(transcript: "", permissionGranted: true)
        let controller = VoiceConversationController(
            capture: MockCapture(permissionGranted: true),
            playback: MockPlayback(),
            deviceTranscriber: deviceTranscriber,
            gateway: MockGateway(),
            submit: { _ in true },
            interrupt: {}
        )

        let result = await controller.requestOnDeviceTranscriptionPermissions()

        XCTAssertTrue(result.passed)
        XCTAssertEqual(result.message, "On-device speech recognition is ready.")
        XCTAssertEqual(deviceTranscriber.permissionRequestCount, 1, "Speech permission should be requested exactly once")
    }

    func testAppleSpeechAvailabilityCanAttemptRecognition() {
        let ready = AppleSpeechRecognitionAvailability.ready(localeIdentifier: "en_US")
        XCTAssertTrue(ready.canAttemptRecognition)

        let permissionRequired = AppleSpeechRecognitionAvailability.permissionRequired(localeIdentifier: "en_US")
        XCTAssertTrue(permissionRequired.canAttemptRecognition)

        let permissionDenied = AppleSpeechRecognitionAvailability.permissionDenied
        XCTAssertFalse(permissionDenied.canAttemptRecognition)

        let unsupported = AppleSpeechRecognitionAvailability.unsupported(localeIdentifier: "en_US")
        XCTAssertFalse(unsupported.canAttemptRecognition)
    }

    func testTrailingSilenceTranscribesThenSubmitsThroughAuthoritativeSeam() async {
        let capture = MockCapture(permissionGranted: true)
        let gateway = MockGateway(transcript: "Hello Hermes")
        var submitted: [String] = []
        let controller = VoiceConversationController(
            capture: capture,
            playback: MockPlayback(),
            gateway: gateway,
            submit: { text in submitted.append(text); return true },
            interrupt: {}
        )
        controller.beginVoiceTurn(sessionID: "session")
        await controller.startListening()
        let start = Date()
        controller.ingestAudioLevel(0.1, at: start)
        controller.ingestAudioLevel(0, at: start.addingTimeInterval(1.3))
        try? await Task.sleep(nanoseconds: 50_000_000)

        XCTAssertEqual(submitted, ["Hello Hermes"])
        XCTAssertEqual(controller.state, .thinking)
        XCTAssertTrue(capture.didBeginMonitoring)
        XCTAssertEqual(controller.conversationTranscript.map(\.speaker), [.user])
        XCTAssertEqual(controller.conversationTranscript.map(\.text), ["Hello Hermes"])
    }

    func testAppleOnDeviceModeBypassesHermesTranscription() async {
        let capture = MockCapture(permissionGranted: true)
        let gateway = MockGateway(transcript: "Hermes transcript")
        let deviceTranscriber = MockDeviceTranscriber(transcript: "Apple transcript")
        var submitted: [String] = []
        let controller = VoiceConversationController(
            capture: capture,
            playback: MockPlayback(),
            deviceTranscriber: deviceTranscriber,
            gateway: gateway,
            submit: { submitted.append($0); return true },
            interrupt: {}
        )
        var preferences = VoiceProfilePreferences()
        preferences.transcriptionMode = .appleOnDevice
        controller.setProfilePreferences(preferences)
        controller.beginVoiceTurn(sessionID: "session")
        await controller.startListening()
        let start = Date()
        controller.ingestAudioLevel(0.1, at: start)
        controller.ingestAudioLevel(0, at: start.addingTimeInterval(1.3))
        try? await Task.sleep(nanoseconds: 50_000_000)

        XCTAssertEqual(submitted, ["Apple transcript"])
        XCTAssertEqual(deviceTranscriber.transcriptionCount, 1)
        XCTAssertEqual(gateway.transcriptionCount, 0)
    }

    func testBargeInRequiresSustainedSpeech() async {
        let capture = MockCapture(permissionGranted: true)
        var interrupts = 0
        let controller = VoiceConversationController(
            capture: capture,
            playback: MockPlayback(),
            gateway: MockGateway(),
            submit: { _ in true },
            interrupt: { interrupts += 1 }
        )
        await controller.startListening()
        let start = Date()
        controller.ingestAudioLevel(0.1, at: start)
        controller.ingestAudioLevel(0, at: start.addingTimeInterval(1.3))
        try? await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(controller.state, .thinking)
        let bargeInStart = Date()
        controller.ingestAudioLevel(0.1, at: bargeInStart)
        controller.ingestAudioLevel(0.1, at: bargeInStart.addingTimeInterval(0.31))
        try? await Task.sleep(nanoseconds: 50_000_000)

        XCTAssertEqual(interrupts, 1)
        XCTAssertEqual(controller.lastBargeInState, .thinking)
        XCTAssertEqual(controller.state, .listening)
    }

    func testVoiceDefaultsMirrorHermesDesktopVAD() {
        let configuration = VoiceConversationController.Configuration()
        XCTAssertEqual(configuration.voiceActivityThreshold, 0.075)
        XCTAssertEqual(configuration.trailingSilence, 1.25)
        XCTAssertEqual(configuration.idleSilence, 12)
        XCTAssertEqual(configuration.maximumUtterance, 60)
        XCTAssertEqual(configuration.bargeInDuration, 0.3)
    }

    func testAssistantDeltasStayInOnePersistentSpeechStream() async {
        let gateway = MockGateway()
        let capture = MockCapture(permissionGranted: true)
        let controller = VoiceConversationController(
            capture: capture,
            playback: MockPlayback(),
            gateway: gateway,
            submit: { _ in true },
            interrupt: {}
        )
        controller.beginVoiceTurn(sessionID: "session")
        await controller.startListening()
        let utteranceStart = Date()
        controller.ingestAudioLevel(0.1, at: utteranceStart)
        controller.ingestAudioLevel(0, at: utteranceStart.addingTimeInterval(1.3))
        try? await Task.sleep(nanoseconds: 50_000_000)
        controller.receiveAssistantEvent(.started(sessionID: "session"))
        controller.receiveAssistantEvent(.delta(sessionID: "session", text: "One "))
        controller.receiveAssistantEvent(.delta(sessionID: "session", text: "turn."))
        controller.receiveAssistantEvent(.completed(sessionID: "session", content: "One turn."))
        try? await Task.sleep(nanoseconds: 50_000_000)

        XCTAssertEqual(gateway.stream?.appended, ["One ", "turn."])
        XCTAssertEqual(gateway.openCount, 1)
    }

    func testStopDuringTranscriptionCannotSubmitOrRestartCapture() async {
        let capture = MockCapture(permissionGranted: true)
        let gateway = MockGateway(transcript: "late", transcriptionDelayNanoseconds: 150_000_000)
        var submitted: [String] = []
        let controller = VoiceConversationController(
            capture: capture,
            playback: MockPlayback(),
            gateway: gateway,
            submit: { submitted.append($0); return true },
            interrupt: {}
        )
        controller.beginVoiceTurn(sessionID: "voice-session")
        await controller.startListening()
        let utteranceStart = Date()
        controller.ingestAudioLevel(0.1, at: utteranceStart)
        controller.ingestAudioLevel(0, at: utteranceStart.addingTimeInterval(1.3))
        try? await Task.sleep(nanoseconds: 20_000_000)
        controller.stop()
        try? await Task.sleep(nanoseconds: 200_000_000)

        XCTAssertTrue(submitted.isEmpty)
        XCTAssertEqual(controller.state, .idle)
        XCTAssertEqual(capture.startCount, 1)
    }

    func testUnrelatedAssistantSessionIsIgnored() async {
        let gateway = MockGateway()
        let controller = VoiceConversationController(
            capture: MockCapture(permissionGranted: true),
            playback: MockPlayback(),
            gateway: gateway,
            submit: { _ in true },
            interrupt: {}
        )
        controller.beginVoiceTurn(sessionID: "voice-session")
        await controller.startListening()
        let start = Date()
        controller.ingestAudioLevel(0.1, at: start)
        controller.ingestAudioLevel(0, at: start.addingTimeInterval(1.3))
        try? await Task.sleep(nanoseconds: 50_000_000)
        controller.receiveAssistantEvent(.delta(sessionID: "typed-session", text: "Do not speak"))
        controller.receiveAssistantEvent(.completed(sessionID: "typed-session", content: "Do not speak"))
        try? await Task.sleep(nanoseconds: 50_000_000)

        XCTAssertEqual(gateway.openCount, 0)
        XCTAssertEqual(controller.state, .thinking)
    }

    func testContinuousConversationRearmsAssistantOwnershipForSecondTurn() async {
        let gateway = MockGateway(transcript: "next turn")
        let capture = MockCapture(permissionGranted: true)
        let controller = VoiceConversationController(
            capture: capture,
            playback: MockPlayback(),
            gateway: gateway,
            submit: { _ in true },
            interrupt: {}
        )
        controller.beginVoiceTurn(sessionID: "session")
        await controller.startListening()

        let first = Date()
        controller.ingestAudioLevel(0.1, at: first)
        controller.ingestAudioLevel(0, at: first.addingTimeInterval(1.3))
        try? await Task.sleep(nanoseconds: 50_000_000)
        controller.receiveAssistantEvent(.delta(sessionID: "session", text: "First."))
        controller.receiveAssistantEvent(.completed(sessionID: "session", content: "First."))
        try? await Task.sleep(nanoseconds: 50_000_000)

        let second = Date()
        controller.ingestAudioLevel(0.1, at: second)
        controller.ingestAudioLevel(0, at: second.addingTimeInterval(1.3))
        try? await Task.sleep(nanoseconds: 50_000_000)
        controller.receiveAssistantEvent(.delta(sessionID: "session", text: "Second."))
        try? await Task.sleep(nanoseconds: 50_000_000)

        XCTAssertEqual(gateway.openCount, 2)
        XCTAssertEqual(gateway.stream?.appended, ["Second."])
    }

    func testAdmittedRuntimeRebindKeepsAssistantVoiceFlowing() async {
        // Hermes events carry runtime routing ids. When a resume rebinds the
        // conversation's runtime mid-turn, the new id is a confirmed alias —
        // the assistant's voice must keep flowing instead of being dropped
        // by raw equality with the captured id.
        let gateway = MockGateway()
        let controller = VoiceConversationController(
            capture: MockCapture(permissionGranted: true),
            playback: MockPlayback(),
            gateway: gateway,
            submit: { _ in true },
            interrupt: {}
        )
        controller.beginVoiceTurn(sessionID: "voice-session")
        await controller.startListening()
        let start = Date()
        controller.ingestAudioLevel(0.1, at: start)
        controller.ingestAudioLevel(0, at: start.addingTimeInterval(1.3))
        try? await Task.sleep(nanoseconds: 50_000_000)

        controller.receiveAssistantEvent(.delta(sessionID: "voice-session", text: "Hello "))
        // The admitted rebind: the reconciled conversation positively
        // contains the turn's captured id.
        controller.extendAssistantSessionIDs(
            ["runtime-rebound"],
            ofConversationContaining: ["stored-a", "voice-session"]
        )
        controller.receiveAssistantEvent(.delta(sessionID: "runtime-rebound", text: "world."))
        controller.receiveAssistantEvent(.delta(sessionID: "unrelated", text: " no"))
        try? await Task.sleep(nanoseconds: 50_000_000)

        XCTAssertEqual(gateway.stream?.appended, ["Hello ", "world."])
    }

    func testVoiceAliasExtensionIgnoresADifferentConversation() async {
        // A reconcile belonging to conversation B while the voice turn is
        // live on conversation A must never inject B's runtime into A's
        // ownership: without the positive overlap guard, B's assistant
        // stream would be spoken into A's turn.
        let gateway = MockGateway()
        let controller = VoiceConversationController(
            capture: MockCapture(permissionGranted: true),
            playback: MockPlayback(),
            gateway: gateway,
            submit: { _ in true },
            interrupt: {}
        )
        controller.beginVoiceTurn(sessionID: "voice-session")
        await controller.startListening()
        let start = Date()
        controller.ingestAudioLevel(0.1, at: start)
        controller.ingestAudioLevel(0, at: start.addingTimeInterval(1.3))
        try? await Task.sleep(nanoseconds: 50_000_000)

        // The reconciled conversation's accepted set is disjoint from the
        // turn's captured id — the extension must be refused.
        controller.extendAssistantSessionIDs(
            ["runtime-of-b"],
            ofConversationContaining: ["stored-b", "runtime-of-b"]
        )
        controller.receiveAssistantEvent(.delta(sessionID: "runtime-of-b", text: " no"))
        try? await Task.sleep(nanoseconds: 50_000_000)

        XCTAssertTrue(
            gateway.stream?.appended.isEmpty ?? true,
            "Another conversation's runtime must never gain this turn's speech"
        )
    }

    func testVoiceAliasExtensionWithoutActiveTurnDoesNotLeakIntoNextTurn() async {
        let gateway = MockGateway()
        let controller = VoiceConversationController(
            capture: MockCapture(permissionGranted: true),
            playback: MockPlayback(),
            gateway: gateway,
            submit: { _ in true },
            interrupt: {}
        )
        // No beginVoiceTurn: the extension is a no-op and a later turn
        // captures only its own id.
        controller.extendAssistantSessionIDs(
            ["runtime-rebound"],
            ofConversationContaining: ["runtime-rebound"]
        )
        controller.beginVoiceTurn(sessionID: "voice-session")
        await controller.startListening()
        let start = Date()
        controller.ingestAudioLevel(0.1, at: start)
        controller.ingestAudioLevel(0, at: start.addingTimeInterval(1.3))
        try? await Task.sleep(nanoseconds: 50_000_000)
        controller.receiveAssistantEvent(.delta(sessionID: "runtime-rebound", text: " no"))
        try? await Task.sleep(nanoseconds: 50_000_000)

        XCTAssertTrue(
            gateway.stream?.appended.isEmpty ?? true,
            "A stale alias extension must not give the next turn's events speech"
        )
    }

    func testAudioInterruptionDuringTranscriptionCannotGhostSubmit() async {
        let capture = MockCapture(permissionGranted: true)
        let gateway = MockGateway(transcript: "late", transcriptionDelayNanoseconds: 150_000_000)
        var submitted: [String] = []
        let controller = VoiceConversationController(
            capture: capture,
            playback: MockPlayback(),
            gateway: gateway,
            submit: { submitted.append($0); return true },
            interrupt: {}
        )
        await controller.startListening()
        let start = Date()
        controller.ingestAudioLevel(0.1, at: start)
        controller.ingestAudioLevel(0, at: start.addingTimeInterval(1.3))
        try? await Task.sleep(nanoseconds: 20_000_000)
        capture.emit(.interrupted)
        try? await Task.sleep(nanoseconds: 200_000_000)

        XCTAssertTrue(submitted.isEmpty)
        XCTAssertEqual(controller.state, .failed("Audio was interrupted."))
    }

    func testIdleSilencePausesWithoutFailingVoiceSession() async {
        let capture = MockCapture(permissionGranted: true)
        let controller = VoiceConversationController(
            capture: capture,
            playback: MockPlayback(),
            gateway: MockGateway(),
            submit: { _ in true },
            interrupt: {}
        )
        await controller.startListening()
        controller.ingestAudioLevel(0, at: Date().addingTimeInterval(12.1))

        XCTAssertEqual(controller.state, .listening)
        XCTAssertTrue(controller.isMicrophonePaused)
        XCTAssertTrue(capture.didPause)
    }

    func testMutedAssistantStillBuildsAuthoritativeConversationTranscript() async {
        let gateway = MockGateway(transcript: "User words")
        let controller = VoiceConversationController(
            capture: MockCapture(permissionGranted: true),
            playback: MockPlayback(),
            gateway: gateway,
            submit: { _ in true },
            interrupt: {}
        )
        controller.beginVoiceTurn(sessionID: "session")
        await controller.startListening()
        let start = Date()
        controller.ingestAudioLevel(0.1, at: start)
        controller.ingestAudioLevel(0, at: start.addingTimeInterval(1.3))
        try? await Task.sleep(nanoseconds: 50_000_000)
        controller.setOutputMuted(true)
        controller.receiveAssistantEvent(.started(sessionID: "session"))
        controller.receiveAssistantEvent(.delta(sessionID: "session", text: "Partial"))
        controller.receiveAssistantEvent(.completed(sessionID: "session", content: "Authoritative answer"))
        try? await Task.sleep(nanoseconds: 50_000_000)

        XCTAssertEqual(controller.conversationTranscript.map(\.speaker), [.user, .assistant])
        XCTAssertEqual(controller.conversationTranscript.map(\.text), ["User words", "Authoritative answer"])
        XCTAssertEqual(gateway.openCount, 0)
    }

    func testEmptyAssistantCompletionDoesNotEraseDeltasOrAddBlankEntry() async {
        let controller = VoiceConversationController(
            capture: MockCapture(permissionGranted: true),
            playback: MockPlayback(),
            gateway: MockGateway(transcript: "Question"),
            submit: { _ in true },
            interrupt: {}
        )
        controller.beginVoiceTurn(sessionID: "session")
        await controller.startListening()
        let start = Date()
        controller.ingestAudioLevel(0.1, at: start)
        controller.ingestAudioLevel(0, at: start.addingTimeInterval(1.3))
        try? await Task.sleep(nanoseconds: 50_000_000)
        controller.setOutputMuted(true)
        controller.receiveAssistantEvent(.started(sessionID: "session"))
        controller.receiveAssistantEvent(.delta(sessionID: "session", text: "Keep this"))
        controller.receiveAssistantEvent(.completed(sessionID: "session", content: ""))
        try? await Task.sleep(nanoseconds: 50_000_000)

        XCTAssertEqual(controller.conversationTranscript.map(\.text), ["Question", "Keep this"])
    }

    func testConversationTranscriptPersistsUntilNextBeginVoiceTurn() async {
        let controller = VoiceConversationController(
            capture: MockCapture(permissionGranted: true),
            playback: MockPlayback(),
            gateway: MockGateway(transcript: "Keep me"),
            submit: { _ in true },
            interrupt: {}
        )
        controller.beginVoiceTurn(sessionID: "first")
        await controller.startListening()
        let start = Date()
        controller.ingestAudioLevel(0.1, at: start)
        controller.ingestAudioLevel(0, at: start.addingTimeInterval(1.3))
        try? await Task.sleep(nanoseconds: 50_000_000)
        controller.stop()

        XCTAssertEqual(controller.conversationTranscript.map(\.text), ["Keep me"])
        controller.beginVoiceTurn(sessionID: "second")
        XCTAssertTrue(controller.conversationTranscript.isEmpty)
    }

    func testMicrophonePausePreservesConversationStateAcrossListeningThinkingSpeakingAndMuted() async {
        let capture = MockCapture(permissionGranted: true)
        let gateway = MockGateway(transcript: "Hello", startsPlaybackOnOpen: true)
        let controller = VoiceConversationController(
            capture: capture,
            playback: MockPlayback(),
            gateway: gateway,
            submit: { _ in true },
            interrupt: {}
        )
        controller.beginVoiceTurn(sessionID: "session")
        await controller.startListening()

        controller.pauseMicrophone()
        XCTAssertEqual(controller.state, .listening)
        XCTAssertTrue(controller.isMicrophonePaused)
        await controller.resumeMicrophone()
        XCTAssertEqual(controller.state, .listening)

        let start = Date()
        controller.ingestAudioLevel(0.1, at: start)
        controller.ingestAudioLevel(0, at: start.addingTimeInterval(1.3))
        try? await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(controller.state, .thinking)
        controller.pauseMicrophone()
        await controller.resumeMicrophone()
        XCTAssertEqual(controller.state, .thinking)

        controller.receiveAssistantEvent(.started(sessionID: "session"))
        controller.receiveAssistantEvent(.delta(sessionID: "session", text: "Speaking"))
        try? await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(controller.state, .speaking)
        controller.pauseMicrophone()
        await controller.resumeMicrophone()
        XCTAssertEqual(controller.state, .speaking)

        controller.setOutputMuted(true)
        XCTAssertEqual(controller.state, .muted)
        controller.pauseMicrophone()
        await controller.resumeMicrophone()
        XCTAssertEqual(controller.state, .muted)
        XCTAssertFalse(controller.isMicrophonePaused)
        XCTAssertEqual(capture.resumeCount, 4)
    }

    func testNewAssistantStartTransactionallyReplacesCancelledSpeechDrain() async {
        let gateway = MockGateway(transcript: "User turn", blocksFirstStreamAppend: true)
        let controller = VoiceConversationController(
            capture: MockCapture(permissionGranted: true),
            playback: MockPlayback(),
            gateway: gateway,
            submit: { _ in true },
            interrupt: {}
        )
        controller.beginVoiceTurn(sessionID: "session")
        await controller.startListening()
        let start = Date()
        controller.ingestAudioLevel(0.1, at: start)
        controller.ingestAudioLevel(0, at: start.addingTimeInterval(1.3))
        try? await Task.sleep(nanoseconds: 50_000_000)

        controller.receiveAssistantEvent(.started(sessionID: "session"))
        controller.receiveAssistantEvent(.delta(sessionID: "session", text: "Old partial"))
        try? await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(gateway.openCount, 1)

        controller.receiveAssistantEvent(.started(sessionID: "session"))
        controller.receiveAssistantEvent(.delta(sessionID: "session", text: "Replacement"))
        controller.receiveAssistantEvent(.completed(sessionID: "session", content: "Replacement complete"))
        try? await Task.sleep(nanoseconds: 100_000_000)

        XCTAssertEqual(gateway.openCount, 2)
        XCTAssertEqual(gateway.streams.first?.cancelCount, 1)
        XCTAssertEqual(gateway.streams.last?.appended, ["Replacement"])
        XCTAssertEqual(gateway.streams.last?.finishCount, 1)
        XCTAssertEqual(controller.state, .listening)
        XCTAssertEqual(controller.conversationTranscript.last?.text, "Replacement complete")
    }

    func testStaleCancelledAssistantFailureAfterBargeInCannotFailNextVoiceTurn() async {
        let controller = VoiceConversationController(
            capture: MockCapture(permissionGranted: true),
            playback: MockPlayback(),
            gateway: MockGateway(transcript: "Next turn"),
            submit: { _ in true },
            interrupt: {}
        )
        controller.beginVoiceTurn(sessionID: "session")
        await controller.startListening()

        let first = Date()
        controller.ingestAudioLevel(0.1, at: first)
        controller.ingestAudioLevel(0, at: first.addingTimeInterval(1.3))
        try? await Task.sleep(nanoseconds: 50_000_000)
        controller.receiveAssistantEvent(.started(sessionID: "session"))

        let bargeIn = Date()
        controller.ingestAudioLevel(0.1, at: bargeIn)
        controller.ingestAudioLevel(0.1, at: bargeIn.addingTimeInterval(0.31))
        try? await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(controller.state, .listening)

        let second = Date()
        controller.ingestAudioLevel(0.1, at: second)
        controller.ingestAudioLevel(0, at: second.addingTimeInterval(1.3))
        try? await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(controller.state, .thinking)

        controller.receiveAssistantEvent(.failed(sessionID: "session", message: "Cancelled."))

        XCTAssertEqual(controller.state, .thinking)
    }

    func testResumeAfterPauseResetsSpeechTimingSoStaleSilenceCannotFinishUtterance() async {
        let capture = MockCapture(permissionGranted: true)
        let controller = VoiceConversationController(
            capture: capture,
            playback: MockPlayback(),
            gateway: MockGateway(),
            submit: { _ in true },
            interrupt: {}
        )

        await controller.startListening()
        let speechStart = Date()
        controller.ingestAudioLevel(0.5, at: speechStart)
        controller.pauseMicrophone()
        await controller.resumeMicrophone()

        // The pre-pause speech timestamp is stale by more than the trailing
        // silence window. Resume is a fresh listening window, so a silent
        // level event right after resume must not finish an utterance.
        let resumeDate = Date()
        controller.ingestAudioLevel(0.0, at: resumeDate.addingTimeInterval(10))
        XCTAssertEqual(controller.state, .listening)
        XCTAssertEqual(capture.finishUtteranceCount, 0)

        // A fresh utterance still finishes normally on trailing silence.
        controller.ingestAudioLevel(0.5, at: resumeDate.addingTimeInterval(2))
        controller.ingestAudioLevel(0.0, at: resumeDate.addingTimeInterval(3.3))
        try? await Task.sleep(nanoseconds: 50_000_000)

        XCTAssertEqual(controller.state, .thinking)
        XCTAssertEqual(capture.finishUtteranceCount, 1)
    }

    func testSpeechTestClaimsStandalonePlaybackOwnership() async {
        let playback = MockPlayback()
        let controller = VoiceConversationController(
            capture: MockCapture(permissionGranted: true),
            playback: playback,
            gateway: MockGateway(startsPlaybackOnOpen: true),
            submit: { _ in true },
            interrupt: {}
        )

        let result = await controller.runSpeechTest(text: "test")

        XCTAssertTrue(result.passed)
        XCTAssertEqual(playback.intentAtLastStart, .standalonePlayback)
    }

    func testConversationSpeechClaimsConversationPlaybackOwnership() async {
        let playback = MockPlayback()
        let controller = VoiceConversationController(
            capture: MockCapture(permissionGranted: true),
            playback: playback,
            gateway: MockGateway(startsPlaybackOnOpen: true),
            submit: { _ in true },
            interrupt: {}
        )
        controller.beginVoiceTurn(sessionID: "session")
        await controller.startListening()
        let utteranceStart = Date()
        controller.ingestAudioLevel(0.1, at: utteranceStart)
        controller.ingestAudioLevel(0, at: utteranceStart.addingTimeInterval(1.3))
        try? await Task.sleep(nanoseconds: 50_000_000)
        controller.receiveAssistantEvent(.started(sessionID: "session"))
        controller.receiveAssistantEvent(.delta(sessionID: "session", text: "One turn."))
        controller.receiveAssistantEvent(.completed(sessionID: "session", content: "One turn."))
        try? await Task.sleep(nanoseconds: 50_000_000)

        XCTAssertEqual(playback.intentAtLastStart, .conversationPlayback)
    }
}

/// Speaker feedback-loop regressions: on routes whose output can feed the
/// device microphone (built-in speaker/receiver), the assistant's own TTS
/// must never become a new user turn. Capture is suspended during playback
/// and the mic control becomes Interrupt; isolated headset routes keep the
/// existing live barge-in.
@MainActor
final class VoiceSpeakerSafeBargeInTests: XCTestCase {
    func testSpeakerRouteAssistantPlaybackCannotBargeInOnItself() async {
        let capture = MockCapture(permissionGranted: true)
        let gateway = MockGateway(transcript: "Why is the kanji cursed", startsPlaybackOnOpen: true)
        var submitted: [String] = []
        var interrupts = 0
        let policy = RoutePolicyBox(.speakerSafeHalfDuplex)
        let controller = VoiceConversationController(
            capture: capture,
            playback: MockPlayback(),
            gateway: gateway,
            routePolicyProvider: { policy.policy },
            submit: { submitted.append($0); return true },
            interrupt: { interrupts += 1 }
        )

        await Self.driveToSpeaking(controller, gateway: gateway)

        XCTAssertEqual(controller.state, .speaking)
        XCTAssertTrue(controller.isPlaybackCaptureSuspended, "speaker-safe routes suspend capture while Hermes speaks")
        XCTAssertTrue(capture.didPause)

        // The speaker's own TTS leaks back into the microphone: sustained
        // level above the voice activity threshold for longer than the
        // barge-in duration.
        let leakStart = Date()
        controller.ingestAudioLevel(0.5, at: leakStart)
        controller.ingestAudioLevel(0.5, at: leakStart.addingTimeInterval(0.31))
        controller.ingestAudioLevel(0.5, at: leakStart.addingTimeInterval(0.62))
        try? await Task.sleep(nanoseconds: 50_000_000)

        XCTAssertEqual(interrupts, 0, "assistant TTS must never schedule a barge-in on a speaker route")
        XCTAssertEqual(controller.state, .speaking)
        XCTAssertEqual(gateway.transcriptionCount, 1, "only the user's real utterance may be transcribed")
        XCTAssertEqual(capture.finishUtteranceCount, 1, "suspended capture must not record a second (assistant) utterance")
        XCTAssertEqual(submitted.count, 1, "no new user turn may be submitted from speaker leakage")
    }

    func testSpeakerRouteResumesFreshListeningAfterPlaybackCompletes() async {
        let capture = MockCapture(permissionGranted: true)
        let gateway = MockGateway(transcript: "Why is the kanji cursed", startsPlaybackOnOpen: true)
        var interrupts = 0
        let policy = RoutePolicyBox(.speakerSafeHalfDuplex)
        let controller = VoiceConversationController(
            capture: capture,
            playback: MockPlayback(),
            gateway: gateway,
            routePolicyProvider: { policy.policy },
            submit: { _ in true },
            interrupt: { interrupts += 1 }
        )

        await Self.driveToSpeaking(controller, gateway: gateway)
        XCTAssertEqual(capture.startCount, 1)
        controller.receiveAssistantEvent(.completed(sessionID: "session", content: "Chorus line answer."))
        try? await Task.sleep(nanoseconds: 150_000_000)

        XCTAssertFalse(controller.isPlaybackCaptureSuspended)
        XCTAssertEqual(controller.state, .listening)
        XCTAssertEqual(capture.startCount, 2, "listening resumes with a fresh capture window after playback")
        XCTAssertEqual(capture.lastStartIncludePreRoll, false, "the post-playback window must not reuse speaker-contaminated pre-roll")
        XCTAssertEqual(interrupts, 0)
    }

    func testInterruptOnSpeakerRouteStopsPlaybackAndStartsFreshListening() async {
        let capture = MockCapture(permissionGranted: true)
        let gateway = MockGateway(transcript: "Why is the kanji cursed", startsPlaybackOnOpen: true)
        let playback = MockPlayback()
        var interrupts = 0
        let policy = RoutePolicyBox(.speakerSafeHalfDuplex)
        let controller = VoiceConversationController(
            capture: capture,
            playback: playback,
            gateway: gateway,
            routePolicyProvider: { policy.policy },
            submit: { _ in true },
            interrupt: { interrupts += 1 }
        )

        await Self.driveToSpeaking(controller, gateway: gateway)
        XCTAssertTrue(controller.isPlaybackCaptureSuspended)
        XCTAssertTrue(playback.isPlaying)

        await controller.interruptAssistantPlayback()

        XCTAssertEqual(interrupts, 1, "Interrupt retires the assistant turn through the authoritative interruption path")
        XCTAssertFalse(playback.isPlaying)
        XCTAssertEqual(gateway.streams.first?.cancelCount, 1, "the in-flight speech stream is retired")
        XCTAssertFalse(controller.isPlaybackCaptureSuspended)
        XCTAssertEqual(controller.state, .listening)
        XCTAssertEqual(capture.startCount, 2)
        XCTAssertEqual(capture.lastStartIncludePreRoll, false, "no speaker-contaminated pre-roll may be requested")
        XCTAssertEqual(capture.finishUtteranceCount, 1, "no additional (assistant) utterance may be recorded")

        // The retired turn's late completion must stay retired.
        controller.receiveAssistantEvent(.completed(sessionID: "session", content: "Late tail"))
        try? await Task.sleep(nanoseconds: 80_000_000)
        XCTAssertEqual(gateway.openCount, 1, "a retired turn must not reopen speech")
        XCTAssertEqual(controller.state, .listening)
    }

    func testHeadsetRouteKeepsLiveBargeInDuringPlayback() async {
        let capture = MockCapture(permissionGranted: true)
        let gateway = MockGateway(transcript: "Question", startsPlaybackOnOpen: true)
        var interrupts = 0
        let policy = RoutePolicyBox(.fullDuplex)
        let controller = VoiceConversationController(
            capture: capture,
            playback: MockPlayback(),
            gateway: gateway,
            routePolicyProvider: { policy.policy },
            submit: { _ in true },
            interrupt: { interrupts += 1 }
        )

        await Self.driveToSpeaking(controller, gateway: gateway)

        XCTAssertEqual(controller.state, .speaking)
        XCTAssertFalse(controller.isPlaybackCaptureSuspended, "isolated headset routes keep live capture")
        XCTAssertEqual(capture.pauseCount, 0)

        let bargeInStart = Date()
        controller.ingestAudioLevel(0.5, at: bargeInStart)
        controller.ingestAudioLevel(0.5, at: bargeInStart.addingTimeInterval(0.31))
        try? await Task.sleep(nanoseconds: 80_000_000)

        XCTAssertEqual(interrupts, 1, "genuine headset barge-in still interrupts playback")
        XCTAssertEqual(controller.lastBargeInState, .speaking)
        XCTAssertEqual(controller.state, .listening)
        XCTAssertEqual(capture.lastStartIncludePreRoll, true, "genuine headset barge-in keeps pre-roll")
    }

    func testUserPauseRemainsAuthoritativeAcrossAutomaticSuspension() async {
        let capture = MockCapture(permissionGranted: true)
        let gateway = MockGateway(transcript: "Question", startsPlaybackOnOpen: true)
        var interrupts = 0
        let policy = RoutePolicyBox(.speakerSafeHalfDuplex)
        let controller = VoiceConversationController(
            capture: capture,
            playback: MockPlayback(),
            gateway: gateway,
            routePolicyProvider: { policy.policy },
            submit: { _ in true },
            interrupt: { interrupts += 1 }
        )
        controller.beginVoiceTurn(sessionID: "session")
        await controller.startListening()
        let utteranceStart = Date()
        controller.ingestAudioLevel(0.1, at: utteranceStart)
        controller.ingestAudioLevel(0, at: utteranceStart.addingTimeInterval(1.3))
        try? await Task.sleep(nanoseconds: 50_000_000)
        controller.pauseMicrophone()
        XCTAssertTrue(controller.isMicrophonePaused)

        controller.receiveAssistantEvent(.started(sessionID: "session"))
        controller.receiveAssistantEvent(.delta(sessionID: "session", text: "Answer while paused."))
        try? await Task.sleep(nanoseconds: 80_000_000)

        XCTAssertTrue(controller.isPlaybackCaptureSuspended, "playback on a speaker route still records the automatic suspension")
        XCTAssertTrue(controller.isMicrophonePaused, "the automatic suspension must not clear the user's pause")
        XCTAssertEqual(controller.state, .speaking)

        controller.receiveAssistantEvent(.completed(sessionID: "session", content: "Answer."))
        try? await Task.sleep(nanoseconds: 150_000_000)

        XCTAssertFalse(controller.isPlaybackCaptureSuspended)
        XCTAssertTrue(controller.isMicrophonePaused, "Hermes finishing playback must not auto-resume a user pause")
        XCTAssertEqual(controller.state, .listening)
        XCTAssertEqual(capture.resumeCount, 0, "resume must never be driven by the playback lifecycle")
        XCTAssertEqual(interrupts, 0)
    }

    func testMutedOutputNeverSuspendsCaptureAndKeepsBargeIn() async {
        let capture = MockCapture(permissionGranted: true)
        let gateway = MockGateway(transcript: "Question", startsPlaybackOnOpen: true)
        var interrupts = 0
        let policy = RoutePolicyBox(.speakerSafeHalfDuplex)
        let controller = VoiceConversationController(
            capture: capture,
            playback: MockPlayback(),
            gateway: gateway,
            routePolicyProvider: { policy.policy },
            submit: { _ in true },
            interrupt: { interrupts += 1 }
        )
        controller.beginVoiceTurn(sessionID: "session")
        await controller.startListening()
        let utteranceStart = Date()
        controller.ingestAudioLevel(0.1, at: utteranceStart)
        controller.ingestAudioLevel(0, at: utteranceStart.addingTimeInterval(1.3))
        try? await Task.sleep(nanoseconds: 50_000_000)
        controller.setOutputMuted(true)
        controller.receiveAssistantEvent(.started(sessionID: "session"))
        controller.receiveAssistantEvent(.delta(sessionID: "session", text: "Silenced answer."))
        try? await Task.sleep(nanoseconds: 80_000_000)

        // Existing mute semantics: muting during .thinking keeps .thinking;
        // the muted label only replaces an in-flight .speaking. Either way
        // nothing audible plays, so capture must never suspend.
        XCTAssertEqual(controller.state, .thinking)
        XCTAssertFalse(controller.isPlaybackCaptureSuspended, "no audible playback means no suspension")
        XCTAssertEqual(capture.pauseCount, 0)
        XCTAssertEqual(gateway.openCount, 0, "muted output never opens a speech stream")

        // With nothing audible playing, the user can still barge in.
        let bargeInStart = Date()
        controller.ingestAudioLevel(0.5, at: bargeInStart)
        controller.ingestAudioLevel(0.5, at: bargeInStart.addingTimeInterval(0.31))
        try? await Task.sleep(nanoseconds: 80_000_000)
        XCTAssertEqual(interrupts, 1)
    }

    func testMutingDuringPlaybackEndsSuspensionAndRestoresMonitoring() async {
        let capture = MockCapture(permissionGranted: true)
        let gateway = MockGateway(transcript: "Question", startsPlaybackOnOpen: true)
        var interrupts = 0
        let policy = RoutePolicyBox(.speakerSafeHalfDuplex)
        let controller = VoiceConversationController(
            capture: capture,
            playback: MockPlayback(),
            gateway: gateway,
            routePolicyProvider: { policy.policy },
            submit: { _ in true },
            interrupt: { interrupts += 1 }
        )

        await Self.driveToSpeaking(controller, gateway: gateway)
        XCTAssertTrue(controller.isPlaybackCaptureSuspended)

        controller.setOutputMuted(true)

        XCTAssertEqual(controller.state, .muted)
        XCTAssertFalse(controller.isPlaybackCaptureSuspended, "muting stops the audible playback that justified suspension")
        XCTAssertEqual(capture.resumeCount, 1, "capture becomes live again for monitoring")

        let bargeInStart = Date()
        controller.ingestAudioLevel(0.5, at: bargeInStart)
        controller.ingestAudioLevel(0.5, at: bargeInStart.addingTimeInterval(0.31))
        try? await Task.sleep(nanoseconds: 80_000_000)
        XCTAssertEqual(interrupts, 1, "with output muted nothing audible plays, so barge-in stays live")
    }

    func testRouteChangeOntoSpeakerDuringPlaybackSuspendsCaptureImmediately() async {
        let capture = MockCapture(permissionGranted: true)
        let gateway = MockGateway(transcript: "Question", startsPlaybackOnOpen: true)
        var interrupts = 0
        let policy = RoutePolicyBox(.fullDuplex)
        let controller = VoiceConversationController(
            capture: capture,
            playback: MockPlayback(),
            gateway: gateway,
            routePolicyProvider: { policy.policy },
            submit: { _ in true },
            interrupt: { interrupts += 1 }
        )

        await Self.driveToSpeaking(controller, gateway: gateway)
        XCTAssertFalse(controller.isPlaybackCaptureSuspended)
        XCTAssertEqual(capture.pauseCount, 0)

        // AirPods disconnect mid-utterance: the route becomes the built-in
        // speaker.
        policy.policy = .speakerSafeHalfDuplex
        capture.emit(.routeChanged)
        try? await Task.sleep(nanoseconds: 80_000_000)

        XCTAssertTrue(controller.isPlaybackCaptureSuspended, "moving onto an open speaker mid-utterance must suspend capture")
        XCTAssertEqual(capture.pauseCount, 1)

        let leakStart = Date()
        controller.ingestAudioLevel(0.5, at: leakStart)
        controller.ingestAudioLevel(0.5, at: leakStart.addingTimeInterval(0.31))
        try? await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(interrupts, 0, "no acoustic barge-in may survive a transition onto an open speaker")
        XCTAssertEqual(controller.state, .speaking)
    }

    func testRouteChangeOntoHeadsetDuringPlaybackStaysConservativeUntilBoundary() async {
        let capture = MockCapture(permissionGranted: true)
        let gateway = MockGateway(transcript: "Question", startsPlaybackOnOpen: true)
        var interrupts = 0
        let policy = RoutePolicyBox(.speakerSafeHalfDuplex)
        let controller = VoiceConversationController(
            capture: capture,
            playback: MockPlayback(),
            gateway: gateway,
            routePolicyProvider: { policy.policy },
            submit: { _ in true },
            interrupt: { interrupts += 1 }
        )

        await Self.driveToSpeaking(controller, gateway: gateway)
        XCTAssertTrue(controller.isPlaybackCaptureSuspended)

        policy.policy = .fullDuplex
        capture.emit(.routeChanged)
        try? await Task.sleep(nanoseconds: 80_000_000)
        XCTAssertTrue(controller.isPlaybackCaptureSuspended, "mid-utterance upgrade to full duplex stays conservative until the next playback boundary")

        controller.receiveAssistantEvent(.completed(sessionID: "session", content: "Done."))
        try? await Task.sleep(nanoseconds: 150_000_000)
        XCTAssertEqual(controller.state, .listening)
        XCTAssertFalse(controller.isPlaybackCaptureSuspended)
    }

    /// listening → user utterance → submit → .thinking → assistant .started
    /// + .delta: the gateway opens its speech stream, playback starts, and
    /// the controller settles in .speaking.
    private static func driveToSpeaking(
        _ controller: VoiceConversationController,
        gateway: MockGateway,
        sessionID: String = "session"
    ) async {
        controller.beginVoiceTurn(sessionID: sessionID)
        await controller.startListening()
        let utteranceStart = Date()
        controller.ingestAudioLevel(0.1, at: utteranceStart)
        controller.ingestAudioLevel(0, at: utteranceStart.addingTimeInterval(1.3))
        try? await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(controller.state, .thinking)
        controller.receiveAssistantEvent(.started(sessionID: sessionID))
        controller.receiveAssistantEvent(.delta(sessionID: sessionID, text: "From a cursed kanji to a full chibi chorus line."))
        try? await Task.sleep(nanoseconds: 80_000_000)
    }
}

/// Mutable route policy so tests can replay route transitions
/// deterministically; production reads the live AVAudioSession route.
@MainActor
private final class RoutePolicyBox {
    var policy: VoiceBargeInRoutePolicy
    init(_ policy: VoiceBargeInRoutePolicy) { self.policy = policy }
}

@MainActor
private final class MockCapture: AudioCaptureService {
    let events: AsyncStream<VoiceCaptureEvent>
    private var continuation: AsyncStream<VoiceCaptureEvent>.Continuation?
    let permissionGranted: Bool
    let startError: Error?
    var didStart = false
    var startCount = 0
    var didBeginMonitoring = false
    var didPause = false
    var pauseCount = 0
    var resumeCount = 0
    private(set) var lastStartIncludePreRoll: Bool?
    private(set) var finishUtteranceCount = 0

    init(permissionGranted: Bool, startError: Error? = nil) {
        self.permissionGranted = permissionGranted
        self.startError = startError
        var captured: AsyncStream<VoiceCaptureEvent>.Continuation?
        events = AsyncStream { captured = $0 }
        continuation = captured
    }
    func requestPermission() async -> Bool { permissionGranted }
    func startListening(includePreRoll: Bool) throws {
        didStart = true
        startCount += 1
        lastStartIncludePreRoll = includePreRoll
        if let startError { throw startError }
    }
    func beginBargeInMonitoring() throws { didBeginMonitoring = true }
    func pause() {
        didPause = true
        pauseCount += 1
    }
    func resume() throws { resumeCount += 1 }
    func finishUtterance() throws -> VoiceCapturedAudio {
        finishUtteranceCount += 1
        return VoiceCapturedAudio(wavData: Data([1]), pcm16Data: Data([1, 0]), sampleRate: 16_000, duration: 0.01)
    }
    func stop() {}
    func emit(_ event: VoiceCaptureEvent) { continuation?.yield(event) }
}

@MainActor
private final class MockPlayback: SpeechPlaybackService {
    var isPlaying = false
    var ownershipIntent: VoiceAudioIntent = .standalonePlayback
    /// The ownership intent in force when playback last started, so tests can
    /// assert which session policy a flow claimed.
    private(set) var intentAtLastStart: VoiceAudioIntent?
    func start(sampleRate: Double) throws {
        intentAtLastStart = ownershipIntent
        isPlaying = true
    }
    func enqueuePCM16(_ data: Data, sampleRate: Double) throws -> Int { data.count - (data.count % 2) }
    func playEncodedAudioData(_ data: Data) throws {
        intentAtLastStart = ownershipIntent
        isPlaying = true
    }
    func finish() throws {}
    func drain() async { isPlaying = false }
    func stop() { isPlaying = false }
}

@MainActor
private final class MockDeviceTranscriber: DeviceSpeechTranscriptionService {
    let transcript: String
    let permissionGranted: Bool
    private(set) var transcriptionCount = 0
    private(set) var permissionRequestCount = 0
    init(transcript: String, permissionGranted: Bool = true) {
        self.transcript = transcript
        self.permissionGranted = permissionGranted
    }
    func requestPermission() async -> Bool { permissionRequestCount += 1; return permissionGranted }
    func transcribe(_ audio: VoiceCapturedAudio) async throws -> String {
        transcriptionCount += 1
        return transcript
    }
    func cancel() {}
}

@MainActor
private final class MockGateway: VoiceGatewayService {
    let profile = "default"
    let transcript: String
    let transcriptionDelayNanoseconds: UInt64
    let startsPlaybackOnOpen: Bool
    let blocksFirstStreamAppend: Bool
    private(set) var transcriptionCount = 0
    private(set) var stream: MockSpeechStream?
    private(set) var streams: [MockSpeechStream] = []
    private(set) var openCount = 0
    init(
        transcript: String = "test",
        transcriptionDelayNanoseconds: UInt64 = 0,
        startsPlaybackOnOpen: Bool = false,
        blocksFirstStreamAppend: Bool = false
    ) {
        self.transcript = transcript
        self.transcriptionDelayNanoseconds = transcriptionDelayNanoseconds
        self.startsPlaybackOnOpen = startsPlaybackOnOpen
        self.blocksFirstStreamAppend = blocksFirstStreamAppend
    }
    func transcribe(_ audio: VoiceCapturedAudio) async throws -> String {
        transcriptionCount += 1
        if transcriptionDelayNanoseconds > 0 { try await Task.sleep(nanoseconds: transcriptionDelayNanoseconds) }
        return transcript
    }
    func openSpeechStream(onStart: @escaping @MainActor (Double) throws -> Void, onPCM16: @escaping @MainActor (Data, Double) throws -> Void, onEncodedAudio: @escaping @MainActor (Data) throws -> Void) async throws -> VoiceSpeechStream {
        openCount += 1
        if startsPlaybackOnOpen { try onStart(24_000) }
        let stream = MockSpeechStream(blocksAppend: blocksFirstStreamAppend && openCount == 1)
        self.stream = stream
        streams.append(stream)
        return stream
    }
}

@MainActor
private final class MockSpeechStream: VoiceSpeechStream {
    private(set) var appended: [String] = []
    private(set) var finishCount = 0
    private(set) var cancelCount = 0
    private let blocksAppend: Bool
    private var appendContinuation: CheckedContinuation<Void, Error>?
    private var isCancelled = false

    init(blocksAppend: Bool = false) { self.blocksAppend = blocksAppend }

    func append(_ text: String) async throws {
        appended.append(text)
        guard blocksAppend else { return }
        if isCancelled { throw URLError(.cancelled) }
        try await withCheckedThrowingContinuation { continuation in
            appendContinuation = continuation
            if isCancelled {
                appendContinuation = nil
                continuation.resume(throwing: URLError(.cancelled))
            }
        }
    }

    func finish() async throws -> Bool {
        finishCount += 1
        return false
    }

    func cancel() {
        guard !isCancelled else { return }
        isCancelled = true
        cancelCount += 1
        let continuation = appendContinuation
        appendContinuation = nil
        continuation?.resume(throwing: URLError(.cancelled))
    }
}
