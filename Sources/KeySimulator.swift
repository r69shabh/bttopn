import Cocoa

/// Simulates keyboard key presses using CGEvent API.
/// Reads current modifier state so physical Cmd/Shift/etc. work with Touch Bar buttons.
enum KeySimulator {

    /// Simulate a single key press (down + up) for the given virtual key code.
    /// Automatically includes any currently-held physical modifier keys.
    static func simulateKeyPress(keyCode: CGKeyCode) {
        let source = CGEventSource(stateID: .hidSystemState)

        // Read the current physical modifier state (Shift, Cmd, Option, Control)
        let currentFlags = CGEventSource.flagsState(.hidSystemState)

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
