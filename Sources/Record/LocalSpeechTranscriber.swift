import AVFoundation
@preconcurrency import CWhisperBridge
import Foundation

/// Streams microphone or system-audio samples through whisper.cpp and emits
/// live-updating partial text plus final segments as speech pauses.
@MainActor
final class LocalSpeechTranscriber {
    /// Live partial text for the current utterance. May change as more audio arrives.
    var onLive: (@MainActor (String) -> Void)?
    /// Final text for a completed utterance. Fired once per detected speech burst.
    var onFinal: (@MainActor (String) -> Void)?
    var onError: (@MainActor (String) -> Void)?
    /// When true, whisper.cpp translates the audio into English instead of
    /// transcribing in the source language.
    var translate: Bool = false

    private let targetSampleRate: Double = 16_000
    /// How much fresh audio should accumulate before we consider asking
    /// whisper for another partial. We ALSO gate on `partialInFlight`
    /// below, so on slower models (large-v3-turbo, medium) we simply
    /// skip requests until the previous one finishes — no queueing.
    private let partialIntervalSamples = 16_000 * 1
    /// True while a partial-whisper call is running. We refuse to fire
    /// a new one until it returns, so partials never back up on slower
    /// models and the on-screen text stays as close to real time as the
    /// model allows.
    private var partialInFlight: Bool = false
    /// Force a final flush at this length even if the user hasn't paused.
    /// Kept small so a run-on speaker (or two people back-to-back with no
    /// 500ms gap) still turns into multiple separate transcript segments
    /// instead of one live bubble that gets replaced over and over.
    private let maxUtteranceSamples = 16_000 * 10          // was 25s → single bubble kept getting rewritten
    /// Silence needed to close an utterance.
    private let silenceHangSamples = Int(16_000 * 0.5)     // was 0.8s
    /// Minimum utterance length before we finalize.
    private let minimumUtteranceSamples = Int(16_000 * 0.6)
    /// RMS threshold for "this frame contains speech".
    private let speechThreshold: Float = 0.006
    /// When we hit max-utterance-samples we finalize the current utterance
    /// but keep the trailing ~500ms of audio to seed the next utterance so
    /// whisper doesn't cut mid-word.
    private let carryoverSamples = 16_000 / 2

    private var utteranceSamples: [Float] = []
    private var trailingSilenceSamples: Int = 0
    private var samplesSinceLastPartial: Int = 0
    private var lastPartialText: String = ""
    private var generation = UUID()
    private var modelURL: URL?
    private var running = false
    private var pendingWork: [Task<Void, Never>] = []

    func start() async throws {
        let modelURL = try WhisperModelLocator.locate()
        try await LocalWhisperEngine.shared.prepare(modelURL: modelURL)
        self.modelURL = modelURL
        resetUtterance()
        generation = UUID()
        running = true
    }

    func append(_ packet: MicrophoneAudioPacket) {
        guard running else { return }
        ingest(LocalAudioMath.resample(packet.monoSamples, from: packet.sampleRate))
    }

    func append(_ packet: SystemAudioPacket) {
        guard running else { return }
        let mono = LocalAudioMath.monoSamples(
            fromInterleavedFloatData: packet.data,
            channelCount: Int(packet.channelCount)
        )
        ingest(LocalAudioMath.resample(mono, from: packet.sampleRate))
    }

    /// Stops accepting audio and awaits any in-flight transcription so the
    /// caller can rely on `onFinal` having been delivered for everything
    /// spoken up to this point.
    func stop() async {
        guard running else { return }
        running = false
        if utteranceSamples.count >= minimumUtteranceSamples {
            finalizeUtterance()
        } else {
            resetUtterance()
        }
        let pending = pendingWork
        pendingWork.removeAll()
        for task in pending { await task.value }
    }

    private func ingest(_ samples: [Float]) {
        guard !samples.isEmpty else { return }
        // Split incoming audio into short frames for VAD.
        let frameSize = 1_600 // 100 ms at 16 kHz
        var index = 0
        while index < samples.count {
            let end = min(samples.count, index + frameSize)
            let frame = Array(samples[index..<end])
            index = end
            processFrame(frame)
        }
    }

