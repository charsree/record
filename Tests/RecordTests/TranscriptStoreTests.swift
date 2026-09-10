import Testing
@testable import Record
import Foundation

struct TranscriptStoreTests {
    @Test
    func replacesLiveSegmentForSameSource() async {
        let store = TranscriptStore()
        _ = await store.replaceLive(source: .microphone, text: "first")
        _ = await store.replaceLive(source: .microphone, text: "second")

        let segments = await store.all()
        #expect(segments.count == 1)
        #expect(segments[0].text == "second")
        #expect(!segments[0].isFinal)
    }

    @Test
    func prefersMatchingEvidence() async {
        let store = TranscriptStore()
        await store.append(TranscriptSegment(source: .microphone, text: "The rollout starts next Tuesday.", isFinal: true))
        await store.append(TranscriptSegment(source: .microphone, text: "I need coffee.", isFinal: true))

        let evidence = await store.evidence(for: "When does the rollout start?")
        #expect(evidence.first?.text == "The rollout starts next Tuesday.")
    }

    @Test
    func evidenceIgnoresLiveSegments() async {
        let store = TranscriptStore()
        await store.append(TranscriptSegment(source: .microphone, text: "The rollout starts Tuesday.", isFinal: true))
        _ = await store.replaceLive(source: .microphone, text: "rollout maybe cancelled")

        let evidence = await store.evidence(for: "rollout")
        #expect(evidence.count == 1)
        #expect(evidence.first?.text == "The rollout starts Tuesday.")
    }

    @Test
    func returnsTheExactFinalizedSegment() async {
        let store = TranscriptStore()
        _ = await store.replaceLive(source: .systemAudio, text: "The target date is")

        let finalized = await store.finalizeLive(source: .systemAudio, text: "The target date is Oct 14.")

        #expect(finalized?.text == "The target date is Oct 14.")
        #expect(finalized?.isFinal == true)
    }

    @Test
    func emptyFinalizeDropsPendingLiveBubble() async {
        let store = TranscriptStore()
        _ = await store.replaceLive(source: .microphone, text: "uh")

        let finalized = await store.finalizeLive(source: .microphone, text: "")

        #expect(finalized == nil)
        let all = await store.all()
        #expect(all.isEmpty)
    }
}

struct WhisperTextTests {
    @Test
    func stripsBracketedNoiseTokens() {
        #expect(WhisperText.cleaned(" [BLANK_AUDIO] hello [Music] ") == "hello")
    }

    @Test
    func dropsSingleWordHallucinations() {
        #expect(WhisperText.cleaned("Thank you.") == "")
        #expect(WhisperText.cleaned("you") == "")
    }

    @Test
    func dropsRepeatedHallucination() {
        #expect(WhisperText.cleaned("Thank you. Thank you. Thank you.") == "")
    }

    @Test
    func keepsRealSentences() {
        let text = "Thanks for that, let's move on to the next slide."
        #expect(WhisperText.cleaned(text) == text)
    }
}

struct TranscriptFormatterTests {
    @Test
    func plainTextOutputIncludesFinalSegmentsOnly() {
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        let segments = [
            TranscriptSegment(source: .microphone, timestamp: start, text: "Hi team", isFinal: true),
            TranscriptSegment(source: .systemAudio, timestamp: start.addingTimeInterval(5), text: "typing…", isFinal: false),
            TranscriptSegment(source: .visual, timestamp: start.addingTimeInterval(6), text: "Q4 plan", isFinal: true)
        ]

        let output = TranscriptFormatter.plainText(segments, title: "Standup", startedAt: start)

        #expect(output.contains("Standup"))
        #expect(output.contains("Hi team"))
        #expect(output.contains("Q4 plan"))
        #expect(!output.contains("typing"))
    }
}
