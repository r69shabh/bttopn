import Cocoa

/// Simulates keyboard key presses using CGEvent API.
/// Reads current modifier state so physical Cmd/Shift/etc. work with Touch Bar buttons.
enum KeySimulator {

    /// Mapping from config modifier names to CGEventFlags.
    static let modifierFlags: [String: CGEventFlags] = [
        "cmd": .maskCommand, "shift": .maskShift, "option": .maskAlternate, "control": .maskControl,
    ]

    /// Simulate a single key press (down + up) for the given virtual key code.
    /// Combines physically-held modifier keys with any static `modifiers`
    /// from the mapping (e.g. per-key "always Cmd" for one-tap undo).
    static func simulateKeyPress(keyCode: CGKeyCode, modifiers: [String] = []) {
        let source = CGEventSource(stateID: .hidSystemState)

        // Physically held modifiers, unioned with the mapping's static ones
        var flags = CGEventSource.flagsState(.hidSystemState)
        for name in modifiers {
            if let mask = modifierFlags[name] { flags.insert(mask) }
        }
        let currentFlags = flags

        // Key Down
        guard let keyDown = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: true) else {
            print("TouchBarKeys: Failed to create key down event for code \(keyCode)")
            return
        }
        keyDown.flags = currentFlags
        keyDown.post(tap: .cghidEventTap)

        // Small delay for apps that process key down before key up
        usleep(8000) // 8ms

        // Key Up
        guard let keyUp = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: false) else {
            print("TouchBarKeys: Failed to create key up event for code \(keyCode)")
            return
        }
        keyUp.flags = currentFlags
        keyUp.post(tap: .cghidEventTap)
    }

    /// Simulate a system media key (volume, brightness, play/pause, …).
    /// Uses the systemDefined CGEvent path with NX_KEYTYPE_* codes; the
    /// Touch Bar can't send these as normal key events.
    static func simulateMediaKey(_ name: String) {
        guard let entry = MediaKeys.entry(named: name) else {
            print("bttopn: unknown media key '\(name)'")
            return
        }
        for isDown in [true, false] {
            let flags = isDown
                ? NSEvent.ModifierFlags(rawValue: 0xA00)
                : NSEvent.ModifierFlags(rawValue: 0xB00)
            let data1 = Int(entry.nxKeyType) << 16 | (isDown ? 0x0A00 : 0x0B00)
            guard let event = NSEvent.otherEvent(
                with: .systemDefined,
                location: .zero,
                modifierFlags: flags,
                timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: 0,
                context: nil,
                subtype: 8,
                data1: data1,
                data2: -1
            ) else { continue }
            event.cgEvent?.post(tap: .cghidEventTap)
            usleep(8000) // 8ms between down/up, mirrors simulateKeyPress
        }
    }

    /// Check if the app has Accessibility permissions (required for CGEvent posting).
    /// If `promptUser` is true, shows the system permission dialog.
    static func checkAccessibility(promptUser: Bool = true) -> Bool {
        let options: [String: Any] = [
            kAXTrustedCheckOptionPrompt.takeRetainedValue() as String: promptUser
        ]
        return AXIsProcessTrustedWithOptions(options as CFDictionary)
    }
}
