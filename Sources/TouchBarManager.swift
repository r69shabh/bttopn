import Cocoa

// MARK: - Touch Bar Identifiers

private extension NSTouchBarItem.Identifier {
    static let controlStripItem = NSTouchBarItem.Identifier("com.bttopn.controlStrip")
    static let keyGroup = NSTouchBarItem.Identifier("com.bttopn.keyGroup")
}

// MARK: - Touch Bar Manager

class TouchBarManager: NSObject, NSTouchBarDelegate {

    private var configManager: ConfigManager
    private var touchBar: NSTouchBar?

    private var controlStripItem: NSCustomTouchBarItem?

    // Tracks whether the user has intentionally enabled the keys overlay.
    // We only auto-re-present when this is true.
    // Read-only externally so AppDelegate can sync menu title.
    private(set) var keysVisible: Bool = false

    // Timer used to debounce rapid app-switch events
    private var representTimer: Timer?

    init(configManager: ConfigManager) {
        self.configManager = configManager
        super.init()
        registerAppSwitchObserver()
    }

    deinit {
        NSWorkspace.shared.notificationCenter.removeObserver(self)
        NotificationCenter.default.removeObserver(self)
    }

    // MARK: - App-Switch Observer
    //
    // When any other app becomes frontmost, macOS automatically dismisses our
    // system-modal Touch Bar. We watch for that event and, if the user had the
    // keys visible, we re-present the bar after a short delay so it stays put
    // even inside Raycast, Spotlight, or any other launcher.

