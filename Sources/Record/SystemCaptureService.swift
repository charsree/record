import AudioToolbox
import CoreMedia
import CoreGraphics
import CoreImage
import ScreenCaptureKit

struct SystemAudioPacket: @unchecked Sendable {
    let data: Data
    let sampleRate: Double
    let channelCount: AVAudioChannelCount
    let frameCount: AVAudioFrameCount
}

@MainActor
final class SystemCaptureService: NSObject {
    var onScreenFrame: (@MainActor (CGImage) -> Void)?
    var onAudioPacket: (@MainActor (SystemAudioPacket) -> Void)?
    var onError: (@MainActor (String) -> Void)?

    private var stream: SCStream?
    private let acceptsVisualFrames = AtomicBool()
    private var latestFrameDigest: UInt64?
    private var lastVisualFrameAt = Date.distantPast

    func requestPermission() -> Bool {
        if CGPreflightScreenCaptureAccess() {
            return true
        }
        return CGRequestScreenCaptureAccess()
    }

    var isRunning: Bool { stream != nil }

    func start(
        includeVisualFrames: Bool,
        displayID: CGDirectDisplayID? = nil,
        windowID: CGWindowID? = nil
    ) async throws {
        acceptsVisualFrames.set(includeVisualFrames)
        let content = try await SCShareableContent.excludingDesktopWindows(
            false,
            onScreenWindowsOnly: true
        )
        let filter: SCContentFilter
        // Never capture Record's own windows (avoids OCR'ing our own UI).
        let selfBundleID = Bundle.main.bundleIdentifier ?? "local.record.app"
        let selfApps = content.applications.filter { $0.bundleIdentifier == selfBundleID }
        if let windowID,
           let window = content.windows.first(where: { $0.windowID == windowID }) {
            filter = SCContentFilter(desktopIndependentWindow: window)
        } else {
            guard let display = content.displays.first(where: { displayID == nil || $0.displayID == displayID }) else {
                throw CaptureError.noDisplay
            }
            filter = SCContentFilter(
                display: display,
                excludingApplications: selfApps,
                exceptingWindows: []
            )
        }
        let configuration = SCStreamConfiguration()
        configuration.capturesAudio = true
        configuration.excludesCurrentProcessAudio = true
        configuration.sampleRate = 48_000
        configuration.channelCount = 2
        configuration.queueDepth = 3
        if includeVisualFrames {
            if windowID == nil,
               let display = content.displays.first(where: { displayID == nil || $0.displayID == displayID }) {
                // Native display resolution — Vision's accurate OCR needs the
                // pixels to actually read tight UI text. Downsampling was the
                // biggest source of missed characters in the previous build.
                configuration.width = display.width
                configuration.height = display.height
            }
            configuration.minimumFrameInterval = CMTime(value: 1, timescale: 2)
        } else {
            configuration.width = 2
            configuration.height = 2
            configuration.minimumFrameInterval = CMTime(value: 1, timescale: 1)
        }

        let stream = SCStream(filter: filter, configuration: configuration, delegate: self)
        let queue = DispatchQueue(label: "record.system-capture")
        try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: queue)
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
        try await stream.startCapture()
        self.stream = stream
    }

    func setVisualFramesEnabled(_ enabled: Bool) {
        acceptsVisualFrames.set(enabled)
    }

    func stop() async {
        guard let stream else { return }
        try? await stream.stopCapture()
        self.stream = nil
        latestFrameDigest = nil
    }

    /// Grabs a native-resolution screenshot of the requested display or
    /// window and returns it as a CGImage suitable for OCR.
    static func screenshot(displayID: CGDirectDisplayID? = nil, windowID: CGWindowID? = nil) async throws -> CGImage {
        let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
        let selfBundleID = Bundle.main.bundleIdentifier ?? "local.record.app"
        let selfApps = content.applications.filter { $0.bundleIdentifier == selfBundleID }

        let filter: SCContentFilter
        var targetSize = CGSize(width: 1_920, height: 1_080)
        if let windowID, let window = content.windows.first(where: { $0.windowID == windowID }) {
            filter = SCContentFilter(desktopIndependentWindow: window)
            targetSize = window.frame.size
        } else {
            guard let display = content.displays.first(where: { displayID == nil || $0.displayID == displayID }) else {
                throw CaptureError.noDisplay
            }
            filter = SCContentFilter(
                display: display,
                excludingApplications: selfApps,
                exceptingWindows: []
            )
            targetSize = CGSize(width: display.width, height: display.height)
        }
        let configuration = SCStreamConfiguration()
        configuration.width = max(64, Int(targetSize.width))
        configuration.height = max(64, Int(targetSize.height))
        configuration.showsCursor = false
        return try await SCScreenshotManager.captureImage(
            contentFilter: filter,
            configuration: configuration
        )
    }

    static func windows() async throws -> [CaptureWindow] {
        let content = try await SCShareableContent.excludingDesktopWindows(
            false,
            onScreenWindowsOnly: true
        )
        return content.windows.compactMap { window in
            guard let title = window.title, !title.isEmpty,
                  let app = window.owningApplication?.applicationName,
                  app != "Record" else {
                return nil
            }
            return CaptureWindow(id: window.windowID, title: "\(app): \(title)")
        }
        .sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
    }

    private func accept(_ image: CGImage) -> Bool {
        guard Date.now.timeIntervalSince(lastVisualFrameAt) >= 1 else { return false }
        let digest = Self.frameDigest(image)
        if digest != latestFrameDigest {
            latestFrameDigest = digest
            lastVisualFrameAt = .now
            return true
        }
        return false
    }

    enum CaptureError: LocalizedError {
        case noDisplay

        var errorDescription: String? {
            "No capturable display is available."
        }
    }
}

