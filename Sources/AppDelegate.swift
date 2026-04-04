import Cocoa

class AppDelegate: NSObject, NSApplicationDelegate {

    private var statusItem: NSStatusItem!
    private var configManager: ConfigManager!
    private var touchBarManager: TouchBarManager!
    private var editWindowController: EditKeysWindowController?

    // Menu items that need state updates
    private var toggleMenuItem: NSMenuItem!

    func applicationDidFinishLaunching(_ notification: Notification) {
        // 1. Check Accessibility permissions
        if !KeySimulator.checkAccessibility(promptUser: true) {
            let alert = NSAlert()
            alert.messageText = "Accessibility Permission Required"
            alert.informativeText = "bttopn needs Accessibility access to simulate key presses.\n\nGo to System Settings → Privacy & Security → Accessibility and enable bttopn.\n\nThe app will keep running — enable the permission and it will work automatically."
            alert.alertStyle = .warning
            alert.addButton(withTitle: "OK")
            alert.runModal()
        }

        // 2. Initialize managers
        configManager = ConfigManager()
        touchBarManager = TouchBarManager(configManager: configManager)

        // Rebuild touch bar on config changes
        configManager.onConfigChanged = { [weak self] in
            self?.touchBarManager.rebuild()
        }

        // 3. Set up menu bar
        setupStatusBar()

        // 4. Add ⌨️ icon to Control Strip (next to default brightness/volume/etc)
        touchBarManager.showControlStripIcon()
    }

    // Prevent app from quitting when Touch Bar overlay is dismissed
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        return false
    }

    // MARK: - Status Bar

    private func setupStatusBar() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "keyboard", accessibilityDescription: "bttopn")
                ?? {
                    // Fallback: text-based icon
                    let img = NSImage(size: NSSize(width: 18, height: 18))
                    img.lockFocus()
                    let str = "⌨" as NSString
                    str.draw(at: NSPoint(x: 1, y: 0),
                             withAttributes: [.font: NSFont.systemFont(ofSize: 14)])
                    img.unlockFocus()
                    return img
                }()
            button.image?.isTemplate = true
        }

        let menu = NSMenu()

        toggleMenuItem = NSMenuItem(title: "Hide Touch Bar", action: #selector(toggleTouchBar), keyEquivalent: "t")
        toggleMenuItem.target = self
        menu.addItem(toggleMenuItem)

        menu.addItem(NSMenuItem.separator())

        let editItem = NSMenuItem(title: "Edit Keys…", action: #selector(openEditWindow), keyEquivalent: "e")
        editItem.target = self
        menu.addItem(editItem)

        let reloadItem = NSMenuItem(title: "Reload Config", action: #selector(reloadConfig), keyEquivalent: "r")
        reloadItem.target = self
        menu.addItem(reloadItem)

        let configPathItem = NSMenuItem(title: "Show Config File", action: #selector(showConfigFile), keyEquivalent: "")
        configPathItem.target = self
        menu.addItem(configPathItem)

        menu.addItem(NSMenuItem.separator())

        let quitItem = NSMenuItem(title: "Quit bttopn", action: #selector(quitApp), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)

        statusItem.menu = menu
    }

    // MARK: - Actions

    @objc private func toggleTouchBar() {
        touchBarManager.toggleTouchBar()
        toggleMenuItem.title = toggleMenuItem.title == "Show Keys" ? "Hide Keys" : "Show Keys"
    }

    @objc private func openEditWindow() {
        if editWindowController == nil {
            editWindowController = EditKeysWindowController(configManager: configManager) { [weak self] in
                self?.touchBarManager.rebuild()
            }
        }
        editWindowController?.showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc private func reloadConfig() {
        configManager.reloadConfig()
    }

    @objc private func showConfigFile() {
        NSWorkspace.shared.selectFile(ConfigManager.configFile.path,
                                       inFileViewerRootedAtPath: ConfigManager.configDirectory.path)
    }

    @objc private func quitApp() {
        touchBarManager.dismissTouchBar()
        NSApp.terminate(nil)
    }
}
