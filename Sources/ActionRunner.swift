import Cocoa

// MARK: - Action Runner

enum ActionRunner {

    static func run(_ mapping: KeyMapping) {
        switch mapping.action {
        case .key:
            KeySimulator.simulateKeyPress(keyCode: CGKeyCode(mapping.keyCode))
        case .mediaKey:
            KeySimulator.simulateMediaKey(mapping.value ?? "")
        case .launchApp:
            launchApp(bundleID: mapping.value)
        case .openURL:
            openURL(mapping.value)
        case .shell:
            runShell(mapping.value)
        case .windowSnap:
            WindowManager.snap(mapping.value ?? "")
        }
    }

    private static func launchApp(bundleID: String?) {
        guard let bundleID = bundleID, !bundleID.isEmpty else { return }

        if let app = NSWorkspace.shared.runningApplications.first(where: { $0.bundleIdentifier == bundleID }) {
            app.activate()
            return
        }
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else {
            NSLog("bttopn: no application found for bundle id \(bundleID)")
            return
        }
        NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration()) { _, error in
            if let error = error { NSLog("bttopn: failed to launch \(bundleID): \(error)") }
        }
    }

    private static func openURL(_ value: String?) {
        guard let value = value, let url = URL(string: value) else { return }
        NSWorkspace.shared.open(url)
    }

    private static func runShell(_ command: String?) {
        guard let command = command, !command.isEmpty else { return }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", command]
        do {
            try process.run()
        } catch {
            NSLog("bttopn: shell command failed: \(error)")
        }
    }
}