    private func processFrame(_ frame: [Float]) {
        let hasSpeech = LocalAudioMath.containsSpeech(frame, threshold: speechThreshold)
        if hasSpeech {
            utteranceSamples.append(contentsOf: frame)
            trailingSilenceSamples = 0
            samplesSinceLastPartial += frame.count
            if samplesSinceLastPartial >= partialIntervalSamples, !partialInFlight {
                samplesSinceLastPartial = 0
                requestPartial()
            }
            if utteranceSamples.count >= maxUtteranceSamples {
                finalizeUtterance(carryTrailingAudio: true)
            }
        } else if !utteranceSamples.isEmpty {
            // Keep a little trailing silence so whisper can hear the end of the word.
            utteranceSamples.append(contentsOf: frame)
            trailingSilenceSamples += frame.count
            if trailingSilenceSamples >= silenceHangSamples,
               utteranceSamples.count >= minimumUtteranceSamples {
                finalizeUtterance(carryTrailingAudio: false)
            }
        }
        // Pure silence with nothing buffered: drop it.
    }

    private func requestPartial() {
        guard utteranceSamples.count >= minimumUtteranceSamples else { return }
        let snapshot = utteranceSamples
        let generation = self.generation
        partialInFlight = true
        submit(snapshot, generation: generation, isFinal: false)
    }

    private func finalizeUtterance(carryTrailingAudio: Bool = false) {
        let samples = utteranceSamples
        let generation = self.generation
        let carry: [Float]
        if carryTrailingAudio, samples.count > carryoverSamples {
            // Keep the last ~500 ms so the next utterance's whisper call
            // has enough context to not cut mid-word.
            carry = Array(samples.suffix(carryoverSamples))
        } else {
            carry = []
        }
        // Kill any outstanding partial-whisper tasks for the utterance we're
        // about to finalize — otherwise a late partial can revive the
        // just-finalized segment as a new live one with stale text.
        for task in pendingWork { task.cancel() }
        pendingWork.removeAll()
        partialInFlight = false
        resetUtterance()
        utteranceSamples = carry
        guard samples.count >= minimumUtteranceSamples else { return }
        submit(samples, generation: generation, isFinal: true)
    }

    private func resetUtterance() {
        utteranceSamples.removeAll(keepingCapacity: true)
        trailingSilenceSamples = 0
        samplesSinceLastPartial = 0
        lastPartialText = ""
        partialInFlight = false
    }

    /// Decide whether a new whisper partial should replace what's on
    /// screen. Whisper reruns on the WHOLE growing utterance buffer, so
    /// its word choice for the earlier part can drift between calls
    /// ("hello everyone" then "hi everybody" for the same audio) — which
    /// looks to the user like their transcript is being wiped out.
    ///
    /// STRICT rule: only accept a new partial if it cleanly EXTENDS the
    /// text we already showed. If whisper drifts (rewords the head, or
    /// swaps in a different transcription entirely), we FREEZE the live
    /// text at the previously-shown version and wait for finalization —
    /// where whisper has the full utterance and produces its most
    /// accurate output.
    ///
    /// Prefix comparison is done after normalizing casing and punctuation
    /// so a legitimate extension like "Hello there" → "Hello there, how
    /// are you" still counts even though whisper added a comma.
    private func shouldAcceptPartial(_ candidate: String) -> Bool {
        guard !candidate.isEmpty else { return false }
        let previous = lastPartialText
        if previous.isEmpty { return true }
        if candidate == previous { return false }
        let normalizedPrevious = Self.normalizeForPrefix(previous)
        let normalizedCandidate = Self.normalizeForPrefix(candidate)
        return normalizedCandidate.hasPrefix(normalizedPrevious)
    }

    private static func normalizeForPrefix(_ text: String) -> String {
        var scalars = String.UnicodeScalarView()
        var lastWasSpace = true
        for scalar in text.unicodeScalars {
            if CharacterSet.letters.contains(scalar)
                || CharacterSet.decimalDigits.contains(scalar) {
                for lower in String(scalar).lowercased().unicodeScalars {
                    scalars.append(lower)
                }
                lastWasSpace = false
            } else if CharacterSet.whitespacesAndNewlines.contains(scalar)
                || CharacterSet.punctuationCharacters.contains(scalar) {
                if !lastWasSpace {
                    scalars.append(UnicodeScalar(0x20))
                    lastWasSpace = true
                }
            }
        }
        return String(scalars).trimmingCharacters(in: .whitespaces)
    }

