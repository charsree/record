import Foundation

/// One installable Whisper model. Sizes match ggerganov/whisper.cpp binary
/// distributions on Hugging Face, which is the canonical source for the
/// GGUF-style ggml-*.bin files we feed to our whisper.cpp bridge.
struct WhisperModel: Identifiable, Hashable, Codable {
    let id: String       // e.g. "large-v3-turbo"
    let displayName: String
    let filename: String // ggml-<id>.bin
    let bytes: Int64
    let downloadURL: URL
    let description: String
    /// English-only (`.en`) or multilingual. Multilingual variants handle
    /// accents (Indian, British, etc.) noticeably better on real-world audio.
    let isMultilingual: Bool
}

enum WhisperModelCatalog {
    /// Byte sizes were captured from Hugging Face's `Content-Length` headers
    /// on 2026-09-09. They're refreshed live via HEAD probes when the
    /// Preferences window opens, so a stale catalog never lies to the user.
    static let all: [WhisperModel] = [
        WhisperModel(
            id: "tiny.en",
            displayName: "Tiny (English)",
            filename: "ggml-tiny.en.bin",
            bytes: 77_704_715,
            downloadURL: URL(string: "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-tiny.en.bin")!,
            description: "Smallest and fastest. Noisy on real speech — mostly a battery-saver option.",
            isMultilingual: false
        ),
        WhisperModel(
            id: "base.en",
            displayName: "Base (English)",
            filename: "ggml-base.en.bin",
            bytes: 147_964_211,
            downloadURL: URL(string: "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-base.en.bin")!,
            description: "Bundled default. Fast, but weak on strong accents.",
            isMultilingual: false
        ),
        WhisperModel(
            id: "small.en",
            displayName: "Small (English)",
            filename: "ggml-small.en.bin",
            bytes: 487_614_201,
            downloadURL: URL(string: "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-small.en.bin")!,
            description: "~3× the accuracy of base for a bit more compute.",
            isMultilingual: false
        ),
        WhisperModel(
            id: "medium.en",
            displayName: "Medium (English)",
            filename: "ggml-medium.en.bin",
            bytes: 1_533_774_781,
            downloadURL: URL(string: "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-medium.en.bin")!,
            description: "Better on rare words and technical jargon. Slower.",
            isMultilingual: false
        ),
        WhisperModel(
            id: "large-v3-turbo",
            displayName: "Large v3 Turbo (multilingual)",
            filename: "ggml-large-v3-turbo.bin",
            bytes: 1_624_555_275,
            downloadURL: URL(string: "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-large-v3-turbo.bin")!,
            description: "Best accent handling (Indian English, non-native speakers) with near-realtime speed on Apple Silicon.",
            isMultilingual: true
        ),
        WhisperModel(
            id: "large-v3",
            displayName: "Large v3 (multilingual)",
            filename: "ggml-large-v3.bin",
            bytes: 3_095_033_483,
            downloadURL: URL(string: "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-large-v3.bin")!,
            description: "Highest accuracy overall. Slower than turbo.",
            isMultilingual: true
        )
    ]

    static func model(withID id: String) -> WhisperModel? {
        all.first(where: { $0.id == id })
    }
}
