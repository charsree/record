import AVFoundation
import Foundation

/// One-shot offline transcription pipeline for user-supplied audio files.
/// Reads a `.wav` / `.mp3` / `.m4a` / `.aac` / `.aiff`, converts to the
/// 16 kHz mono float32 whisper expects, then feeds it through the same
/// LocalWhisperEngine we use for live audio in 30-second chunks.
///
/// Results are appended to a new meeting in the database so the file
/// shows up in History exactly like a live-recorded meeting.
enum AudioFileTranscriber {
    struct Progress: Equatable {
        var completedSeconds: Double
        var totalSeconds: Double
        var stage: Stage
        enum Stage: Equatable {
            case reading, transcribing, saving, done, failed(String)
        }
    }

    enum ImportError: LocalizedError {
        case unreadable(URL)
        case emptyResult(URL)

        var errorDescription: String? {
            switch self {
            case .unreadable(let url): "Could not read \(url.lastPathComponent) — unsupported format or corrupted file."
            case .emptyResult(let url): "No speech was detected in \(url.lastPathComponent)."
            }
        }
    }

    static func transcribe(
        url: URL,
        database: MeetingDatabase?,
        translate: Bool,
        progress: @Sendable @escaping (Progress) -> Void
    ) async throws -> UUID {
        progress(Progress(completedSeconds: 0, totalSeconds: 0, stage: .reading))

        // Read + resample the whole file into a single [Float] buffer at 16 kHz mono.
        let audioFile: AVAudioFile
        do {
            audioFile = try AVAudioFile(forReading: url)
        } catch {
            throw ImportError.unreadable(url)
        }
        let sourceFormat = audioFile.processingFormat
        let sourceLength = AVAudioFrameCount(audioFile.length)
        guard sourceLength > 0 else { throw ImportError.emptyResult(url) }

        let totalSeconds = Double(sourceLength) / sourceFormat.sampleRate

        let modelURL = try WhisperModelLocator.locate()
        try await LocalWhisperEngine.shared.prepare(modelURL: modelURL)

        // Chunk-based transcription so long files show incremental progress.
        // 30 seconds at 16 kHz = 480 000 samples per chunk. Overlap by 1 s
        // to give whisper context between chunks.
        let chunkSeconds: Double = 30
        let overlapSeconds: Double = 1
        let framesPerChunk = AVAudioFrameCount(chunkSeconds * sourceFormat.sampleRate)
        let overlapFrames = AVAudioFrameCount(overlapSeconds * sourceFormat.sampleRate)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: sourceFormat, frameCapacity: framesPerChunk) else {
            throw ImportError.unreadable(url)
        }

        // Reset file position.
        audioFile.framePosition = 0

        var segments: [TranscriptSegment] = []
        var elapsedSeconds: Double = 0
        let started = Date.now

        progress(Progress(completedSeconds: 0, totalSeconds: totalSeconds, stage: .transcribing))

        while audioFile.framePosition < audioFile.length {
            let remaining = AVAudioFrameCount(audioFile.length - audioFile.framePosition)
            let toRead = min(framesPerChunk, remaining)
            buffer.frameLength = 0
            do {
                try audioFile.read(into: buffer, frameCount: toRead)
            } catch {
                throw ImportError.unreadable(url)
            }
            let mono = LocalAudioMath.monoSamples(from: buffer)
            let resampled = LocalAudioMath.resample(
                mono,
                from: sourceFormat.sampleRate,
                to: 16_000
            )
            if !resampled.isEmpty {
                let text = try await LocalWhisperEngine.shared.transcribe(
                    samples: resampled,
                    modelURL: modelURL,
                    translate: translate
                )
                let cleaned = WhisperText.cleaned(text)
                if !cleaned.isEmpty {
                    // Split on sentence boundaries so we get multiple segments,
                    // roughly aligned with the elapsed offset in the file.
                    let sentences = cleaned
                        .split(whereSeparator: { $0 == "." || $0 == "!" || $0 == "?" })
                        .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                        .filter { !$0.isEmpty }
                    let secondsPerSentence = chunkSeconds / Double(max(sentences.count, 1))
                    for (index, sentence) in sentences.enumerated() {
                        let offset = elapsedSeconds + Double(index) * secondsPerSentence
                        segments.append(TranscriptSegment(
                            source: .microphone,
                            timestamp: started.addingTimeInterval(offset),
                            text: sentence,
                            isFinal: true
                        ))
                    }
                }
            }
            // Rewind by overlap so context flows between chunks.
            let readFrames = AVAudioFrameCount(toRead)
            let advance = readFrames > overlapFrames ? readFrames - overlapFrames : readFrames
            audioFile.framePosition = min(audioFile.length, audioFile.framePosition + AVAudioFramePosition(advance) - AVAudioFramePosition(toRead))
            elapsedSeconds += Double(advance) / sourceFormat.sampleRate
            progress(Progress(completedSeconds: elapsedSeconds, totalSeconds: totalSeconds, stage: .transcribing))
        }

        guard !segments.isEmpty else {
            progress(Progress(completedSeconds: totalSeconds, totalSeconds: totalSeconds, stage: .failed("No speech detected")))
            throw ImportError.emptyResult(url)
        }

        progress(Progress(completedSeconds: totalSeconds, totalSeconds: totalSeconds, stage: .saving))

        // Save as a new meeting.
        guard let database else { throw ImportError.emptyResult(url) }
        let title = "Imported: " + url.deletingPathExtension().lastPathComponent
        let meetingID = try await database.startMeeting(title: title)
        for segment in segments {
            try? await database.append(segment, meetingID: meetingID)
        }
        try? await database.finishMeeting(meetingID)

        progress(Progress(completedSeconds: totalSeconds, totalSeconds: totalSeconds, stage: .done))
        return meetingID
    }
}
