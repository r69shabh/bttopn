import Carbon
import Cocoa

// MARK: - Global Hotkeys
//
// Registers system-wide hotkeys via Carbon's RegisterEventHotKey — no
// Accessibility permission required and works while bttopn is an
// accessory (LSUIElement) app. Supports multiple bindings keyed by id.

final class HotKeyManager {

    static let shared = HotKeyManager()

    private var handlerRef: EventHandlerRef?
    private var hotKeys: [UInt32: (ref: EventHotKeyRef, handler: () -> Void)] = [:]

    private init() {}

    /// Register a global hotkey. `id` must be unique per binding.
    func register(id: UInt32,
                  keyCode: UInt32,
                  modifiers: UInt32,
                  handler: @escaping () -> Void) {
        installHandlerIfNeeded()

        let hotKeyID = EventHotKeyID(signature: OSType(0x6274746F), id: id) // 'btto'
        var ref: EventHotKeyRef?
        let status = RegisterEventHotKey(keyCode, modifiers, hotKeyID,
                                         GetApplicationEventTarget(), 0, &ref)
        guard status == noErr, let ref = ref else {
            NSLog("bttopn: RegisterEventHotKey(id: \(id)) failed with status \(status)")
            return
        }
        hotKeys[id] = (ref, handler)
    }

    func unregisterAll() {
        for (_, entry) in hotKeys {
            UnregisterEventHotKey(entry.ref)
        }
        hotKeys.removeAll()
        if let handlerRef = handlerRef {
            RemoveEventHandler(handlerRef)
            self.handlerRef = nil
        }
    }

    deinit { unregisterAll() }

    // MARK: - Carbon event handler

    private func installHandlerIfNeeded() {
        guard handlerRef == nil else { return }

        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                      eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, userData -> OSStatus in
            guard let event = event, let userData = userData else { return OSStatus(eventNotHandledErr) }

            var hotKeyID = EventHotKeyID()
            let status = GetEventParameter(event,
                                           EventParamName(kEventParamDirectObject),
                                           EventParamType(typeEventHotKeyID),
                                           nil,
                                           MemoryLayout<EventHotKeyID>.size,
                                           nil,
                                           &hotKeyID)
            guard status == noErr else { return OSStatus(eventNotHandledErr) }

            let manager = Unmanaged<HotKeyManager>.fromOpaque(userData).takeUnretainedValue()
            DispatchQueue.main.async {
                manager.hotKeys[hotKeyID.id]?.handler()
            }
            return noErr
        }, 1, &eventType, Unmanaged.passUnretained(self).toOpaque(), &handlerRef)
    }
}
