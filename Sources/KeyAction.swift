import Foundation

// MARK: - Key Actions
//
// What a Touch Bar button does. Every mapping carries an action;
// legacy configs without an action decode as "key" (see KeyMapping).
// Kept free of Cocoa so the config layer stays unit-testable.

enum KeyAction: String, Codable {
    case key        // simulate a virtual key code (honours physical modifiers)
    case mediaKey   // system media/volume/brightness key via NX_KEYTYPE_*
    case launchApp  // open an app by bundle identifier
    case openURL    // open a URL in the default browser
    case shell      // run a shell command via /bin/sh in the background

    var displayName: String {
        switch self {
        case .key:       return "Key Press"
        case .mediaKey:  return "Media Key"
        case .launchApp: return "Launch App"
        case .openURL:   return "Open URL"
        case .shell:     return "Shell Command"
        }
    }

    static let allCasesInMenu: [KeyAction] = [.key, .mediaKey, .launchApp, .openURL, .shell]
}
