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

    init(configManager: ConfigManager) {
        self.configManager = configManager
        super.init()
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
        // Dismiss any stale modal
        if let existing = touchBar {
            NSTouchBar.dismissSystemModalTouchBar(existing)
        }

        // Build touch bar: just the key buttons, no custom close button
        let tb = NSTouchBar()
        tb.delegate = self
        tb.defaultItemIdentifiers = [.keyGroup]
        self.touchBar = tb

        // Hide the native macOS ✕ close box on the left.
        // Our ⌨️ stays in the Control Strip and acts as the toggle.
        DFRSystemModalShowsCloseBoxWhenFrontMost(false)
        NSTouchBar.presentSystemModalTouchBar(tb, placement: 0,
                                               systemTrayItemIdentifier: nil)
        
        // Ensure the control strip icon stays visible and active
        showControlStripIcon()
    }

    func dismissTouchBar() {
        if let tb = touchBar {
            NSTouchBar.dismissSystemModalTouchBar(tb)
        }
        touchBar = nil
        
        // Ensure the control strip icon stays visible
        showControlStripIcon()
    }

    func toggleTouchBar() {
        if touchBar != nil {
            dismissTouchBar()
        } else {
            presentTouchBar()
        }
    }

    /// Rebuild after config change
    func rebuild() {
        if touchBar != nil {
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
