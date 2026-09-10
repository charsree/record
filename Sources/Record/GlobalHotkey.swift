import AppKit
import Carbon.HIToolbox
import Foundation

/// Registers a single system-wide hotkey (default ⌘⌥R) that fires
/// `onTrigger` on the main queue. macOS-native — no accessibility permission
/// required; the process just needs to be running.
///
/// One hotkey per instance. Deregisters on `deinit`.
final class GlobalHotkey: @unchecked Sendable {
    private var handlerRef: EventHandlerRef?
    private var hotKeyRef: EventHotKeyRef?
    private let onTrigger: @Sendable () -> Void
    private let identifier: UInt32

    /// Registry of live instances so the C event handler can look one up by id.
    /// Guarded by `registryLock`.
    private static let registryLock = NSLock()
    private nonisolated(unsafe) static var instances: [UInt32: GlobalHotkey] = [:]
    private nonisolated(unsafe) static var nextIdentifier: UInt32 = 0x52454331 // 'REC1'

    init(keyCode: UInt32 = UInt32(kVK_ANSI_R),
         modifiers: UInt32 = UInt32(cmdKey | optionKey),
         onTrigger: @escaping @Sendable () -> Void) {
        self.onTrigger = onTrigger
        Self.registryLock.lock()
        Self.nextIdentifier += 1
        self.identifier = Self.nextIdentifier
        Self.instances[identifier] = self
        Self.registryLock.unlock()
        register(keyCode: keyCode, modifiers: modifiers)
    }

    deinit {
        if let handlerRef {
            RemoveEventHandler(handlerRef)
        }
        if let hotKeyRef {
            UnregisterEventHotKey(hotKeyRef)
        }
        Self.registryLock.lock()
        Self.instances[identifier] = nil
        Self.registryLock.unlock()
    }

    private func register(keyCode: UInt32, modifiers: UInt32) {
        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        InstallEventHandler(
            GetApplicationEventTarget(),
            { _, event, _ -> OSStatus in
                var hotkeyID = EventHotKeyID()
                let err = GetEventParameter(
                    event,
                    EventParamName(kEventParamDirectObject),
                    EventParamType(typeEventHotKeyID),
                    nil,
                    MemoryLayout<EventHotKeyID>.size,
                    nil,
                    &hotkeyID
                )
                guard err == noErr else { return err }
                GlobalHotkey.registryLock.lock()
                let instance = GlobalHotkey.instances[hotkeyID.id]
                GlobalHotkey.registryLock.unlock()
                if let instance {
                    let callback = instance.onTrigger
                    DispatchQueue.main.async { callback() }
                }
                return noErr
            },
            1,
            &eventType,
            nil,
            &handlerRef
        )

        let hotKeyID = EventHotKeyID(signature: OSType(0x52454344), id: identifier) // 'RECD'
        RegisterEventHotKey(
            keyCode,
            modifiers,
            hotKeyID,
            GetApplicationEventTarget(),
            0,
            &hotKeyRef
        )
    }
}