struct CaptureWindow: Identifiable, Hashable {
    let id: CGWindowID
    let title: String
}

/// Lock-guarded bool that can be read from the ScreenCaptureKit delivery
/// thread and written from the main actor without data races.
final class AtomicBool: @unchecked Sendable {
    private var value = false
    private let lock = NSLock()

    func set(_ newValue: Bool) {
        lock.lock(); defer { lock.unlock() }
        value = newValue
    }

    func get() -> Bool {
        lock.lock(); defer { lock.unlock() }
        return value
    }
}

extension SystemCaptureService: SCStreamOutput, SCStreamDelegate {
    nonisolated func stream(
        _ stream: SCStream,
        didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
        of outputType: SCStreamOutputType
    ) {
        guard sampleBuffer.isValid else { return }
        switch outputType {
        case .audio:
            guard let packet = Self.audioPacket(from: sampleBuffer) else { return }
            Task { @MainActor [weak self] in
                self?.onAudioPacket?(packet)
            }
        case .screen:
            // Skip the OCR pipeline entirely when visual frames are off — the
            // 2×2 dummy frames from the audio-only config still arrive here.
            guard acceptsVisualFrames.get() else { return }
            guard let imageBuffer = sampleBuffer.imageBuffer else { return }
            let ciImage = CIImage(cvPixelBuffer: imageBuffer)
            guard let image = Self.ciContext.createCGImage(ciImage, from: ciImage.extent) else { return }
            Task { @MainActor [weak self] in
                guard let self, self.acceptsVisualFrames.get(), self.accept(image) else { return }
                self.onScreenFrame?(image)
            }
        case .microphone:
            break
        @unknown default:
            break
        }
    }

    nonisolated func stream(_ stream: SCStream, didStopWithError error: Error) {
        Task { @MainActor [weak self] in
            self?.onError?(error.localizedDescription)
        }
    }

    private nonisolated static func audioPacket(from sampleBuffer: CMSampleBuffer) -> SystemAudioPacket? {
        guard
            let formatDescription = CMSampleBufferGetFormatDescription(sampleBuffer),
            let streamDescription = CMAudioFormatDescriptionGetStreamBasicDescription(formatDescription),
            streamDescription.pointee.mBitsPerChannel == 32,
            streamDescription.pointee.mFormatID == kAudioFormatLinearPCM,
            streamDescription.pointee.mFormatFlags & kAudioFormatFlagIsFloat != 0,
            let blockBuffer = CMSampleBufferGetDataBuffer(sampleBuffer)
        else {
            return nil
        }

        var dataPointer: UnsafeMutablePointer<Int8>?
        var lengthAtOffset = 0
        var totalLength = 0
        guard CMBlockBufferGetDataPointer(
            blockBuffer,
            atOffset: 0,
            lengthAtOffsetOut: &lengthAtOffset,
            totalLengthOut: &totalLength,
            dataPointerOut: &dataPointer
        ) == noErr, let dataPointer else {
            return nil
        }

        let channels = AVAudioChannelCount(streamDescription.pointee.mChannelsPerFrame)
        guard channels > 0 else { return nil }
        let bytesPerFrame = Int(streamDescription.pointee.mBytesPerFrame)
        guard bytesPerFrame > 0 else { return nil }
        return SystemAudioPacket(
            data: Data(bytes: dataPointer, count: totalLength),
            sampleRate: streamDescription.pointee.mSampleRate,
            channelCount: channels,
            frameCount: AVAudioFrameCount(totalLength / bytesPerFrame)
        )
    }

    private nonisolated static let ciContext = CIContext()

    private nonisolated static func frameDigest(_ image: CGImage) -> UInt64 {
        guard let provider = image.dataProvider,
              let data = provider.data,
              let pointer = CFDataGetBytePtr(data) else {
            return UInt64(image.width) << 32 | UInt64(image.height)
        }
        let count = CFDataGetLength(data)
        guard count > 0 else { return UInt64(image.width) << 32 | UInt64(image.height) }
        let stride = max(1, count / 256)
        var hash: UInt64 = 1_469_598_103_934_665_603
        var index = 0
        while index < count {
            hash ^= UInt64(pointer[index])
            hash &*= 1_099_511_628_211
            index += stride
        }
        return hash
    }
}
