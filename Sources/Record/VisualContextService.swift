import AppKit
import CoreGraphics
import Foundation
@preconcurrency import Vision

/// Runs Vision text recognition on the latest captured screen frame and
/// publishes any new text to the main-actor `onText` callback. Deliberately
/// NOT `@MainActor`: Vision calls its completion handler on its own worker
/// queue, and Swift 6 crashes with a queue-assertion trap if a `@MainActor`
/// closure runs off-main. We manage the tiny bit of mutable state ourselves
/// under a lock instead.
final class VisualContextService: @unchecked Sendable {
    /// Fires on the main actor whenever recognized text changes.
    var onText: (@MainActor (String) -> Void)?
    /// Fires on an arbitrary queue whenever a new frame is captured (for
    /// UI previews). Consumers should hop to the main actor themselves.
    var onFrameUpdated: (@Sendable (Data) -> Void)?

    private let lock = NSLock()
    private var _previousText = ""
    private var _latestFrameJPEG: Data?

    var latestFrameJPEG: Data? {
        lock.lock(); defer { lock.unlock() }
        return _latestFrameJPEG
    }

    func inspect(_ image: CGImage) {
        // Cache a JPEG snapshot for Kiro attachments. Done off the main queue
        // because encoding a screen-sized image is not free.
        let jpeg = NSBitmapImageRep(cgImage: image)
            .representation(using: .jpeg, properties: [.compressionFactor: 0.65])
        lock.lock()
        _latestFrameJPEG = jpeg
        lock.unlock()
        if let jpeg { onFrameUpdated?(jpeg) }

        let callback = onText
        let request = VNRecognizeTextRequest { [weak self] request, _ in
            guard let self else { return }
            let text = (request.results as? [VNRecognizedTextObservation] ?? [])
                .compactMap { $0.topCandidates(1).first?.string }
                .joined(separator: "\n")
            let changed = self.updateRecognized(text: text)
            guard changed, !text.isEmpty else { return }
            Task { @MainActor in callback?(text) }
        }
        Self.configureAccurateRecognition(request)

        DispatchQueue.global(qos: .utility).async {
            try? VNImageRequestHandler(cgImage: image).perform([request])
        }
    }

    /// Fires an `.accurate` VNRecognizeTextRequest against a caller-supplied
    /// CGImage without touching the background text-change stream. Returns
    /// the joined recognized lines. Use this for on-demand snapshot OCR
    /// (Snap & OCR button, Kiro attachments, etc.).
    static func recognizeText(from image: CGImage) async -> String {
        await withCheckedContinuation { continuation in
            let request = VNRecognizeTextRequest { request, _ in
                let text = (request.results as? [VNRecognizedTextObservation] ?? [])
                    .compactMap { $0.topCandidates(1).first?.string }
                    .joined(separator: "\n")
                continuation.resume(returning: text)
            }
            configureAccurateRecognition(request)
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    try VNImageRequestHandler(cgImage: image).perform([request])
                } catch {
                    continuation.resume(returning: "")
                }
            }
        }
    }

    /// Match the settings the macpowertools screenshot OCR uses: accurate
    /// recognition, language correction, English preferred with automatic
    /// language identification as a fallback, and the newest revision the
    /// current OS ships (revision 3 on macOS 13+, revision 4 on macOS 15+).
    private static func configureAccurateRecognition(_ request: VNRecognizeTextRequest) {
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        request.recognitionLanguages = ["en-US", "en-GB"]
        request.automaticallyDetectsLanguage = true
        // VNRecognizeTextRequestRevision4 exists on macOS 15+, revision 3 on
        // macOS 13+; pick whatever the current build enumerates.
        let latest = VNRecognizeTextRequest.supportedRevisions.max() ?? request.revision
        request.revision = latest
        request.minimumTextHeight = 0.008 // roughly 8 px tall on a 1000 px image
    }

    /// Swaps in the new recognized text and returns `true` iff it actually
    /// changed. Runs on Vision's worker queue — never touches the main actor.
    private func updateRecognized(text: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard text != _previousText else { return false }
        _previousText = text
        return true
    }
}
