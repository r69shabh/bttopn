import Foundation

// MARK: - Config Data Model
//
// Schema v2: every mapping carries an `action` (defaults to "key" so v1
// configs keep working) and the config may carry per-app `profiles`.
// Decoding is deliberately lenient — missing fields fall back to defaults.

struct KeyMapping: Codable, Equatable {
    var label: String
    var keyCode: Int
    var action: KeyAction
    var value: String?
    /// Static modifiers held while this key fires, e.g. ["cmd", "shift"].
    /// Combined with any physically held modifiers at trigger time.
    var modifiers: [String]?

    init(label: String, keyCode: Int, action: KeyAction = .key, value: String? = nil, modifiers: [String]? = nil) {
        self.label = label
        self.keyCode = keyCode
        self.action = action
        self.value = value
        self.modifiers = modifiers
    }

    enum CodingKeys: String, CodingKey { case label, keyCode, action, value, modifiers }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        label = try c.decodeIfPresent(String.self, forKey: .label) ?? "?"
        keyCode = try c.decodeIfPresent(Int.self, forKey: .keyCode) ?? 0
        action = try c.decodeIfPresent(KeyAction.self, forKey: .action) ?? .key
        value = try c.decodeIfPresent(String.self, forKey: .value)
        modifiers = try c.decodeIfPresent([String].self, forKey: .modifiers)
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(label, forKey: .label)
        try c.encode(keyCode, forKey: .keyCode)
        try c.encode(action, forKey: .action)
        try c.encodeIfPresent(value, forKey: .value)
        try c.encodeIfPresent(modifiers, forKey: .modifiers)
    }
}

struct AppProfile: Codable, Equatable {
    var bundleID: String
    var name: String
    var keys: [KeyMapping]

    enum CodingKeys: String, CodingKey { case bundleID, name, keys }

    init(bundleID: String, name: String, keys: [KeyMapping]) {
        self.bundleID = bundleID
        self.name = name
        self.keys = keys
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        bundleID = try c.decode(String.self, forKey: .bundleID)
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? bundleID
        keys = try c.decodeIfPresent([KeyMapping].self, forKey: .keys) ?? []
    }
}

struct KeyConfig: Codable, Equatable {
    var keys: [KeyMapping]
    var profiles: [AppProfile]

    enum CodingKeys: String, CodingKey { case keys, profiles }

    init(keys: [KeyMapping], profiles: [AppProfile] = []) {
        self.keys = keys
        self.profiles = profiles
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        keys = try c.decodeIfPresent([KeyMapping].self, forKey: .keys) ?? []
        profiles = try c.decodeIfPresent([AppProfile].self, forKey: .profiles) ?? []
    }

    /// Keys for the given frontmost app: its profile's keys if one matches,
    /// otherwise the default layout.
    func keys(forBundleID bundleID: String?) -> [KeyMapping] {
        if let bundleID = bundleID,
           let profile = profiles.first(where: { $0.bundleID == bundleID }) {
            return profile.keys
        }
        return keys
    }

    /// Stable identifier of which layout `keys(for:)` would resolve to.
    /// Used to detect when an app switch requires a rebuild.
    func contextID(forBundleID bundleID: String?) -> String {
        if let bundleID = bundleID,
           profiles.contains(where: { $0.bundleID == bundleID }) {
            return "profile:\(bundleID)"
        }
        return "default"
    }
}

// MARK: - Config Manager

class ConfigManager {

    static let configDirectory: URL = {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/bttopn")
    }()

    static let configFile: URL = {
        configDirectory.appendingPathComponent("keys.json")
    }()

    /// Currently loaded configuration
    private(set) var config: KeyConfig

    /// Callback invoked when config changes
    var onConfigChanged: (() -> Void)?

    init() {
        self.config = KeyConfig(keys: [])
        self.config = loadConfig()
    }

    // MARK: - Default Config (user's broken keys)

    static let defaultConfig = KeyConfig(keys: [
        KeyMapping(label: "9", keyCode: 0x19),
        KeyMapping(label: "O", keyCode: 0x1F),
        KeyMapping(label: "L", keyCode: 0x25),
        KeyMapping(label: ".", keyCode: 0x2F),
        KeyMapping(label: "-", keyCode: 0x1B),
        KeyMapping(label: "→", keyCode: 0x7C),
    ])

    // MARK: - Load

    func loadConfig() -> KeyConfig {
        let fm = FileManager.default

        // Create config directory if needed
        if !fm.fileExists(atPath: ConfigManager.configDirectory.path) {
            try? fm.createDirectory(at: ConfigManager.configDirectory,
                                     withIntermediateDirectories: true)
        }

        // If config file doesn't exist, create default
        if !fm.fileExists(atPath: ConfigManager.configFile.path) {
            saveConfig(ConfigManager.defaultConfig)
            return ConfigManager.defaultConfig
        }

        // Load from file
        do {
            let data = try Data(contentsOf: ConfigManager.configFile)
            let decoded = try JSONDecoder().decode(KeyConfig.self, from: data)
            self.config = decoded
            return decoded
        } catch {
            print("bttopn: Failed to load config: \(error). Using defaults.")
            return ConfigManager.defaultConfig
        }
    }

    // MARK: - Save

    @discardableResult
    func saveConfig(_ newConfig: KeyConfig) -> Bool {
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(newConfig)
            try data.write(to: ConfigManager.configFile, options: .atomic)
            self.config = newConfig
            return true
        } catch {
            print("bttopn: Failed to save config: \(error)")
            return false
        }
    }

    // MARK: - Reload

    func reloadConfig() {
        self.config = loadConfig()
        onConfigChanged?()
    }

    // MARK: - Update

    func updateConfig(_ newConfig: KeyConfig) {
        if saveConfig(newConfig) {
            onConfigChanged?()
        }
    }
}
