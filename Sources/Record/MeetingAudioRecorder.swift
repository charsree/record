import AVFoundation
import Foundation

/// Streams meeting audio to two separate `.m4a` files while a meeting is
/// recording: one for the microphone, one for system audio. Playback then
/// plays both simultaneously at the same clock — so a Zoom call's mic
/// (you) and system (them) both end up in the recording without needing
/// a real-time mixer.
///
/// Layout on disk:
///   `~/Library/Application Support/Record/audio/<meetingID>.mic.m4a`
///   `~/Library/Application Support/Record/audio/<meetingID>.sys.m4a`
///
/// A legacy `<meetingID>.m4a` from earlier builds is still recognized as
/// a mic-only fallback for the player.
///
/// AAC 128 kbps mono @ 48 kHz — ~1 MB / min / stream.
@MainActor
final class MeetingAudioRecorder {
    private var micWriter: AudioFileWriter?
    private var sysWriter: AudioFileWriter?

    private enum Track: String {
        case mic = "mic"
        case sys = "sys"
    }

    // MARK: URL resolution

    private static func directory() -> URL {
        let base = try? FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        ).appending(path: "Record/audio")
        let dir = base ?? URL(fileURLWithPath: NSTemporaryDirectory()).appending(path: "record-audio")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private static func url(for meetingID: UUID, track: Track) -> URL {
        directory().appending(path: "\(meetingID.uuidString).\(track.rawValue).m4a")
    }

    static func micURL(for meetingID: UUID) -> URL {
        url(for: meetingID, track: .mic)
    }

    static func systemURL(for meetingID: UUID) -> URL {
        url(for: meetingID, track: .sys)
    }

    /// Kept for backward compatibility with builds that only wrote one file.
    static func legacyURL(for meetingID: UUID) -> URL {
        directory().appending(path: "\(meetingID.uuidString).m4a")
    }

    /// Any audio at all for this meeting?
    static func hasAudio(for meetingID: UUID) -> Bool {
        let fm = FileManager.default
        return fm.isReadableFile(atPath: micURL(for: meetingID).path)
            || fm.isReadableFile(atPath: systemURL(for: meetingID).path)
            || fm.isReadableFile(atPath: legacyURL(for: meetingID).path)
    }

    /// URLs of every audio track associated with the meeting that we can
    /// actually read. Used by the player and waveform generator.
    static func tracks(for meetingID: UUID) -> [URL] {
        let fm = FileManager.default
        var out: [URL] = []
        let mic = micURL(for: meetingID)
        if fm.isReadableFile(atPath: mic.path) { out.append(mic) }
        let sys = systemURL(for: meetingID)
        if fm.isReadableFile(atPath: sys.path) { out.append(sys) }
        if out.isEmpty {
            let legacy = legacyURL(for: meetingID)
            if fm.isReadableFile(atPath: legacy.path) { out.append(legacy) }
        }
        return out
    }

    /// Delete every audio file associated with the meeting.
    static func deleteAudio(for meetingID: UUID) {
        for url in [micURL(for: meetingID), systemURL(for: meetingID), legacyURL(for: meetingID)] {
            try? FileManager.default.removeItem(at: url)
        }
    }

    // MARK: Recording lifecycle

    func start(meetingID: UUID) throws {
        stop()
        // Fresh files.
        Self.deleteAudio(for: meetingID)
        micWriter = try AudioFileWriter(url: Self.micURL(for: meetingID), sampleRate: 48_000)
        try? FileManager.default.setAttributes(
            [.posixPermissions: 0o600], ofItemAtPath: Self.micURL(for: meetingID).path
        )
        sysWriter = try AudioFileWriter(url: Self.systemURL(for: meetingID), sampleRate: 48_000)
        try? FileManager.default.setAttributes(
            [.posixPermissions: 0o600], ofItemAtPath: Self.systemURL(for: meetingID).path
        )
    }

    func writeMic(_ packet: MicrophoneAudioPacket) {
        micWriter?.append(samples: packet.monoSamples, sampleRate: packet.sampleRate)
    }

    func writeSystem(_ packet: SystemAudioPacket) {
        let mono = LocalAudioMath.monoSamples(
            fromInterleavedFloatData: packet.data,
            channelCount: Int(packet.channelCount)
        )
        sysWriter?.append(samples: mono, sampleRate: packet.sampleRate)
    }

    func stop() {
        micWriter?.close()
        sysWriter?.close()
        micWriter = nil
        sysWriter = nil
    }
}

/// Thin AVAudioFile wrapper. Resamples input to the writer's target rate
/// so heterogeneous packet rates (mic @ 44.1 vs system @ 48) end up in a
/// single time-consistent stream.
private final class AudioFileWriter {
    private let file: AVAudioFile
    private let targetFormat: AVAudioFormat

    init(url: URL, sampleRate: Double) throws {
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: 1,
            AVEncoderBitRateKey: 128_000,
            AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue
        ]
        self.file = try AVAudioFile(forWriting: url, settings: settings)
        guard let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: sampleRate,
            channels: 1,
            interleaved: false
        ) else {
            throw NSError(domain: "AudioFileWriter", code: 1)
        }
        self.targetFormat = format
    }

    func append(samples: [Float], sampleRate: Double) {
        let resampled: [Float]
        if abs(sampleRate - targetFormat.sampleRate) < 1 {
            resampled = samples
        } else {
            resampled = LocalAudioMath.resample(samples, from: sampleRate, to: targetFormat.sampleRate)
        }
        guard !resampled.isEmpty else { return }
        guard let buffer = AVAudioPCMBuffer(
            pcmFormat: targetFormat,
            frameCapacity: AVAudioFrameCount(resampled.count)
        ), let channel = buffer.floatChannelData?[0] else { return }
        for (index, sample) in resampled.enumerated() {
            channel[index] = sample
        }
        buffer.frameLength = AVAudioFrameCount(resampled.count)
        try? file.write(from: buffer)
    }

    func close() {
        // AVAudioFile finalizes on deinit.
    }
}
