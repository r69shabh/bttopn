import Cocoa
import IOKit

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

    // One-shot timers fired immediately after an app-switch / KVO dismissal.
    // Staggered to catch both fast (hot-start) and slow (cold-start) apps.
    private var representTimers: [Timer] = []

    // KVO observer: fires whenever the Touch Bar's isVisible property changes.
    private var touchBarObserver: NSKeyValueObservation?

    // Watchdog: a low-frequency repeating timer that re-asserts the Touch Bar
    // after Secure Input is released (password fields, Wi-Fi prompts, Raycast
    // search box, etc.). Runs every 2 seconds while keysVisible == true.
    // This is the definitive fix for cases where the OS silently blocks our
    // presentSystemModalTouchBar calls while Secure Input is held.
    private var watchdogTimer: Timer?

    // Tracks whether the system is currently asleep.
    // All observer callbacks and timer scheduling are suppressed during sleep
    // to prevent waking the CPU unnecessarily.
    private var isSleeping: Bool = false

    init(configManager: ConfigManager) {
        self.configManager = configManager
        super.init()
        registerAppSwitchObserver()
    }

    deinit {
        NSWorkspace.shared.notificationCenter.removeObserver(self)
        NotificationCenter.default.removeObserver(self)
        stopWatchdog()
    }

    // MARK: - Secure Input Detection
    //
    // Secure Input is a macOS security mode that prevents other processes from
    // injecting or intercepting keystrokes (active during password fields, Wi-Fi
    // prompts, Raycast's search box, etc.).
    //
    // While Secure Input is held, presentSystemModalTouchBar is silently blocked
    // by the OS. We detect it via the IOKit registry (same technique used by
    // Karabiner-Elements, Alfred, and other professional utilities).
    //
    // Returns true if any process currently holds Secure Input.
    private func isSecureInputActive() -> Bool {
        // IOServiceGetMatchingService gives us the HID system entry, which
        // exposes the "SecureInputPID" property when any app holds the lock.
        let service = IOServiceGetMatchingService(
            kIOMainPortDefault,
            IOServiceMatching("IOHIDSystem")
        )
        guard service != IO_OBJECT_NULL else { return false }
        defer { IOObjectRelease(service) }

        var properties: Unmanaged<CFMutableDictionary>?
        let kr = IORegistryEntryCreateCFProperties(service, &properties, kCFAllocatorDefault, 0)
        guard kr == KERN_SUCCESS, let props = properties?.takeRetainedValue() as? [String: Any] else {
            return false
        }

        // "HIDSecureInputPID" > 0 means a process currently holds Secure Input
        if let pid = props["HIDSecureInputPID"] as? Int32 {
            return pid > 0
        }
        return false
    }

    // MARK: - Watchdog Timer
    //
    // Fires every 2 seconds while keysVisible == true. Checks if our Touch Bar
    // was silently dismissed (e.g. by Secure Input) and re-asserts it the
    // moment Secure Input is released. This is the safety net that catches
    // every case the event-driven timers can't handle.

    private func startWatchdog() {
        stopWatchdog() // ensure no duplicate
        let timer = Timer(timeInterval: 2.0, repeats: true) { [weak self] _ in
            self?.watchdogTick()
        }
        timer.tolerance = 0.5 // allow OS timer coalescing — saves power
        RunLoop.main.add(timer, forMode: .common)
        watchdogTimer = timer
    }

    private func stopWatchdog() {
        watchdogTimer?.invalidate()
        watchdogTimer = nil
    }

    @objc private func watchdogTick() {
        guard keysVisible, !isSleeping else { return }

        // Only act if the Touch Bar is currently hidden
        guard let tb = touchBar, !tb.isVisible else { return }

        // Don't fight Secure Input — wait for it to be released
        guard !isSecureInputActive() else { return }

        // Touch Bar is hidden, keys should be visible, Secure Input is gone → re-assert
        repaintTouchBar()
    }

    // MARK: - App-Switch Observer
    //
    // When any standard app becomes frontmost, macOS dismisses our system-modal
    // Touch Bar. We watch for that event and, if keysVisible is true, schedule
    // staggered repaints to race Raycast's opening animation.

    private func registerAppSwitchObserver() {
        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(activeAppChanged(_:)),
            name: NSWorkspace.didActivateApplicationNotification,
            object: nil
        )
    }

    @objc private func activeAppChanged(_ notification: Notification) {
        guard !isSleeping else { return }
        guard keysVisible else { return }

        let activeApp = notification.userInfo?[NSWorkspace.applicationUserInfoKey]
            as? NSRunningApplication
        let activeBundleID = activeApp?.bundleIdentifier ?? ""

        // Don't fight ourselves
        let ownBundleID = Bundle.main.bundleIdentifier ?? "com.personal.bttopn"
        if activeBundleID == ownBundleID { return }

        scheduleStaggeredRepaints()
    }

    // MARK: - Staggered Repaints
    //
    // Fired after an app-switch or a KVO dismissal. Multiple tiers ensure we
    // catch both fast apps (hot-start Raycast: ~50ms) and slow apps (cold-start
    // Raycast: 300ms+). The watchdog handles anything that outlasts 1.5s.

    private func scheduleStaggeredRepaints() {
        representTimers.forEach { $0.invalidate() }
        representTimers.removeAll()

        let delays = [0.1, 0.3, 0.6, 1.0, 1.5]
        for delay in delays {
            let timer = Timer(timeInterval: delay, repeats: false) { [weak self] _ in
                DispatchQueue.main.async {
                    guard let self = self, !self.isSecureInputActive() else { return }
                    self.repaintTouchBar()
                }
            }
            timer.tolerance = 0.05
            RunLoop.main.add(timer, forMode: .common)
            representTimers.append(timer)
        }
    }

    // MARK: - Touch Bar Setup (with KVO)

    private func setupTouchBar() -> NSTouchBar {
        let tb = NSTouchBar()
        tb.delegate = self
        tb.defaultItemIdentifiers = [.keyGroup]

        // KVO: catches EVERY OS-initiated dismissal, including floating panels
        // like Raycast that don't send NSWorkspace.didActivateApplicationNotification.
        self.touchBarObserver = tb.observe(\.isVisible, options: [.new]) { [weak self] _, change in
            guard let self = self, !self.isSleeping, self.keysVisible else { return }
            if let visible = change.newValue, !visible {
                self.scheduleStaggeredRepaints()
            }
        }
        return tb
    }

    // MARK: - Repaint
    //
    // Re-presents the Touch Bar without toggling keysVisible state.
    //
    // KEY INSIGHT for no-jerk behaviour:
    // macOS has already dismissed our modal by the time this runs.
    // Calling dismissSystemModalTouchBar here would add a second blank frame
    // (dismiss → blank → present) causing the visible "jerk".
    // Instead we just re-assert the same cached NSTouchBar object directly
    // (blank → present), which is one transition instead of two.

    private func repaintTouchBar() {
        guard keysVisible, !isSleeping else { return }

        if touchBar == nil {
            self.touchBar = setupTouchBar()
        }

        DFRSystemModalShowsCloseBoxWhenFrontMost(false)
        NSTouchBar.presentSystemModalTouchBar(touchBar!, placement: 0,
                                               systemTrayItemIdentifier: nil)
        showControlStripIcon()
    }

    // MARK: - Control Strip Icon

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
        // Always build a fresh bar on explicit show so config changes are reflected.
        if let existing = touchBar {
            NSTouchBar.dismissSystemModalTouchBar(existing)
        }

        self.touchBar = setupTouchBar()

        DFRSystemModalShowsCloseBoxWhenFrontMost(false)
        NSTouchBar.presentSystemModalTouchBar(touchBar!, placement: 0,
                                               systemTrayItemIdentifier: nil)

        keysVisible = true

        showControlStripIcon()
        startWatchdog() // begin persistent Secure Input recovery
    }

    func dismissTouchBar() {
        keysVisible = false

        representTimers.forEach { $0.invalidate() }
        representTimers.removeAll()

        touchBarObserver?.invalidate()
        touchBarObserver = nil

        stopWatchdog()

        if let tb = touchBar {
            NSTouchBar.dismissSystemModalTouchBar(tb)
        }
        touchBar = nil

        showControlStripIcon()
    }

    // MARK: - Sleep / Wake

    /// Called by AppDelegate when macOS is about to sleep.
    func pauseForSleep() {
        isSleeping = true

        representTimers.forEach { $0.invalidate() }
        representTimers.removeAll()

        stopWatchdog() // critical: no timers during sleep

        if let tb = touchBar {
            NSTouchBar.dismissSystemModalTouchBar(tb)
        }
        // Keep touchBar object alive for fast wake restore
    }

    /// Called by AppDelegate when macOS has finished waking from sleep.
    func resumeAfterWake() {
        isSleeping = false

        guard keysVisible else { return }

        // Give TouchBarServer time to fully initialize before pushing our overlay.
        let timer = Timer(timeInterval: 0.5, repeats: false) { [weak self] _ in
            self?.repaintTouchBar()
            self?.startWatchdog()
        }
        timer.tolerance = 0.1
        RunLoop.main.add(timer, forMode: .common)
        representTimers.append(timer)
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

        let stack = NSStackView()
        stack.orientation = .horizontal
        stack.spacing = 2

        for keyMapping in configManager.config.keys {
            let button = NSButton(title: keyMapping.label, target: self, action: #selector(keyButtonTapped(_:)))
            button.tag = keyMapping.keyCode
            button.font = NSFont.monospacedSystemFont(ofSize: 14, weight: .medium)

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
