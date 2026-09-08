//
//  VoiceBargeInRoutePolicy.swift
//  Conduit
//
//  A single, testable seam for deciding whether acoustic barge-in is safe
//  while Hermes is audibly speaking, so AVAudioSession route inspection
//  never scatters across controller and UI code.
//

import AVFAudio
import Foundation

/// Whether the microphone may stay live while the assistant's own TTS plays.
enum VoiceBargeInRoutePolicy: Equatable {
    /// The output is acoustically isolated from this device's microphone
    /// (wired headset, or a Bluetooth headset-profile pairing where capture
    /// and playback both travel the headset's own mic/speaker). The user can
    /// keep speaking over Hermes: live barge-in monitoring stays armed.
    case fullDuplex
    /// The output can feed this device's microphone (built-in speaker,
    /// built-in receiver, or a generic/external output with no clear
    /// headset pairing). Capture is suspended while Hermes speaks: the
    /// amplitude-based barge-in detector cannot tell the speaker's own TTS
    /// from user speech (device-reproduced feedback loop).
    case speakerSafeHalfDuplex

    /// Classifies a route from its port descriptions. Deliberately
    /// conservative: anything that is not provably an isolated headset
    /// output is half duplex.
    static func resolve(
        outputs: [VoiceAudioRoutePort],
        inputs: [VoiceAudioRoutePort]
    ) -> VoiceBargeInRoutePolicy {
        // An open speaker or receiver anywhere in the output list vetoes
        // full duplex, even alongside a headset: audio may be rendering to
        // the open speaker, whose sound feeds the microphone.
        if outputs.contains(where: { $0.type == .builtInSpeaker || $0.type == .builtInReceiver }) {
            return .speakerSafeHalfDuplex
        }
        // Wired headphones/headset: output sits in the user's ears, away
        // from the device microphone.
        if outputs.contains(where: { $0.type == .headphones }) { return .fullDuplex }
        // A Bluetooth headset-profile INPUT paired with the same accessory's
        // output is clear evidence of a usable headset microphone/output
        // pairing (AirPods, mono headsets): the voice session's output
        // travels the headset's own speaker. Name equality keeps two
        // different accessories (headset mic + room speaker) conservative,
        // and empty names never pair (two anonymous ports are not evidence).
        let hasPairedHeadsetOutput = outputs.contains { output in
            guard output.type == .bluetoothHFP || output.type == .bluetoothA2DP else { return false }
            return inputs.contains {
                $0.type == .bluetoothHFP && !$0.name.isEmpty && $0.name == output.name
            }
        }
        if hasPairedHeadsetOutput { return .fullDuplex }
        // A2DP-only Bluetooth (speakers), AirPlay, and every other or
        // unknown output can feed the microphone: half duplex.
        return .speakerSafeHalfDuplex
    }

    /// Classifies the session's live route. MainActor-scoped because
    /// AVAudioSession is.
    @MainActor
    static func current() -> VoiceBargeInRoutePolicy {
        let route = AVAudioSession.sharedInstance().currentRoute
        return resolve(
            outputs: route.outputs.map { VoiceAudioRoutePort(type: $0.portType, name: $0.portName) },
            inputs: route.inputs.map { VoiceAudioRoutePort(type: $0.portType, name: $0.portName) }
        )
    }
}

/// The port facts the policy classifier needs, decoupled from
/// AVAudioSessionPortDescription (which cannot be constructed in tests).
/// `name` participates in Bluetooth pairing: a full-duplex classification
/// requires the headset-profile input and the output to belong to the same
/// named accessory.
struct VoiceAudioRoutePort: Equatable {
    var type: AVAudioSession.Port
    var name: String
}
