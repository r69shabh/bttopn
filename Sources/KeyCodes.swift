import Cocoa

// MARK: - Key Code Entry

struct KeyCodeEntry {
    let name: String
    let code: Int
    let category: String
}

// MARK: - Key Codes Database

enum KeyCodes {

    // All supported key codes organized by category
    static let allKeys: [KeyCodeEntry] = {
        var keys: [KeyCodeEntry] = []

        // Letters
        let letters: [(String, Int)] = [
            ("A", 0x00), ("B", 0x0B), ("C", 0x08), ("D", 0x02), ("E", 0x0E),
            ("F", 0x03), ("G", 0x05), ("H", 0x04), ("I", 0x22), ("J", 0x26),
            ("K", 0x28), ("L", 0x25), ("M", 0x2E), ("N", 0x2D), ("O", 0x1F),
            ("P", 0x23), ("Q", 0x0C), ("R", 0x0F), ("S", 0x01), ("T", 0x11),
            ("U", 0x20), ("V", 0x09), ("W", 0x0D), ("X", 0x07), ("Y", 0x10),
            ("Z", 0x06)
        ]
        keys += letters.map { KeyCodeEntry(name: $0.0, code: $0.1, category: "Letters") }

        // Numbers
        let numbers: [(String, Int)] = [
            ("0", 0x1D), ("1", 0x12), ("2", 0x13), ("3", 0x14), ("4", 0x15),
            ("5", 0x17), ("6", 0x16), ("7", 0x1A), ("8", 0x1C), ("9", 0x19)
        ]
        keys += numbers.map { KeyCodeEntry(name: $0.0, code: $0.1, category: "Numbers") }

        // Symbols
        let symbols: [(String, Int)] = [
            ("Period", 0x2F), ("Comma", 0x2B), ("Minus", 0x1B), ("Equal", 0x18),
            ("Semicolon", 0x29), ("Quote", 0x27), ("Slash", 0x2C),
            ("Backslash", 0x2A), ("Left Bracket", 0x21), ("Right Bracket", 0x1E),
            ("Grave/Tilde", 0x32)
        ]
        keys += symbols.map { KeyCodeEntry(name: $0.0, code: $0.1, category: "Symbols") }

        // Navigation
        let nav: [(String, Int)] = [
            ("Up Arrow", 0x7E), ("Down Arrow", 0x7D),
            ("Left Arrow", 0x7B), ("Right Arrow", 0x7C),
            ("Home", 0x73), ("End", 0x77),
            ("Page Up", 0x74), ("Page Down", 0x79)
        ]
        keys += nav.map { KeyCodeEntry(name: $0.0, code: $0.1, category: "Navigation") }

        // Special
        let special: [(String, Int)] = [
            ("Space", 0x31), ("Return", 0x24), ("Tab", 0x30),
            ("Delete", 0x33), ("Forward Delete", 0x75), ("Escape", 0x35)
        ]
        keys += special.map { KeyCodeEntry(name: $0.0, code: $0.1, category: "Special") }

        // Function Keys
        let fkeys: [(String, Int)] = [
            ("F1", 0x7A), ("F2", 0x78), ("F3", 0x63), ("F4", 0x76),
            ("F5", 0x60), ("F6", 0x61), ("F7", 0x62), ("F8", 0x64),
            ("F9", 0x65), ("F10", 0x6D), ("F11", 0x67), ("F12", 0x6F)
        ]
        keys += fkeys.map { KeyCodeEntry(name: $0.0, code: $0.1, category: "Function Keys") }

        return keys
    }()

    static let categories = ["Letters", "Numbers", "Symbols", "Navigation", "Special", "Function Keys"]

    /// Look up key name by code
    static func name(for keyCode: Int) -> String {
        return allKeys.first { $0.code == keyCode }?.name ?? "Key \(keyCode)"
    }

    /// Look up key code by name
    static func code(for name: String) -> Int? {
        return allKeys.first { $0.name == name }?.code
    }

    /// Default label for a key (short display name for Touch Bar)
    static func defaultLabel(for keyCode: Int) -> String {
        let labelMap: [Int: String] = [
            0x31: "␣", 0x24: "⏎", 0x33: "⌫", 0x75: "⌦", 0x35: "⎋", 0x30: "⇥",
            0x7E: "↑", 0x7D: "↓", 0x7B: "←", 0x7C: "→",
            0x2F: ".", 0x2B: ",", 0x1B: "-", 0x18: "=",
            0x29: ";", 0x27: "'", 0x2C: "/", 0x2A: "\\",
            0x21: "[", 0x1E: "]", 0x32: "`"
        ]
        if let special = labelMap[keyCode] { return special }
        return name(for: keyCode)
    }
}
