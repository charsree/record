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

    /// Capture ONE app's audio (plus your mic). Record uses macOS's
    /// native per-app capture — the built-in equivalent of routing an
    /// app through BlackHole, with zero extra software. Pick the app in
    /// the picker that appears.
    case specificApp

    /// Only what's playing on the Mac — a webinar you're just watching,
    /// a recorded video, a livestream. Mic stays off so your keyboard
    /// and room noise don't pollute the transcript.
    case playbackOnly

    var id: String { rawValue }

    var title: String {
        switch self {
        case .videoCall: "Video call on this Mac"
        case .inRoom: "In-room / phone"
        case .specificApp: "One app's audio"
        case .playbackOnly: "Mac audio only"
        }
    }

    var icon: String {
        switch self {
        case .videoCall: "video.fill"
        case .inRoom: "person.2.fill"
        case .specificApp: "app.badge.checkmark"
        case .playbackOnly: "speaker.wave.3.fill"
        }
    }

    var explanation: String {
        switch self {
        case .videoCall:
            "Captures your mic (you) and system audio (everyone on the call). The standard choice for Zoom, Meet, Teams, Chime, Webex, or Slack calls happening on this Mac."
        case .inRoom:
            "Mic only. For in-person meetings, phone calls on speaker, or interviews — everything comes through the microphone. System audio is off so Mac sounds don't pollute the transcript."
        case .specificApp:
            "Captures your mic plus ONE app's audio — nothing else on the system. Like routing that app through a virtual device, but built in. Pick the app below."
        case .playbackOnly:
            "System audio only — mic is not captured. For webinars you're watching, videos, or livestreams where your own voice doesn't matter."
        }
    }

    var capturesMicrophone: Bool {
        switch self {
        case .videoCall, .inRoom, .specificApp: true
        case .playbackOnly: false
        }
    }

    var capturesSystemAudio: Bool {
        switch self {
        case .videoCall, .playbackOnly, .specificApp: true
        case .inRoom: false
        }
    }

    /// Scenario needs the user to choose which app to capture.
    var needsAppSelection: Bool {
        self == .specificApp
    }

    static func load() -> MeetingScenario {
        guard let raw = UserDefaults.standard.string(forKey: "record.meetingScenario"),
              let scenario = MeetingScenario(rawValue: raw) else {
            return .videoCall
        }
        // Migrate the old BlackHole-based preset to the native one.
        return scenario
    }

    func save() {
        UserDefaults.standard.set(rawValue, forKey: "record.meetingScenario")
    }
}
