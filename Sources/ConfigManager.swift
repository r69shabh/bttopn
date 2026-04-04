import Foundation

// MARK: - Config Data Model

struct KeyMapping: Codable {
    var label: String
    var keyCode: Int
}

struct KeyConfig: Codable {
    var keys: [KeyMapping]
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
            let decoder = JSONDecoder()
            let loaded = try decoder.decode(KeyConfig.self, from: data)
            self.config = loaded
            return loaded
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
