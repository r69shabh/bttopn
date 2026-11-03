import Cocoa

// MARK: - App Launcher
//
// Enumerates installed applications for the Action Palette. Local file
// system scan only — no Spotlight/mdfind dependency. Shallow scan of the
// standard app directories (plus ONE level of folders inside /Applications,
// e.g. /Applications/Setapp/Foo.app).

struct AppEntry {
    let name: String
    let url: URL
}

enum AppLauncher {

    private static let appDirectories = [
        "/Applications",
        "/Applications/Utilities",
        "/System/Applications",
        "/System/Applications/Utilities",
        NSHomeDirectory() + "/Applications",
    ]

    static func list() -> [AppEntry] {
        let fm = FileManager.default
        var apps: [AppEntry] = []
        var seen = Set<String>()

        func add(_ url: URL) {
            let key = url.standardizedFileURL.path
            guard seen.insert(key).inserted else { return }
            apps.append(AppEntry(name: url.deletingPathExtension().lastPathComponent, url: url))
        }

        for dir in appDirectories {
            guard let items = try? fm.contentsOfDirectory(at: URL(fileURLWithPath: dir),
                                                          includingPropertiesForKeys: nil,
                                                          options: [.skipsHiddenFiles]) else { continue }
            for item in items where item.pathExtension == "app" {
                add(item)
            }
        }

        // One level of nesting inside /Applications (Setapp-style folders)
        let applicationsDir = URL(fileURLWithPath: "/Applications")
        if let topLevel = try? fm.contentsOfDirectory(at: applicationsDir,
                                                      includingPropertiesForKeys: [.isDirectoryKey],
                                                      options: [.skipsHiddenFiles]) {
            for item in topLevel where (try? item.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true {
                guard let nested = try? fm.contentsOfDirectory(at: item,
                                                               includingPropertiesForKeys: nil,
                                                               options: [.skipsHiddenFiles]) else { continue }
                for app in nested where app.pathExtension == "app" {
                    add(app)
                }
            }
        }

        return apps.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    static func launch(_ entry: AppEntry) {
        if let bundleID = Bundle(url: entry.url)?.bundleIdentifier,
           let running = NSWorkspace.shared.runningApplications.first(where: { $0.bundleIdentifier == bundleID }) {
            running.activate()
            return
        }
        NSWorkspace.shared.openApplication(at: entry.url,
                                           configuration: NSWorkspace.OpenConfiguration()) { _, error in
            if let error = error { NSLog("bttopn: failed to launch \(entry.name): \(error)") }
        }
    }
}
