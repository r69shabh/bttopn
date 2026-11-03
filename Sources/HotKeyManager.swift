import Carbon
import Cocoa

// MARK: - Global Hotkey
//
// Registers ⌃⌥⌘B system-wide to toggle the Touch Bar keys.
// Uses Carbon's RegisterEventHotKey — no extra permissions required and it
// works while bttopn is an accessory (LSUIElement) app.

final class HotKeyManager {

    static let shared = HotKeyManager()

    private var hotKeyRef: EventHotKeyRef?
    private var handlerRef: EventHandlerRef?
    var onToggle: (() -> Void)?

    private init() {}

    func register(keyCode: UInt32 = UInt32(kVK_ANSI_B),
                  modifiers: UInt32 = UInt32(cmdKey | optionKey | controlKey)) {
        guard hotKeyRef == nil else { return }

        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                      eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, _, userData -> OSStatus in
            guard let userData = userData else { return noErr }
            let manager = Unmanaged<HotKeyManager>.fromOpaque(userData).takeUnretainedValue()
            DispatchQueue.main.async { manager.onToggle?() }
            return noErr
        }, 1, &eventType, Unmanaged.passUnretained(self).toOpaque(), &handlerRef)

        let hotKeyID = EventHotKeyID(signature: OSType(0x6274746F), id: 1) // 'btto'
        RegisterEventHotKey(keyCode, modifiers, hotKeyID, GetApplicationEventTarget(), 0, &hotKeyRef)
    }

    func unregister() {
        if let ref = hotKeyRef { UnregisterEventHotKey(ref) }
        hotKeyRef = nil
        if let ref = handlerRef { RemoveEventHandler(ref) }
        handlerRef = nil
    }

    deinit { unregister() }
}
