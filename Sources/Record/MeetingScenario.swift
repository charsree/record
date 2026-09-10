import Foundation

/// High-level capture presets that map how people actually meet onto the
/// right combination of audio sources. Selecting one configures the
/// microphone tap and system-audio capture correctly so users don't have
/// to reason about routing.
enum MeetingScenario: String, CaseIterable, Identifiable, Codable {
    /// A video call running on THIS Mac (Zoom / Meet / Teams / Chime /
    /// Webex / Slack huddle). You speak into the mic; everyone else
    /// arrives via system audio. Capture both.
    case videoCall

    /// Everyone is physically in the room (or you're on a phone held to
    /// your ear / on speaker). The mic hears everything; system audio
    /// would only add noise or music playing on the Mac, so it's off.
    case inRoom

    /// Another app's audio routed into Record through a virtual input
    /// device such as BlackHole 2ch (existential.audio/blackhole) or an
    /// aggregate device. Pick the virtual device as the input; system
    /// audio capture is off because the virtual device IS the feed.
    case virtualDevice

    /// Only what's playing on the Mac — a webinar you're just watching,
    /// a recorded video, a livestream. Mic stays muted/off so your
    /// keyboard and room noise don't pollute the transcript.
    case playbackOnly

    var id: String { rawValue }

    var title: String {
        switch self {
        case .videoCall: "Video call on this Mac"
        case .inRoom: "In-room / phone"
        case .virtualDevice: "Virtual device (BlackHole)"
        case .playbackOnly: "Mac audio only"
        }
    }

    var icon: String {
        switch self {
        case .videoCall: "video.fill"
        case .inRoom: "person.2.fill"
        case .virtualDevice: "arrow.triangle.branch"
        case .playbackOnly: "speaker.wave.3.fill"
        }
    }

    var explanation: String {
        switch self {
        case .videoCall:
            "Captures your mic (you) and system audio (everyone on the call). The standard choice for Zoom, Meet, Teams, Chime, Webex, or Slack calls happening on this Mac."
        case .inRoom:
            "Mic only. For in-person meetings, phone calls on speaker, or interviews — everything comes through the microphone. System audio is off so Mac sounds don't pollute the transcript."
        case .virtualDevice:
            "Captures a virtual input like BlackHole 2ch. Route any app's output to BlackHole in Audio MIDI Setup (or the app's own output picker) and Record transcribes that feed. Pick the BlackHole device as your input below."
        case .playbackOnly:
            "System audio only — mic is not captured. For webinars you're watching, videos, or livestreams where your own voice doesn't matter."
        }
    }

    var capturesMicrophone: Bool {
        switch self {
        case .videoCall, .inRoom, .virtualDevice: true
        case .playbackOnly: false
        }
    }

    var capturesSystemAudio: Bool {
        switch self {
        case .videoCall, .playbackOnly: true
        case .inRoom, .virtualDevice: false
        }
    }

    static func load() -> MeetingScenario {
        guard let raw = UserDefaults.standard.string(forKey: "record.meetingScenario"),
              let scenario = MeetingScenario(rawValue: raw) else {
            return .videoCall
        }
        return scenario
    }

    func save() {
        UserDefaults.standard.set(rawValue, forKey: "record.meetingScenario")
    }
}
