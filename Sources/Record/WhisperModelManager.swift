import Foundation
import SwiftUI

/// Coordinates local storage of Whisper models: which is installed, which
/// is currently selected, and downloading missing ones from the ggerganov
/// whisper.cpp Hugging Face mirror with live progress.
///
/// Models live in `~/Library/Application Support/Record/models/`. The
/// bundled `ggml-base.en.bin` is always resolvable so first-run works
/// without a network round-trip.
@MainActor
final class WhisperModelManager: NSObject, ObservableObject {
    static let shared = WhisperModelManager()

    @Published private(set) var installed: Set<String> = []
    @Published private(set) var download: DownloadState?
    @Published private(set) var probedSizes: [String: Int64] = [:]
    @Published var selectedID: String = SelectionDefaults.load() {
        didSet { SelectionDefaults.save(selectedID) }
    }

    struct DownloadState: Equatable {
        var modelID: String
        var receivedBytes: Int64
        var totalBytes: Int64
        var isFinishing: Bool = false
        var errorMessage: String?

        var fraction: Double {
            guard totalBytes > 0 else { return 0 }
            return min(1, Double(receivedBytes) / Double(totalBytes))
        }
    }

    /// Session used for HEAD probes only — has no delegate.
    private let probeSession: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 15
        return URLSession(configuration: config)
    }()

    /// Session used for actual downloads. We're its delegate, so we receive
    /// both progress and completion callbacks. Downloads can be large and
    /// slow, so timeouts are generous.
    private lazy var downloadSession: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 60
        config.timeoutIntervalForResource = 60 * 60 // 1 hour for large models
        config.waitsForConnectivity = true
        return URLSession(configuration: config, delegate: self, delegateQueue: .main)
    }()

    private var currentDownloadTask: URLSessionDownloadTask?
    private var currentModel: WhisperModel?

    private override init() {
        super.init()
        rescan()
    }

    // MARK: - Path resolution

    static func modelsDirectory() -> URL {
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

    func selectedModelURL() -> URL? {
        guard let model = WhisperModelCatalog.model(withID: selectedID) else { return nil }
        return existingURL(for: model)
    }

    func existingURL(for model: WhisperModel) -> URL? {
        let downloaded = Self.modelsDirectory().appending(path: model.filename)
        if FileManager.default.isReadableFile(atPath: downloaded.path) {
            return downloaded
        }
        if let bundled = Bundle.main.resourceURL?.appending(path: model.filename),
           FileManager.default.isReadableFile(atPath: bundled.path) {
            return bundled
        }
        let workspace = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appending(path: "Models/\(model.filename)")
        if FileManager.default.isReadableFile(atPath: workspace.path) {
            return workspace
        }
        return nil
    }

    func isInstalled(_ model: WhisperModel) -> Bool {
        existingURL(for: model) != nil
    }

    func rescan() {
        let installedIDs = WhisperModelCatalog.all
            .filter { existingURL(for: $0) != nil }
            .map(\.id)
        installed = Set(installedIDs)
    }

    // MARK: - Size probing

    func probeSizes() {
        for model in WhisperModelCatalog.all where existingURL(for: model) == nil {
            Task { @MainActor [weak self] in
                guard let self else { return }
                var request = URLRequest(url: model.downloadURL)
                request.httpMethod = "HEAD"
                request.timeoutInterval = 15
                if let (_, response) = try? await self.probeSession.data(for: request),
                   let http = response as? HTTPURLResponse,
                   http.expectedContentLength > 0 {
                    self.probedSizes[model.id] = http.expectedContentLength
                }
            }
        }
    }

    func size(of model: WhisperModel) -> Int64 {
        probedSizes[model.id] ?? model.bytes
    }

    // MARK: - Downloading

    func downloadModel(_ model: WhisperModel) {
        currentDownloadTask?.cancel()
        currentModel = model
        download = DownloadState(modelID: model.id, receivedBytes: 0, totalBytes: size(of: model))

        let task = downloadSession.downloadTask(with: model.downloadURL)
        currentDownloadTask = task
        task.resume()
    }

    func cancelDownload() {
        currentDownloadTask?.cancel()
        currentDownloadTask = nil
        currentModel = nil
        download = nil
    }

    func deleteModel(_ model: WhisperModel) {
        let url = Self.modelsDirectory().appending(path: model.filename)
        try? FileManager.default.removeItem(at: url)
        rescan()
        if selectedID == model.id, !installed.contains(model.id) {
            selectedID = "base.en"
        }
    }

    // MARK: - Persistence

    private enum SelectionDefaults {
        static let key = "record.whisperModelID"
        static func load() -> String {
            UserDefaults.standard.string(forKey: key) ?? "base.en"
        }
        static func save(_ id: String) {
            UserDefaults.standard.set(id, forKey: key)
        }
    }
}

// MARK: - URLSessionDownloadDelegate

extension WhisperModelManager: URLSessionDownloadDelegate {
    nonisolated func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        // Session was created with a main-actor delegate queue, so hop to main.
        let received = totalBytesWritten
        let expected = totalBytesExpectedToWrite
        Task { @MainActor in
            guard var state = self.download else { return }
            state.receivedBytes = received
            if expected > 0 { state.totalBytes = expected }
            self.download = state
        }
    }

    nonisolated func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {
        // We MUST copy the file inside this callback — the temp file at
        // `location` is deleted the moment this method returns.
        let temp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appending(path: "record-model-\(UUID().uuidString).bin")
        let moveResult: Result<URL, Error>
        do {
            try FileManager.default.moveItem(at: location, to: temp)
            moveResult = .success(temp)
        } catch {
            moveResult = .failure(error)
        }
        Task { @MainActor in
            self.finishDownload(with: moveResult)
        }
    }

    nonisolated func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: Error?
    ) {
        guard let error else { return }
        Task { @MainActor in
            self.finishDownload(with: .failure(error))
        }
    }

    private func finishDownload(with result: Result<URL, Error>) {
        guard let model = currentModel else { return }
        currentDownloadTask = nil
        currentModel = nil
        let destination = Self.modelsDirectory().appending(path: model.filename)
        switch result {
        case .success(let tempURL):
            do {
                try? FileManager.default.removeItem(at: destination)
                try FileManager.default.moveItem(at: tempURL, to: destination)
                rescan()
                download = nil
                selectedID = model.id
            } catch {
                var state = download ?? DownloadState(modelID: model.id, receivedBytes: 0, totalBytes: model.bytes)
                state.errorMessage = "Could not save the model: \(error.localizedDescription)"
                download = state
            }
        case .failure(let error):
            var state = download ?? DownloadState(modelID: model.id, receivedBytes: 0, totalBytes: model.bytes)
            state.errorMessage = error.localizedDescription
            download = state
        }
    }
}
