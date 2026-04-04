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

    /// Check if the app has Accessibility permissions (required for CGEvent posting).
    /// If `promptUser` is true, shows the system permission dialog.
    static func checkAccessibility(promptUser: Bool = true) -> Bool {
        let options: [String: Any] = [
            kAXTrustedCheckOptionPrompt.takeRetainedValue() as String: promptUser
        ]
        return AXIsProcessTrustedWithOptions(options as CFDictionary)
    }
}
