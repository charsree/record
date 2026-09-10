import AppKit
import SwiftUI

/// Tiny always-on-top window for corner-of-screen use while you're in a
/// Zoom / Chime / Slack call. Shows record status, elapsed time, the last
/// transcript line, and a compact start/pause/stop control.
struct MiniWindow: View {
    @ObservedObject var session: MeetingSession

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                RecordDotMini(active: session.isRecording, paused: session.isPaused)
                Text(session.currentMeetingTitle.isEmpty ? "Record" : session.currentMeetingTitle)
                    .font(.system(.body, design: .rounded).weight(.semibold))
                    .lineLimit(1)
                Spacer()
                if session.isRecording {
                    MiniElapsed(session: session)
                        .font(.callout.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                Button {
                    NSApp.activate(ignoringOtherApps: true)
                    RecordWindowActivator.bringMainWindowForward()
                } label: {
                    Image(systemName: "arrow.up.right.square")
                }
                .buttonStyle(.borderless)
                .help("Open full window")
            }
            HStack(spacing: 8) {
                if session.isRecording {
                    Button {
                        session.micMuted.toggle()
                    } label: {
                        Image(systemName: session.micMuted ? "mic.slash.fill" : "mic.fill")
                    }
                    .buttonStyle(.bordered)
                    .tint(session.micMuted ? .red : .accentColor)
                    .help(session.micMuted ? "Unmute mic" : "Mute mic (⌘⌥.)")
                    Button {
                        Task { await session.togglePause() }
                    } label: {
                        Image(systemName: session.isPaused ? "play.fill" : "pause.fill")
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(session.isPaused ? .accentColor : .orange)
                    .disabled(session.isBusy)
                    Button(role: .destructive) {
                        Task { await session.toggleRecording() }
                    } label: {
                        Image(systemName: "stop.fill")
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.red)
                    .disabled(session.isBusy)
                } else {
                    Button {
                        Task { await session.toggleRecording() }
                    } label: {
                        Label("Start", systemImage: "record.circle")
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(session.isBusy)
                }
                Spacer()
                LevelMeterMini(level: session.micLevel, color: .blue).frame(width: 42)
                if session.captureModeText.contains("system audio") {
                    LevelMeterMini(level: session.systemAudioLevel, color: .purple).frame(width: 42)
                }
            }
            if !session.lastTranscriptText.isEmpty {
                Text(session.lastTranscriptText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(12)
        .frame(minWidth: 320)
        .background(.ultraThinMaterial)
        .background(WindowFloatingConfigurator())
    }
}

/// Pushes the containing NSWindow above regular windows so the mini stays
/// visible during Zoom/Chime/Slack calls without stealing focus.
private struct WindowFloatingConfigurator: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async {
            if let window = view.window {
                window.level = .floating
                window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
                window.isMovableByWindowBackground = true
                window.titlebarAppearsTransparent = true
                window.styleMask.insert(.hudWindow)
            }
        }
        return view
    }
    func updateNSView(_ nsView: NSView, context: Context) {}
}

private struct RecordDotMini: View {
    let active: Bool
    let paused: Bool
    @State private var pulse = false

    var body: some View {
        Circle()
            .fill(paused ? .orange : (active ? .red : .secondary))
            .frame(width: 10, height: 10)
            .scaleEffect(pulse && active && !paused ? 1.2 : 1)
            .opacity(pulse && active && !paused ? 0.7 : 1)
            .animation(active && !paused ? .easeInOut(duration: 0.9).repeatForever(autoreverses: true) : .default, value: pulse)
            .onAppear { pulse = true }
    }
}

private struct MiniElapsed: View {
    @ObservedObject var session: MeetingSession
    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.5)) { _ in
            Text(format(session.activeElapsed))
        }
    }
    private func format(_ interval: TimeInterval) -> String {
        let s = max(0, Int(interval))
        let h = s / 3600
        let m = (s % 3600) / 60
        let sec = s % 60
        if h > 0 { return String(format: "%d:%02d:%02d", h, m, sec) }
        return String(format: "%d:%02d", m, sec)
    }
}

private struct LevelMeterMini: View {
    let level: Float
    let color: Color
    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(.secondary.opacity(0.2))
                Capsule()
                    .fill(color.gradient)
                    .frame(width: max(2, proxy.size.width * CGFloat(level)))
                    .animation(.easeOut(duration: 0.1), value: level)
            }
        }
        .frame(height: 4)
    }
}
