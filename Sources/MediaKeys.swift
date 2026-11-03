import Foundation

// MARK: - Media Keys
//
// Simulated via NX_KEYTYPE_* codes over the "systemDefined" CGEvent path.
// Requires the same Accessibility permission as regular key events.

enum MediaKeys {

    struct Entry {
        let name: String       // shown in the editor popup
        let label: String      // short glyph shown on the Touch Bar
        let nxKeyType: Int32   // NX_KEYTYPE_*
    }

    static let all: [Entry] = [
        Entry(name: "Volume Up",      label: "♪+",  nxKeyType: 0),   // NX_KEYTYPE_SOUND_UP
        Entry(name: "Volume Down",    label: "♪-",  nxKeyType: 1),   // NX_KEYTYPE_SOUND_DOWN
        Entry(name: "Mute",           label: "♪x",  nxKeyType: 7),   // NX_KEYTYPE_MUTE
        Entry(name: "Brightness Up",  label: "☀+",  nxKeyType: 2),   // NX_KEYTYPE_BRIGHTNESS_UP
        Entry(name: "Brightness Down",label: "☀-",  nxKeyType: 3),   // NX_KEYTYPE_BRIGHTNESS_DOWN
        Entry(name: "Play / Pause",   label: "⏯",  nxKeyType: 16),  // NX_KEYTYPE_PLAY
        Entry(name: "Next Track",     label: "⏭",  nxKeyType: 17),  // NX_KEYTYPE_NEXT
        Entry(name: "Previous Track", label: "⏮",  nxKeyType: 18),  // NX_KEYTYPE_PREVIOUS
    ]

    static func entry(named name: String) -> Entry? {
        all.first { $0.name == name }
    }

    static func defaultLabel(forValue value: String?) -> String {
        value.flatMap { entry(named: $0)?.label } ?? "♪"
    }
}