    private func submit(_ samples: [Float], generation: UUID, isFinal: Bool) {
        guard let modelURL else { return }
        let translate = self.translate
        let task = Task<Void, Never> { [weak self] in
            do {
                let raw = try await LocalWhisperEngine.shared.transcribe(
                    samples: samples,
                    modelURL: modelURL,
                    translate: translate
                )
                // If finalizeUtterance cancelled us while whisper was busy,
                // drop the result — it belongs to an utterance that no
                // longer exists in the live view.
                if Task.isCancelled { return }
                let cleaned = WhisperText.cleaned(raw)
                await MainActor.run {
                    guard let self, self.generation == generation else { return }
                    if !isFinal { self.partialInFlight = false }
                    if Task.isCancelled { return }
                    guard !cleaned.isEmpty else {
                        if isFinal { self.lastPartialText = "" }
                        return
                    }
                    if isFinal {
                        self.lastPartialText = ""
                        self.onFinal?(cleaned)
                    } else if self.shouldAcceptPartial(cleaned) {
                        self.lastPartialText = cleaned
                        self.onLive?(cleaned)
                    }
                }
            } catch {
                if Task.isCancelled { return }
                await MainActor.run {
                    guard let self, self.generation == generation else { return }
                    if !isFinal { self.partialInFlight = false }
                    self.onError?(error.localizedDescription)
                }
            }
        }
        pendingWork.append(task)
        pendingWork.removeAll { $0.isCancelled }
    }
}

actor LocalWhisperEngine {
    static let shared = LocalWhisperEngine()

    private var context: OpaquePointer?
    private var loadedModelPath: String?

    func prepare(modelURL: URL) throws {
        if context != nil, loadedModelPath == modelURL.path {
            return
        }
        if let context {
            record_whisper_destroy(context)
            self.context = nil
        }

        let threadCount = min(6, max(2, ProcessInfo.processInfo.activeProcessorCount / 2))
        let created = modelURL.path.withCString {
            record_whisper_create($0, Int32(threadCount))
        }
        guard let created else {
            throw LocalWhisperError.modelLoadFailed(modelURL.path)
        }
        context = created
        loadedModelPath = modelURL.path
    }

    func transcribe(samples: [Float], modelURL: URL, translate: Bool = false) throws -> String {
        try prepare(modelURL: modelURL)
        guard let context else {
            throw LocalWhisperError.modelLoadFailed(modelURL.path)
        }

        var errorCode: Int32 = 0
        let output = samples.withUnsafeBufferPointer {
            record_whisper_transcribe(
                context,
                $0.baseAddress,
                Int32($0.count),
                translate ? 1 : 0,
                &errorCode
            )
        }
        guard let output else {
            throw LocalWhisperError.transcriptionFailed(errorCode)
        }
        defer { record_whisper_string_destroy(output) }
        return String(cString: output)
    }
}

enum WhisperModelLocator {
    /// Resolves the model file to load. Preference order:
    /// 1. `RECORD_WHISPER_MODEL` env var
    /// 2. Downloaded selected model in Application Support
    /// 3. Any bundled ggml-*.bin
    /// 4. Workspace `Models/ggml-base.en.bin` (dev fallback)
    static func locate() throws -> URL {
        let environment = ProcessInfo.processInfo.environment
        if let path = environment["RECORD_WHISPER_MODEL"],
           FileManager.default.isReadableFile(atPath: path) {
            return URL(fileURLWithPath: path)
        }
        let selectedID = UserDefaults.standard.string(forKey: "record.whisperModelID") ?? "base.en"
        if let model = WhisperModelCatalog.model(withID: selectedID) {
            let downloaded = modelsDirectory().appending(path: model.filename)
            if FileManager.default.isReadableFile(atPath: downloaded.path) {
                return downloaded
            }
            if let bundled = Bundle.main.resourceURL?.appending(path: model.filename),
               FileManager.default.isReadableFile(atPath: bundled.path) {
                return bundled
            }
        }
        // Fall back to any bundled ggml file we can find.
        if let resourceURL = Bundle.main.resourceURL {
            for candidate in WhisperModelCatalog.all {
                let bundled = resourceURL.appending(path: candidate.filename)
                if FileManager.default.isReadableFile(atPath: bundled.path) {
                    return bundled
                }
            }
        }
        // Development workspace fallback.
        let devFallback = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appending(path: "Models/ggml-base.en.bin")
        if FileManager.default.isReadableFile(atPath: devFallback.path) {
            return devFallback
        }
        throw LocalWhisperError.modelMissing
    }

    private static func modelsDirectory() -> URL {
        let base = try? FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        ).appending(path: "Record/models")
        let url = base ?? URL(fileURLWithPath: NSTemporaryDirectory()).appending(path: "record-models")
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}

