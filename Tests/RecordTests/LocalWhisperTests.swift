import AVFoundation
import Foundation
import Testing
@testable import Record

struct LocalWhisperTests {
    @Test
    func resamplesAudioToSixteenKilohertz() {
        let input = Array(repeating: Float(0.25), count: 48_000)

        let output = LocalAudioMath.resample(input, from: 48_000)

        #expect(output.count == 16_000)
        #expect(abs((output.first ?? 0) - 0.25) < 0.0001)
    }

    @Test
    func rejectsSilentChunks() {
        #expect(!LocalAudioMath.containsSpeech(Array(repeating: 0, count: 16_000)))
    }

    @Test
    func detectsAudibleTone() {
        let tone = (0..<16_000).map { index -> Float in
            0.2 * sinf(2 * .pi * 440 * Float(index) / 16_000)
        }
        #expect(LocalAudioMath.containsSpeech(tone))
    }

    @Test
    func transcribesTheBundledWhisperFixture() async throws {
        let audioURL = URL(fileURLWithPath: "/opt/homebrew/opt/whisper-cpp/share/whisper-cpp/jfk.wav")
        guard FileManager.default.isReadableFile(atPath: audioURL.path) else {
            return // Optional fixture; skip when whisper-cpp examples are not installed.
        }
        let file = try AVAudioFile(forReading: audioURL)
        let frameCount = AVAudioFrameCount(file.length)
        let buffer = try #require(
            AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: frameCount)
        )
        try file.read(into: buffer)
        let samples = LocalAudioMath.resample(
            LocalAudioMath.monoSamples(from: buffer),
            from: buffer.format.sampleRate
        )

        let text = try await LocalWhisperEngine.shared.transcribe(
            samples: samples,
            modelURL: try WhisperModelLocator.locate()
        )

        #expect(text.lowercased().contains("ask not what"))
    }
}
