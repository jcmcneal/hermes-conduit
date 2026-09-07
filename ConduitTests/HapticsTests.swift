import CoreHaptics
import XCTest
@testable import Conduit

@MainActor
final class HapticsTests: XCTestCase {
    override func setUp() {
        super.setUp()
        Haptics.resetCoreHapticsStateForTesting()
    }

    override func tearDown() {
        Haptics.resetCoreHapticsStateForTesting()
        super.tearDown()
    }

    func testResponseEngineIsHapticsOnly() {
        // The response lifecycle's Core Haptics engine is haptics-only and
        // session-free: it must never bind or activate the shared voice
        // AVAudioSession (issue #140).
        XCTAssertTrue(Haptics.enginePolicy.playsHapticsOnly)
    }

    func testUIKitFallbackResponseStartedDoesNotCreateEngine() {
        let previousHandler = Haptics.testEmissionHandler
        let previousSuppressesHardware = Haptics.testSuppressesHardware
        var events: [Haptics.Event] = []
        defer {
            Haptics.testEmissionHandler = previousHandler
            Haptics.testSuppressesHardware = previousSuppressesHardware
        }

        Haptics.testEmissionHandler = { events.append($0) }
        Haptics.testSuppressesHardware = false
        Haptics.coreHapticsEngineCreationCount = 0

        // While a voice session may hold the audio session, response haptics
        // degrade to the UIKit fallback pattern and must not create — or
        // start — a Core Haptics engine at all.
        Haptics.responseStarted(coreHapticsAllowed: false)

        XCTAssertEqual(events, [.responseStarted])
        XCTAssertEqual(
            Haptics.coreHapticsEngineCreationCount, 0,
            "degraded response haptics must not create a Core Haptics engine"
        )
    }

    func testUnsuppressedResponseStartedAttemptsCoreHapticsEngine() {
        let previousHandler = Haptics.testEmissionHandler
        let previousSuppressesHardware = Haptics.testSuppressesHardware
        var events: [Haptics.Event] = []
        defer {
            Haptics.testEmissionHandler = previousHandler
            Haptics.testSuppressesHardware = previousSuppressesHardware
        }

        Haptics.testEmissionHandler = { events.append($0) }
        Haptics.testSuppressesHardware = false
        Haptics.coreHapticsEngineCreationCount = 0

        Haptics.responseStarted(coreHapticsAllowed: true)

        XCTAssertEqual(events, [.responseStarted])
        XCTAssertEqual(
            Haptics.coreHapticsEngineCreationCount, 1,
            "unsuppressed response haptics attempt the custom Core Haptics pattern"
        )
    }

    func testHapticsDisabledPreventsEngineCreation() {
        let defaults = UserDefaults.standard
        let previousValue = defaults.object(forKey: Haptics.preferenceKey)
        defer {
            if let previousValue {
                defaults.set(previousValue, forKey: Haptics.preferenceKey)
            } else {
                defaults.removeObject(forKey: Haptics.preferenceKey)
            }
        }

        Haptics.enabled = false

        Haptics.responseStarted(coreHapticsAllowed: true)

        XCTAssertEqual(
            Haptics.coreHapticsEngineCreationCount, 0,
            "a disabled haptics preference must never create Core Haptics resources"
        )
    }

    func testEngineStopPolicyDiscardsOnlyRecoveryCriticalStops() {
        XCTAssertFalse(HapticsEngineStopPolicy.shouldDiscardEngine(for: .idleTimeout))
        XCTAssertTrue(HapticsEngineStopPolicy.shouldDiscardEngine(for: .audioSessionInterrupt))
        XCTAssertTrue(HapticsEngineStopPolicy.shouldDiscardEngine(for: .systemError))
    }

    func testEnabledUsesDevicePreference() {
        let defaults = UserDefaults.standard
        let previousValue = defaults.object(forKey: Haptics.preferenceKey)
        defer {
            if let previousValue {
                defaults.set(previousValue, forKey: Haptics.preferenceKey)
            } else {
                defaults.removeObject(forKey: Haptics.preferenceKey)
            }
        }

        defaults.removeObject(forKey: Haptics.preferenceKey)
        XCTAssertTrue(Haptics.enabled)

        Haptics.enabled = false
        XCTAssertFalse(Haptics.enabled)
        XCTAssertEqual(
            defaults.object(forKey: Haptics.preferenceKey) as? Bool,
            false
        )

        Haptics.enabled = true
        XCTAssertTrue(Haptics.enabled)
        XCTAssertEqual(
            defaults.object(forKey: Haptics.preferenceKey) as? Bool,
            true
        )
    }

    func testDisabledPreferenceSuppressesEveryBaseEmitter() {
        let defaults = UserDefaults.standard
        let previousValue = defaults.object(forKey: Haptics.preferenceKey)
        let previousHandler = Haptics.testEmissionHandler
        let previousSuppressesHardware = Haptics.testSuppressesHardware
        var events: [Haptics.Event] = []
        defer {
            if let previousValue {
                defaults.set(previousValue, forKey: Haptics.preferenceKey)
            } else {
                defaults.removeObject(forKey: Haptics.preferenceKey)
            }
            Haptics.testEmissionHandler = previousHandler
            Haptics.testSuppressesHardware = previousSuppressesHardware
        }

        Haptics.testEmissionHandler = { events.append($0) }
        Haptics.testSuppressesHardware = true
        Haptics.enabled = false

        Haptics.soft()
        Haptics.light()
        Haptics.medium()
        Haptics.rigid()
        Haptics.success()
        Haptics.error()
        Haptics.warning()
        Haptics.selection()

        XCTAssertTrue(events.isEmpty)
    }

    func testEnabledPreferenceRecordsEveryBaseEmitterInOrder() {
        let defaults = UserDefaults.standard
        let previousValue = defaults.object(forKey: Haptics.preferenceKey)
        let previousHandler = Haptics.testEmissionHandler
        let previousSuppressesHardware = Haptics.testSuppressesHardware
        var events: [Haptics.Event] = []
        defer {
            if let previousValue {
                defaults.set(previousValue, forKey: Haptics.preferenceKey)
            } else {
                defaults.removeObject(forKey: Haptics.preferenceKey)
            }
            Haptics.testEmissionHandler = previousHandler
            Haptics.testSuppressesHardware = previousSuppressesHardware
        }

        Haptics.testEmissionHandler = { events.append($0) }
        Haptics.testSuppressesHardware = true
        Haptics.enabled = true

        Haptics.soft()
        Haptics.light()
        Haptics.medium()
        Haptics.rigid()
        Haptics.success()
        Haptics.error()
        Haptics.warning()
        Haptics.selection()

        XCTAssertEqual(events, [.soft, .light, .medium, .rigid, .success, .error, .warning, .selection])
    }
}