enum LocalAudioMath {
    static func monoSamples(from buffer: AVAudioPCMBuffer) -> [Float] {
        guard buffer.format.commonFormat == .pcmFormatFloat32 else { return [] }
        let frameCount = Int(buffer.frameLength)
        let channelCount = Int(buffer.format.channelCount)
        guard frameCount > 0, channelCount > 0 else { return [] }

        if buffer.format.isInterleaved {
            guard let data = buffer.audioBufferList.pointee.mBuffers.mData else { return [] }
            let input = data.assumingMemoryBound(to: Float.self)
            return (0..<frameCount).map { frame in
                var sum: Float = 0
                for channel in 0..<channelCount {
                    sum += input[frame * channelCount + channel]
                }
                return sum / Float(channelCount)
            }
        }

        guard let channels = buffer.floatChannelData else { return [] }
        return (0..<frameCount).map { frame in
            var sum: Float = 0
            for channel in 0..<channelCount {
                sum += channels[channel][frame]
            }
            return sum / Float(channelCount)
        }
    }

    static func monoSamples(fromInterleavedFloatData data: Data, channelCount: Int) -> [Float] {
        guard channelCount > 0 else { return [] }
        return data.withUnsafeBytes { bytes in
            let values = bytes.bindMemory(to: Float.self)
            let frameCount = values.count / channelCount
            return (0..<frameCount).map { frame in
                var sum: Float = 0
                for channel in 0..<channelCount {
                    sum += values[frame * channelCount + channel]
                }
                return sum / Float(channelCount)
            }
        }
    }

    static func resample(_ samples: [Float], from sourceRate: Double, to targetRate: Double = 16_000) -> [Float] {
        guard !samples.isEmpty, sourceRate > 0, targetRate > 0 else { return [] }
        if abs(sourceRate - targetRate) < 1 {
            return samples
        }

        let ratio = targetRate / sourceRate
        let outputCount = max(1, Int(Double(samples.count) * ratio))
        return (0..<outputCount).map { outputIndex in
            let sourcePosition = Double(outputIndex) / ratio
            let lower = min(samples.count - 1, Int(sourcePosition))
            let upper = min(samples.count - 1, lower + 1)
            let fraction = Float(sourcePosition - Double(lower))
            return samples[lower] + (samples[upper] - samples[lower]) * fraction
        }
    }

    static func containsSpeech(_ samples: [Float], threshold: Float = 0.006) -> Bool {
        guard !samples.isEmpty else { return false }
        let energy = samples.reduce(Float.zero) { $0 + $1 * $1 } / Float(samples.count)
        return sqrt(energy) >= threshold
    }
}

enum WhisperText {
    private static let noiseTokens: [String] = [
        "[BLANK_AUDIO]", "[ Silence ]", "[silence]", "(silence)",
        "[MUSIC]", "[Music]", "[music]", "(music)", "[MUSIC PLAYING]",
        "[APPLAUSE]", "(applause)", "[laughter]", "(laughter)",
        "[NOISE]", "(noise)", "[BLANK]"
    ]
    /// Frequent whisper hallucinations when fed silence or background hiss.
    private static let hallucinations: Set<String> = [
        "thank you.", "thanks for watching.", "thanks for watching!",
        "thank you for watching.", "thank you for watching!",
        "you", ".", "..", "...", "bye.", "bye!", "okay.", "ok.", "mm.", "hmm."
    ]

    static func cleaned(_ text: String) -> String {
        var value = text
        for token in noiseTokens {
            value = value.replacingOccurrences(of: token, with: "")
        }
        value = value.trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = value.lowercased()
        if hallucinations.contains(lower) { return "" }
        // Whisper sometimes emits a single repeated phrase like
        // "Thank you. Thank you. Thank you." — drop those too.
        let phrases = value.split(separator: ".").map {
            $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        }.filter { !$0.isEmpty }
        if let first = phrases.first,
           phrases.count >= 3,
           phrases.allSatisfy({ $0 == first }),
           hallucinations.contains(first + ".") {
            return ""
        }
        return value
    }
}

enum LocalWhisperError: LocalizedError {
    case modelMissing
    case modelLoadFailed(String)
    case transcriptionFailed(Int32)

    var errorDescription: String? {
        switch self {
        case .modelMissing:
            "The local whisper model is missing from Record.app."
        case .modelLoadFailed(let path):
            "The local whisper model could not be loaded at \(path)."
        case .transcriptionFailed(let code):
            "Local whisper transcription failed with code \(code)."
        }
    }
}
