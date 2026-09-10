@preconcurrency import AVFoundation

struct MicrophoneAudioPacket: Sendable {
    let monoSamples: [Float]
    let sampleRate: Double
}

private final class MicrophoneAudioPacketSink: Sendable {
    private let callback: @MainActor @Sendable (MicrophoneAudioPacket) -> Void

    init(callback: @escaping @MainActor @Sendable (MicrophoneAudioPacket) -> Void) {
        self.callback = callback
    }

    func submit(_ packet: MicrophoneAudioPacket) {
        let callback = callback
        Task { @MainActor in
            callback(packet)
        }
    }
}

private func microphoneTapHandler(
    sink: MicrophoneAudioPacketSink
) -> AVAudioNodeTapBlock {
    { buffer, _ in
        let samples = LocalAudioMath.monoSamples(from: buffer)
        guard !samples.isEmpty else { return }
        sink.submit(
            MicrophoneAudioPacket(
                monoSamples: samples,
                sampleRate: buffer.format.sampleRate
            )
        )
    }
}

@MainActor
final class AudioCaptureService {
    var onPacket: (@MainActor @Sendable (MicrophoneAudioPacket) -> Void)?
    var onError: (@MainActor (String) -> Void)?

    private let engine = AVAudioEngine()
    private var packetSink: MicrophoneAudioPacketSink?

    func requestPermission() async -> Bool {
        await withCheckedContinuation { continuation in
            AVCaptureDevice.requestAccess(for: .audio) { granted in
                continuation.resume(returning: granted)
            }
        }
    }

    func start() throws {
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        let callback = onPacket
        let sink = MicrophoneAudioPacketSink { packet in
            callback?(packet)
        }
        packetSink = sink
        input.removeTap(onBus: 0)
        input.installTap(
            onBus: 0,
            bufferSize: 2_048,
            format: format,
            block: microphoneTapHandler(sink: sink)
        )
        engine.prepare()
        try engine.start()
    }

    func stop() {
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        packetSink = nil
    }
}
