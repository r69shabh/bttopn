import Foundation

// Lightweight assert-based checks for the v1 → v2 config schema migration
// and per-app profile resolution. Run via ./test.sh

@main
struct ConfigTest {

    static var failures = 0

    static func check(_ condition: Bool, _ name: String) {
        if condition {
            print("PASS  \(name)")
        } else {
            failures += 1
            print("FAIL  \(name)")
        }
    }

    static func main() {
        // 1. Legacy v1 config (no action / value / profiles) decodes with defaults
        let legacyJSON = """
        {
          "keys": [
            { "label": "9", "keyCode": 25 },
            { "label": "O", "keyCode": 31 }
          ]
        }
        """.data(using: .utf8)!

        do {
            let config = try JSONDecoder().decode(KeyConfig.self, from: legacyJSON)
            check(config.keys.count == 2, "legacy: key count")
            check(config.keys[0].action == .key, "legacy: action defaults to .key")
            check(config.keys[0].keyCode == 25, "legacy: keyCode preserved")
            check(config.keys[0].value == nil, "legacy: value defaults to nil")
            check(config.keys[0].modifiers == nil, "legacy: modifiers default to nil")
            check(config.profiles.isEmpty, "legacy: profiles default to empty")
        } catch {
            failures += 1
            print("FAIL  legacy: decode threw \(error)")
        }

        // 2. v2 round-trip: encode → decode is lossless
        let original = KeyConfig(keys: [
            KeyMapping(label: "9", keyCode: 25),
            KeyMapping(label: "Vol+", keyCode: 0, action: .mediaKey, value: "Volume Up"),
            KeyMapping(label: "Calc", keyCode: 0, action: .launchApp, value: "com.apple.Calculator"),
            KeyMapping(label: "GitHub", keyCode: 0, action: .openURL, value: "https://github.com"),
            KeyMapping(label: "🍺", keyCode: 0, action: .shell, value: "echo hi"),
            KeyMapping(label: "Left ½", keyCode: 0, action: .windowSnap, value: "Left Half"),
            KeyMapping(label: "Undo", keyCode: 0x06, modifiers: ["cmd"]),
            KeyMapping(label: "Paste", keyCode: 0x09, modifiers: ["cmd", "shift"]),
        ], profiles: [
            AppProfile(bundleID: "com.raycast.macos", name: "Raycast",
                       keys: [KeyMapping(label: "Enter", keyCode: 0x24)]),
        ])

        do {
            let data = try JSONEncoder().encode(original)
            let decoded = try JSONDecoder().decode(KeyConfig.self, from: data)
            check(decoded == original, "v2: encode/decode round-trip")
        } catch {
            failures += 1
            print("FAIL  v2: round-trip threw \(error)")
        }

        // 3. Profile resolution: matching bundleID wins, unknown falls back to default
        let config = KeyConfig(keys: [KeyMapping(label: "D", keyCode: 1)], profiles: [
            AppProfile(bundleID: "com.raycast.macos", name: "Raycast",
                       keys: [KeyMapping(label: "R", keyCode: 15)]),
        ])
        check(config.keys(forBundleID: "com.raycast.macos").map { $0.label } == ["R"],
              "profiles: matching app gets profile keys")
        check(config.keys(forBundleID: "com.apple.Safari").map { $0.label } == ["D"],
              "profiles: unknown app falls back to default")
        check(config.keys(forBundleID: nil).map { $0.label } == ["D"],
              "profiles: nil bundleID falls back to default")
        check(config.contextID(forBundleID: "com.raycast.macos") == "profile:com.raycast.macos",
              "profiles: contextID for profile")
        check(config.contextID(forBundleID: "com.apple.Safari") == "default",
              "profiles: contextID for unknown app")

        // 4. Partial/malformed entries don't nuke the whole file
        let partialJSON = """
        {
          "keys": [
            { "label": "Good", "keyCode": 4 },
            { "label": "NoAction" }
          ],
          "profiles": [
            { "bundleID": "com.example.app", "keys": [{ "label": "P", "keyCode": 15 }] }
          ]
        }
        """.data(using: .utf8)!

        do {
            let config = try JSONDecoder().decode(KeyConfig.self, from: partialJSON)
            check(config.keys.count == 2, "partial: both keys decode")
            check(config.keys[1].action == .key && config.keys[1].keyCode == 0,
                  "partial: missing keyCode/action fall back")
            check(config.profiles[0].name == "com.example.app",
                  "partial: missing profile name falls back to bundleID")
        } catch {
            failures += 1
            print("FAIL  partial: decode threw \(error)")
        }

        // 5. Clipboard filter: concealed/transient pasteboards never stored
        check(ClipboardFilter.shouldStore(types: ["public.utf8-plain-text"], text: "hello"),
              "clipboard: plain text stored")
        check(!ClipboardFilter.shouldStore(types: ["public.utf8-plain-text", "org.nspasteboard.ConcealedType"], text: "hunter2"),
              "clipboard: concealed (1Password) rejected")
        check(!ClipboardFilter.shouldStore(types: ["org.nspasteboard.TransientType"], text: "temp"),
              "clipboard: transient rejected")
        check(!ClipboardFilter.shouldStore(types: ["org.nspasteboard.AutoGeneratedType"], text: "generated"),
              "clipboard: auto-generated rejected")
        check(!ClipboardFilter.shouldStore(types: ["public.utf8-plain-text"], text: "   \n  "),
              "clipboard: whitespace-only rejected")
        check(!ClipboardFilter.shouldStore(types: ["public.utf8-plain-text"],
                                             text: String(repeating: "x", count: ClipboardFilter.maxTextLength + 1)),
              "clipboard: oversized blob rejected")

        if failures > 0 {
            print("\n\(failures) test(s) failed")
            exit(1)
        }
        print("\nAll config tests passed")
        exit(0)
    }
}
