//
//  VoiceAudioSessionCoordinator.swift
//  Conduit
//
//  Single authority for Conduit's ownership of the process-global
//  AVAudioSession. Services acquire an intent-scoped lease instead of
//  calling setCategory/setActive themselves, so playback-only flows
//  (Read Aloud, the TTS provider test) can no longer leave the session
//  active forever, and one component can never deactivate or reconfigure
//  the session while another still needs it (issue #140).
//

import AVFAudio
import Foundation
import OSLog

private let audioSessionLogger = Logger(subsystem: "com.milim.relay", category: "VoiceAudio")

/// An audio capability Conduit can hold against the shared session.
enum VoiceAudioIntent: Equatable {
    /// Microphone capture for an active Voice Conversation.
    case conversationCapture
    /// Assistant speech during an active Voice Conversation.
    case conversationPlayback
    /// Output-only speech outside a Voice Conversation (Read Aloud, TTS test).
    case standalonePlayback
}

/// Seam over `AVAudioSession.sharedInstance()` so coordinator policy can be
/// asserted in unit tests without touching real system audio state.
@MainActor
protocol VoiceAudioSessionControlling: AnyObject {
    func setCategory(
        _ category: AVAudioSession.Category,
        mode: AVAudioSession.Mode,
        options: AVAudioSession.CategoryOptions
    ) throws
    func setActive(_ active: Bool, options: AVAudioSession.SetActiveOptions) throws
}

@MainActor
final class SystemVoiceAudioSession: VoiceAudioSessionControlling {
    func setCategory(
        _ category: AVAudioSession.Category,
        mode: AVAudioSession.Mode,
        options: AVAudioSession.CategoryOptions
    ) throws {
        try AVAudioSession.sharedInstance().setCategory(category, mode: mode, options: options)
    }

    func setActive(_ active: Bool, options: AVAudioSession.SetActiveOptions) throws {
        try AVAudioSession.sharedInstance().setActive(active, options: options)
    }
}

/// Ownership token returned by `acquire`. Release is idempotent: releasing an
/// unknown or already-released lease is a no-op, so repeated cleanup paths
/// (stop, cancellation, backgrounding) can never underflow another owner.
struct VoiceAudioLease: Equatable {
    private let id: UUID
    /// Internal so tests can synthesize unknown leases; production callers
    /// only ever receive leases from `acquire`.
    init(id: UUID = UUID()) { self.id = id }
}

@MainActor
final class VoiceAudioSessionCoordinator {
    /// Shared instance: the underlying `AVAudioSession` is itself a
    /// process-global singleton, so one coordinator mirrors reality. Tests
    /// construct isolated instances with a mocked session seam.
    /// Both audio services are app-lifetime objects owned by AppState and
    /// must release leases on every terminal path (stop, cancellation,
    /// failure) — a lease still held at service deinit would leave a
    /// permanent owner entry here.
    static let shared = VoiceAudioSessionCoordinator()

    /// The session policy currently applied to the system session, or nil
    /// while no audio intent is active. Exposed read-only for diagnostics
    /// and deterministic ownership tests.
    private(set) var appliedPolicy: Policy?

    enum Policy: Equatable {
        /// `.playAndRecord` + `.voiceChat`: Voice Conversation capture, and
        /// assistant speech that shares the capture-owned session.
        case conversation
        /// Output-only `.playback` with media coexistence: standalone speech.
        case standalonePlayback
    }

    private let session: VoiceAudioSessionControlling
    private var leases: [UUID: VoiceAudioIntent] = [:]

    /// Optional injection instead of a default-constructed argument: default
    /// parameter values are evaluated in a nonisolated context, which cannot
    /// construct the MainActor-isolated `SystemVoiceAudioSession`.
    init(session: VoiceAudioSessionControlling? = nil) {
        self.session = session ?? SystemVoiceAudioSession()
    }

    func acquire(_ intent: VoiceAudioIntent) throws -> VoiceAudioLease {
        let lease = VoiceAudioLease(id: UUID())
        leases[lease.id] = intent
        do {
            try applyDominantPolicy()
        } catch {
            leases.removeValue(forKey: lease.id)
            audioSessionLogger.error(
                "audio session activation failed for \(Self.describe(intent), privacy: .public): \(String(describing: error), privacy: .public)"
            )
            throw error
        }
        audioSessionLogger.debug(
            "audio intent acquired: \(Self.describe(intent), privacy: .public) (owners: \(self.leases.count))"
        )
        return lease
    }

    func release(_ lease: VoiceAudioLease) {
        guard let intent = leases.removeValue(forKey: lease.id) else { return }
        do {
            try applyDominantPolicy()
        } catch {
            // Deactivation and policy-transition failures must never crash
            // the caller. The policy stays marked applied, so the next
            // ownership transition retries it instead of assuming the session
            // went inactive.
            audioSessionLogger.error(
                "audio session policy transition failed on release: \(String(describing: error), privacy: .public)"
            )
            return
        }
        audioSessionLogger.debug(
            "audio intent released: \(Self.describe(intent), privacy: .public) (owners: \(self.leases.count))"
        )
    }

    /// Reapplies the dominant policy after the system may have deactivated
    /// the session underneath a live lease (route change restarting capture).
    func reassert() throws {
        guard !leases.isEmpty else { return }
        let previous = appliedPolicy
        appliedPolicy = nil
        do {
            try applyDominantPolicy()
        } catch {
            // Mirror release(): keep the last known-applied policy so a later
            // ownership transition still diffs against it and retries the
            // deactivation instead of assuming the session went inactive.
            appliedPolicy = previous
            throw error
        }
    }

    /// Any conversation intent keeps the conversation configuration:
    /// conversation playback joins the capture-owned session without
    /// reconfiguring it, and conversation playback that outlives its capture
    /// owner (paused microphone while the assistant is still speaking) must
    /// not churn the audio route mid-playback.
    private var dominantPolicy: Policy? {
        if leases.values.contains(where: { $0 != .standalonePlayback }) {
            return .conversation
        }
        if leases.values.contains(.standalonePlayback) {
            return .standalonePlayback
        }
        return nil
    }

    private func applyDominantPolicy() throws {
        let target = dominantPolicy
        guard target != appliedPolicy else { return }
        switch target {
        case .conversation:
            let configuration = VoiceAudioSessionConfiguration.capture
            try session.setCategory(configuration.category, mode: configuration.mode, options: configuration.options)
            try session.setActive(true, options: [])
            appliedPolicy = .conversation
        case .standalonePlayback:
            let configuration = VoiceAudioSessionConfiguration.standalonePlayback
            try session.setCategory(configuration.category, mode: configuration.mode, options: configuration.options)
            try session.setActive(true, options: [])
            appliedPolicy = .standalonePlayback
        case nil:
            try session.setActive(false, options: .notifyOthersOnDeactivation)
            appliedPolicy = nil
        }
        audioSessionLogger.info("audio policy changed: \(Self.describe(target), privacy: .public)")
    }

    private static func describe(_ intent: VoiceAudioIntent) -> String {
        switch intent {
        case .conversationCapture: return "conversationCapture"
        case .conversationPlayback: return "conversationPlayback"
        case .standalonePlayback: return "standalonePlayback"
        }
    }

    private static func describe(_ policy: Policy?) -> String {
        switch policy {
        case .conversation: return "conversation"
        case .standalonePlayback: return "standalone"
        case nil: return "inactive"
        }
    }
}
