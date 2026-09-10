import AVFoundation
import CoreAudio
import Foundation

struct MicrophoneAudioPacket: Sendable {
    let monoSamples: [Float]
    let sampleRate: Double
}

/// One selectable audio input device (built-in mic, USB interface,
/// BlackHole virtual device, aggregate device, …).
struct AudioInputDevice: Identifiable, Hashable, Sendable {
    let id: AudioDeviceID
    let uid: String
    let name: String

    /// All devices that offer at least one input channel, in system order.
    /// Includes virtual loopback drivers like BlackHole 2ch/16ch, which is
    /// how users can route another app's audio into Record as a "mic".
    static func availableInputs() -> [AudioInputDevice] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var dataSize: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &dataSize
        ) == noErr else { return [] }
        let count = Int(dataSize) / MemoryLayout<AudioDeviceID>.size
        var deviceIDs = [AudioDeviceID](repeating: 0, count: count)
        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &dataSize, &deviceIDs
        ) == noErr else { return [] }

        var devices: [AudioInputDevice] = []
        for deviceID in deviceIDs {
            guard inputChannelCount(deviceID) > 0 else { continue }
            let name = stringProperty(deviceID, selector: kAudioDevicePropertyDeviceNameCFString) ?? "Unknown"
            let uid = stringProperty(deviceID, selector: kAudioDevicePropertyDeviceUID) ?? "\(deviceID)"
            devices.append(AudioInputDevice(id: deviceID, uid: uid, name: name))
        }
        return devices
    }

    /// The system default input device, if resolvable.
    static func systemDefault() -> AudioInputDevice? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var deviceID = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &deviceID
        ) == noErr, deviceID != 0 else { return nil }
        let name = stringProperty(deviceID, selector: kAudioDevicePropertyDeviceNameCFString) ?? "Default"
        let uid = stringProperty(deviceID, selector: kAudioDevicePropertyDeviceUID) ?? "\(deviceID)"
        return AudioInputDevice(id: deviceID, uid: uid, name: name)
    }

    private static func inputChannelCount(_ deviceID: AudioDeviceID) -> Int {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: kAudioDevicePropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        )
        var dataSize: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(deviceID, &address, 0, nil, &dataSize) == noErr,
              dataSize > 0 else { return 0 }
        let bufferListPointer = UnsafeMutableRawPointer.allocate(
            byteCount: Int(dataSize), alignment: MemoryLayout<AudioBufferList>.alignment
        )
        defer { bufferListPointer.deallocate() }
        guard AudioObjectGetPropertyData(deviceID, &address, 0, nil, &dataSize, bufferListPointer) == noErr else {
            return 0
        }
        let bufferList = bufferListPointer.assumingMemoryBound(to: AudioBufferList.self)
        let buffers = UnsafeMutableAudioBufferListPointer(bufferList)
        return buffers.reduce(0) { $0 + Int($1.mNumberChannels) }
    }

    private static func stringProperty(
        _ deviceID: AudioDeviceID,
        selector: AudioObjectPropertySelector
    ) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var unmanaged: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        let status = withUnsafeMutablePointer(to: &unmanaged) { pointer in
            AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, pointer)
        }
        guard status == noErr, let value = unmanaged?.takeRetainedValue() else { return nil }
        return value as String
    }
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

    /// UID of the input device to capture from. nil = system default.
    /// Set before `start()`; changing it while running requires a
    /// stop/start cycle (MeetingSession handles that).
    var preferredDeviceUID: String?

    func requestPermission() async -> Bool {
        await withCheckedContinuation { continuation in
            AVCaptureDevice.requestAccess(for: .audio) { granted in
                continuation.resume(returning: granted)
            }
        }
    }

    func start() throws {
        let input = engine.inputNode

        // Route the engine's input to the user-selected device when one
        // is chosen. This is how BlackHole (or any aggregate/virtual
        // device) gets selected without changing the system default.
        if let uid = preferredDeviceUID,
           let device = AudioInputDevice.availableInputs().first(where: { $0.uid == uid }) {
            var deviceID = device.id
            let audioUnit = input.audioUnit
            if let audioUnit {
                let status = AudioUnitSetProperty(
                    audioUnit,
                    kAudioOutputUnitProperty_CurrentDevice,
                    kAudioUnitScope_Global,
                    0,
                    &deviceID,
                    UInt32(MemoryLayout<AudioDeviceID>.size)
                )
                if status != noErr {
                    onError?("Couldn't switch to input device \(device.name) (error \(status)). Using system default.")
                }
            }
        }

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