    private func registerAppSwitchObserver() {
        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(activeAppChanged(_:)),
            name: NSWorkspace.didActivateApplicationNotification,
            object: nil
        )
    }

    @objc private func activeAppChanged(_ notification: Notification) {
        guard keysVisible else { return }

        // Determine the newly active app
        let activeApp = notification.userInfo?[NSWorkspace.applicationUserInfoKey]
            as? NSRunningApplication
        let activeBundleID = activeApp?.bundleIdentifier ?? ""

        // Don't fight ourselves — if bttopn somehow becomes active, skip
        let ownBundleID = Bundle.main.bundleIdentifier ?? "com.personal.bttopn"
        if activeBundleID == ownBundleID { return }

        // Cancel any pending re-present
        representTimer?.invalidate()

        // Wait 80ms — just enough for the OS transition to settle before we
        // re-assert. Too short and we race with TouchBarServer; too long and
        // the user sees the default bar for a noticeable moment.
        representTimer = Timer.scheduledTimer(withTimeInterval: 0.08, repeats: false) { [weak self] _ in
            DispatchQueue.main.async {
                self?.repaintTouchBar()
            }
        }
    }

    // Re-presents the Touch Bar without toggling keysVisible state.
    //
    // KEY INSIGHT for no-jerk behaviour:
    // macOS has already dismissed our modal by the time this runs.
    // Calling dismissSystemModalTouchBar here would add a second blank frame
    // (dismiss → blank → present) causing the visible "jerk".
    // Instead we just re-assert the same cached NSTouchBar object directly
    // (blank → present), which is one transition instead of two.
    private func repaintTouchBar() {
        guard keysVisible else { return }

        // Reuse the cached bar if it still exists; only allocate a new one
        // if this is the very first present or after a user-initiated dismiss.
        if touchBar == nil {
            let tb = NSTouchBar()
            tb.delegate = self
            tb.defaultItemIdentifiers = [.keyGroup]
            self.touchBar = tb
        }

        // Do NOT call dismissSystemModalTouchBar here — macOS already did
        // that when the other app took focus. Adding another dismiss just
        // creates an extra blank frame, which is the "jerk" the user sees.
        DFRSystemModalShowsCloseBoxWhenFrontMost(false)
        NSTouchBar.presentSystemModalTouchBar(touchBar!, placement: 0,
                                               systemTrayItemIdentifier: nil)
        showControlStripIcon()
    }

    // MARK: - Control Strip Icon
    //
    // Adds a persistent ⌨️ icon in the Control Strip.
    // Tap it to toggle the custom keys.

    func showControlStripIcon() {
        if controlStripItem == nil {
            let item = NSCustomTouchBarItem(identifier: .controlStripItem)

            let image = NSImage(systemSymbolName: "keyboard",
                                accessibilityDescription: "bttopn")

            let button: NSButton
            if let img = image {
                button = NSButton(image: img, target: self, action: #selector(controlStripTapped))
            } else {
                button = NSButton(title: "⌨", target: self, action: #selector(controlStripTapped))
            }
            item.view = button
            self.controlStripItem = item
            NSTouchBarItem.addSystemTrayItem(item)
        }
        
        DFRElementSetControlStripPresenceForIdentifier(.controlStripItem, true)
    }

    @objc private func controlStripTapped() {
        toggleTouchBar()
    }

    // MARK: - Present / Dismiss

    func presentTouchBar() {
        // On an explicit user-initiated show, always build a fresh bar so any
        // config changes (from Edit Keys) are reflected immediately.
        if let existing = touchBar {
            NSTouchBar.dismissSystemModalTouchBar(existing)
        }

        let tb = NSTouchBar()
        tb.delegate = self
        tb.defaultItemIdentifiers = [.keyGroup]
        self.touchBar = tb

        // Hide the native macOS ✕ close box on the left.
        // Our ⌨️ stays in the Control Strip and acts as the toggle.
        DFRSystemModalShowsCloseBoxWhenFrontMost(false)
        NSTouchBar.presentSystemModalTouchBar(tb, placement: 0,
                                               systemTrayItemIdentifier: nil)

        keysVisible = true

        // Ensure the control strip icon stays visible and active
        showControlStripIcon()
    }

    func dismissTouchBar() {
        keysVisible = false
        representTimer?.invalidate()
        representTimer = nil

        if let tb = touchBar {
            NSTouchBar.dismissSystemModalTouchBar(tb)
        }
        // Nil out the cached bar so the next presentTouchBar() builds fresh
        touchBar = nil

        // Ensure the control strip icon stays visible
        showControlStripIcon()
    }

    func toggleTouchBar() {
        if keysVisible {
            dismissTouchBar()
        } else {
            presentTouchBar()
        }
    }

    /// Rebuild after config change
    func rebuild() {
        if keysVisible {
            presentTouchBar()
        }
    }

    // MARK: - NSTouchBarDelegate

    func touchBar(_ touchBar: NSTouchBar,
                  makeItemForIdentifier identifier: NSTouchBarItem.Identifier) -> NSTouchBarItem? {

        guard identifier == .keyGroup else { return nil }

        let item = NSCustomTouchBarItem(identifier: identifier)

        // Build all key buttons in a horizontal stack with zero spacing
        let stack = NSStackView()
        stack.orientation = .horizontal
        stack.spacing = 2

        for keyMapping in configManager.config.keys {
            let button = NSButton(title: keyMapping.label, target: self, action: #selector(keyButtonTapped(_:)))
            button.tag = keyMapping.keyCode
            button.font = NSFont.monospacedSystemFont(ofSize: 14, weight: .medium)

            // Width: text width + 24pt padding (12pt each side), minimum 40pt
            let textWidth = (keyMapping.label as NSString)
                .size(withAttributes: [.font: button.font!]).width
            let btnWidth = ceil(textWidth) + 24
            button.widthAnchor.constraint(equalToConstant: max(btnWidth, 40)).isActive = true

            stack.addArrangedSubview(button)
        }

        item.view = stack
        return item
    }

    // MARK: - Actions

    @objc private func keyButtonTapped(_ sender: NSButton) {
        let keyCode = CGKeyCode(sender.tag)
        KeySimulator.simulateKeyPress(keyCode: keyCode)
    }
}
