import Cocoa

// MARK: - Built-in System Actions
//
// Ready-to-use actions for the Action Palette so it's useful out of the
// box — works on every Mac, no configuration required. All are local,
// reversible system operations; nothing destructive.

enum SystemActions {

    struct BuiltIn {
        let id: String      // stable identifier for MRU, e.g. "window-left-half"
        let title: String   // shown in the palette
        let detail: String  // subtitle, always "System · …"
        let run: () -> Void
    }

    private static func snap(_ id: String, _ title: String, _ name: String) -> BuiltIn {
        BuiltIn(id: id, title: title, detail: "System · Window Snap · \(name)") {
            WindowManager.snap(name)
        }
    }

    private static func media(_ name: String) -> BuiltIn {
        BuiltIn(id: "media-\(name.lowercased().replacingOccurrences(of: " ", with: "-"))",
                title: name,
                detail: "System · Media Key · \(name)") {
            KeySimulator.simulateMediaKey(name)
        }
    }

    private static func keyStroke(_ id: String, _ title: String, _ keyCode: CGKeyCode, _ modifiers: [String]) -> BuiltIn {
        BuiltIn(id: id, title: title, detail: "System · Keyboard Shortcut") {
            KeySimulator.simulateKeyPress(keyCode: keyCode, modifiers: modifiers)
        }
    }

    private static func shell(_ id: String, _ title: String, _ command: String) -> BuiltIn {
        BuiltIn(id: id, title: title, detail: "System · Shell · \(command)") {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/sh")
            process.arguments = ["-c", command]
            try? process.run()
        }
    }

    static let all: [BuiltIn] = [
        // Window management
        snap("window-left-half",  "Snap Window Left Half",  "Left Half"),
        snap("window-right-half", "Snap Window Right Half", "Right Half"),
        snap("window-left-third", "Snap Window Left Third", "Left Third"),
        snap("window-right-third","Snap Window Right Third","Right Third"),
        snap("window-maximize",   "Maximize Window",        "Maximize"),
        snap("window-center",     "Center Window",          "Center"),

        // Media keys
        media("Volume Up"),
        media("Volume Down"),
        media("Mute"),
        media("Brightness Up"),
        media("Brightness Down"),
        media("Play / Pause"),
        media("Next Track"),
        media("Previous Track"),

        // Screenshots (triggers the macOS screenshot UI)
        keyStroke("screenshot-region", "Screenshot: Select Area", 0x15, ["cmd", "shift"]),  // ⌘⇧4
        keyStroke("screenshot-full",   "Screenshot: Full Screen", 0x14, ["cmd", "shift"]),  // ⌘⇧3

        // System
        keyStroke("lock-screen", "Lock Screen", 0x0C, ["control", "cmd"]),                // ⌃⌘Q
        keyStroke("force-quit",  "Force Quit…", 0x35, ["cmd", "option"]),                 // ⌘⌥⎋
        shell("sleep-display", "Sleep Display", "pmset displaysleepnow"),
        shell("toggle-dark-mode", "Toggle Dark Mode",
              "osascript -e 'tell application \"System Events\" to tell appearance preferences to set dark mode to not dark mode'"),
    ]
}
