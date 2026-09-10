import AVFoundation
import Foundation
import SwiftUI

/// Plays one or more audio tracks belonging to the same meeting at the
/// same clock — useful when we've split mic and system audio into two
/// files. All tracks start together, seek together, and finish together.
@MainActor
final class MeetingAudioPlayer: NSObject, ObservableObject, AVAudioPlayerDelegate {
    @Published private(set) var isPlaying: Bool = false
    @Published private(set) var currentTime: TimeInterval = 0
    @Published private(set) var duration: TimeInterval = 0

    private var players: [AVAudioPlayer] = []
    private var timer: Timer?

    // Per-track mute (indexed like the returned tracks array).
    @Published var mutedTracks: Set<URL> = []

    func load(urls: [URL]) {
        stop()
        players.removeAll()
        var maxDuration: TimeInterval = 0
        for url in urls {
            do {
                let player = try AVAudioPlayer(contentsOf: url)
                player.prepareToPlay()
                player.delegate = self
                players.append(player)
                if player.duration > maxDuration { maxDuration = player.duration }
            } catch {
                // Skip unreadable tracks.
            }
        }
        duration = maxDuration
    }

    func unload() {
        stop()
        players.removeAll()
        duration = 0
        currentTime = 0
        mutedTracks = []
    }

    func play() {
        guard !players.isEmpty else { return }
        // Anchor all players to the same host time so they start truly
        // simultaneously — small drift is inevitable but this pins the
        // very first sample per track to the same moment.
        let startAt = players.first?.deviceCurrentTime ?? 0
        let anchor = startAt + 0.05
        for player in players {
            applyMute(player)
            player.play(atTime: anchor)
        }
        isPlaying = true
        startTicking()
    }

    func pause() {
        for player in players { player.pause() }
        isPlaying = false
        stopTicking()
    }

    func stop() {
        for player in players {
            player.stop()
            player.currentTime = 0
        }
        currentTime = 0
        isPlaying = false
        stopTicking()
    }

    func togglePlayPause() {
        if isPlaying { pause() } else { play() }
    }

    func seek(to time: TimeInterval) {
        let clamped = max(0, min(time, duration))
        let wasPlaying = isPlaying
        for player in players {
            let targetTime = min(clamped, player.duration)
            player.currentTime = targetTime
        }
        currentTime = clamped
        if wasPlaying { play() }
    }

    func toggleMute(url: URL) {
        if mutedTracks.contains(url) {
            mutedTracks.remove(url)
        } else {
            mutedTracks.insert(url)
        }
        for player in players { applyMute(player) }
    }

    private func applyMute(_ player: AVAudioPlayer) {
        player.volume = mutedTracks.contains(player.url ?? URL(fileURLWithPath: "")) ? 0 : 1
    }

    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        // A track finishes; if any other is still playing, keep the tick
        // going; otherwise stop.
        Task { @MainActor in
            if self.players.allSatisfy({ !$0.isPlaying }) {
                self.isPlaying = false
                self.currentTime = self.duration
                self.stopTicking()
            }
        }
    }

    private func startTicking() {
        stopTicking()
        timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, let leader = self.players.first else { return }
                self.currentTime = leader.currentTime
            }
        }
    }

    private func stopTicking() {
        timer?.invalidate()
        timer = nil
    }
}

enum WaveformGenerator {
    /// Combined peaks across every provided track — take the max of both
    /// mic and system peaks at each bucket so the visualization reflects
    /// "someone was speaking".
    static func combinedPeaks(urls: [URL], bucketCount: Int = 320) async -> [Float] {
        var accumulated: [Float] = []
        for url in urls {
            let peaks = await peaks(url: url, bucketCount: bucketCount)
            if accumulated.isEmpty {
                accumulated = peaks
            } else {
                for index in 0..<min(accumulated.count, peaks.count) {
                    accumulated[index] = max(accumulated[index], peaks[index])
                }
            }
        }
        return accumulated
    }

    /// Reads the audio file at `url` and returns `bucketCount` peak values
    /// (0…1) for waveform rendering. Async / off-main because it can take
    /// hundreds of ms on long files.
    static func peaks(url: URL, bucketCount: Int = 320) async -> [Float] {
        await Task.detached(priority: .utility) { () -> [Float] in
            guard let file = try? AVAudioFile(forReading: url) else { return [] }
            let format = file.processingFormat
            let totalFrames = AVAudioFrameCount(file.length)
            guard totalFrames > 0 else { return [] }
            let framesPerBucket = max(1, Int(totalFrames) / bucketCount)
            let readCapacity = AVAudioFrameCount(framesPerBucket)
            guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: readCapacity) else { return [] }
            var peaks: [Float] = []
            peaks.reserveCapacity(bucketCount)
            while file.framePosition < file.length {
                buffer.frameLength = 0
                let toRead = min(readCapacity, AVAudioFrameCount(file.length - file.framePosition))
                do {
                    try file.read(into: buffer, frameCount: toRead)
                } catch {
                    break
                }
                let frames = Int(buffer.frameLength)
                guard frames > 0 else { break }
                let channels = Int(format.channelCount)
                var maxAmp: Float = 0
                if let float = buffer.floatChannelData {
                    for channel in 0..<channels {
                        let data = float[channel]
                        for frame in 0..<frames {
                            let v = abs(data[frame])
                            if v > maxAmp { maxAmp = v }
                        }
                    }
                }
                peaks.append(min(1, maxAmp))
            }
            return peaks
        }.value
    }
}

struct WaveformView: View {
    let peaks: [Float]
    let progress: Double
    let onSeek: (Double) -> Void

    var body: some View {
        GeometryReader { proxy in
            Canvas { context, size in
                guard !peaks.isEmpty else { return }
                let barWidth = max(1.5, size.width / CGFloat(peaks.count) * 0.75)
                let spacing = size.width / CGFloat(peaks.count)
                for (index, peak) in peaks.enumerated() {
                    let x = spacing * CGFloat(index)
                    let barHeight = max(2, size.height * CGFloat(peak))
                    let rect = CGRect(
                        x: x + (spacing - barWidth) / 2,
                        y: (size.height - barHeight) / 2,
                        width: barWidth,
                        height: barHeight
                    )
                    let played = Double(index) / Double(max(1, peaks.count - 1)) <= progress
                    let color: Color = played ? .accentColor : Color.secondary.opacity(0.5)
                    context.fill(Path(roundedRect: rect, cornerRadius: 1.5), with: .color(color))
                }
                let markerX = size.width * CGFloat(progress)
                context.stroke(
                    Path { p in
                        p.move(to: CGPoint(x: markerX, y: 0))
                        p.addLine(to: CGPoint(x: markerX, y: size.height))
                    },
                    with: .color(.accentColor),
                    lineWidth: 2
                )
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        let fraction = min(1, max(0, value.location.x / proxy.size.width))
                        onSeek(fraction)
                    }
            )
        }
        .frame(height: 60)
    }
}
