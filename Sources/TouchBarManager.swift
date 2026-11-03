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

    // One-shot timers fired immediately after an app-switch / KVO dismissal.
    // Staggered to catch both fast (hot-start) and slow (cold-start) apps.
    private var representTimers: [Timer] = []

    // KVO observer: fires whenever the Touch Bar's isVisible property changes.
    private var touchBarObserver: NSKeyValueObservation?

    // Watchdog: a low-frequency repeating timer that re-asserts the Touch Bar
    // after Secure Input is released (password fields, Wi-Fi prompts, Raycast
    // search box, etc.). Runs every 0.5 seconds while keysVisible == true.
    // This is the definitive fix for cases where the OS silently blocks our
    // presentSystemModalTouchBar calls while Secure Input is held.
    private var watchdogTimer: Timer?

    // Sustained-loss tracking: the OS can permanently stop accepting our
    // system-modal Touch Bar after a hostile overlay (Raycast, password
    // fields, etc.). Re-presents stop working and only re-registering with
    // the Touch Bar server (i.e. restarting the app) revives it. AppDelegate
    // hooks onSustainedHidden to do exactly that — once per episode, and
    // rate-limited by AppDelegate to once per hour.
    private var hiddenSince: Date?
    private var sustainedHiddenNotified = false
    var onSustainedHidden: (() -> Void)?

    /// Written on every present/dismiss so a relaunch (login item or our own
    /// auto-restart) can restore the keys the user had on.
    static let keysWantedKey = "touchBarKeysWanted"

    // Anti-flicker state. Every presentSystemModalTouchBar makes ALL Control
    // Strip icons (camera, volume, brightness…) re-layout, and every
    // destroy/rebuild cycle re-registers our tray item. We therefore rate-
    // limit presents and back off exponentially while the OS refuses to show
    // the bar — same guarantee (keys come back), without the strobe.
    private var lastPresentAttempt = Date.distantPast
    private var reassertFailures = 0
    private var controlStripPresenceSet = false

    // Tracks whether the system is currently asleep.
    // All observer callbacks and timer scheduling are suppressed during sleep
    // to prevent waking the CPU unnecessarily.
    private var isSleeping: Bool = false

    // The exact key set currently rendered in the Touch Bar, and which
    // profile context it came from ("default" or "profile:<bundleID>").
    // Button tags are indices into this array.
    private var currentKeys: [KeyMapping] = []
    private var renderedContextID: String?

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

    // MARK: - Watchdog Timer
    //
    // Fires every 0.5 seconds while keysVisible == true. If the Touch Bar is
    // hidden but should be visible, it unconditionally re-asserts — no Secure
    // Input check, no guards. If the OS rejects the call (e.g. a system dialog
    // has hard-locked the Touch Bar), it fails silently and we try again in 0.5s.
    // The moment any blocker (Raycast, Spotlight, password field, Wi-Fi prompt)
    // releases control, the very next tick wins and brings the keys back.

    private func startWatchdog() {
        stopWatchdog()
        let timer = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in
            self?.watchdogTick()
        }
        timer.tolerance = 0.1
        RunLoop.main.add(timer, forMode: .common)
        watchdogTimer = timer
    }

    private func stopWatchdog() {
        watchdogTimer?.invalidate()
        watchdogTimer = nil
    }

    @objc private func watchdogTick() {
        guard keysVisible, !isSleeping else { return }
        // Only act if the Touch Bar is currently hidden — no-op if already visible
        guard let tb = touchBar, !tb.isVisible else {
            hiddenSince = nil
            sustainedHiddenNotified = false
            return
        }

        if hiddenSince == nil { hiddenSince = Date() }
        if let since = hiddenSince,
           Date().timeIntervalSince(since) > 90,
           !sustainedHiddenNotified {
            sustainedHiddenNotified = true
            NSLog("bttopn: Touch Bar hidden for >90s despite re-asserts — requesting auto-restart")
            onSustainedHidden?()
        }

        // Exponential backoff: 0.5s, 1s, 2s, … capped at 4s.
        // Each present re-lays-out the whole Control Strip; hammering it
        // makes every other strip icon flicker for as long as the OS keeps
        // hiding our bar (e.g. during a slow app launch).
        reassertFailures += 1
        let backoff = min(0.5 * pow(2.0, Double(reassertFailures - 1)), 4.0)
        guard Date().timeIntervalSince(lastPresentAttempt) >= backoff else { return }

        // The OS is ignoring the stale instance (common when Raycast or
        // Spotlight overlays the UI). Only rebuild it after several failed
        // re-asserts — rebuilding on every tick is what caused the flicker.
        if reassertFailures >= 4 {
            touchBarObserver?.invalidate()
            touchBarObserver = nil
            NSTouchBar.dismissSystemModalTouchBar(tb)
            self.touchBar = nil
        }

        repaintTouchBar(force: true)
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

        // If the newly activated app has its own profile (or lost one), swap
        // the rendered key set. rebuild() re-presents immediately; the
        // staggered repaints / watchdog cover any OS-initiated dismissal.
        let contextID = configManager.config.contextID(forBundleID: activeBundleID)
        if contextID != renderedContextID {
            rebuild()
        }

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

        // Immediately try once — catches fast app switches right away
        repaintTouchBar()

        // Then staggered retries to outlast slow cold-start animations
        // (e.g. Raycast cold start: 200–800ms). Watchdog handles anything longer.
        let delays = [0.15, 0.4, 0.8, 1.2, 1.8]
        for delay in delays {
            let timer = Timer(timeInterval: delay, repeats: false) { [weak self] _ in
                DispatchQueue.main.async {
                    self?.repaintTouchBar()
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
            if let visible = change.newValue {
                if visible {
                    // Bar is back — reset the re-assert backoff
                    self.reassertFailures = 0
                } else {
                    self.scheduleStaggeredRepaints()
                }
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

    // `force` bypasses the minimum re-present interval; used by the watchdog
    // (after its own backoff) and when the user explicitly toggles the bar.
    private func repaintTouchBar(force: Bool = false) {
        guard keysVisible, !isSleeping else { return }

        // Never present more than once per 0.5s; every present re-lays-out
        // the Control Strip, and the strip re-layout is what the user sees
        // as "all the other Touch Bar icons flickering".
        if !force && Date().timeIntervalSince(lastPresentAttempt) < 0.5 { return }
        lastPresentAttempt = Date()

        if touchBar == nil {
            self.touchBar = setupTouchBar()
        }

        DFRSystemModalShowsCloseBoxWhenFrontMost(false)
        NSTouchBar.presentSystemModalTouchBar(touchBar!, placement: 0,
                                               systemTrayItemIdentifier: .controlStripItem)
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

        // Set presence once per run — re-asserting on every repaint makes the
        // whole Control Strip re-layout and flicker.
        guard !controlStripPresenceSet else { return }
        DFRElementSetControlStripPresenceForIdentifier(.controlStripItem, true)
        controlStripPresenceSet = true
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
                                               systemTrayItemIdentifier: .controlStripItem)

        lastPresentAttempt = Date()
        reassertFailures = 0
        keysVisible = true
        hiddenSince = nil
        sustainedHiddenNotified = false
        UserDefaults.standard.set(true, forKey: TouchBarManager.keysWantedKey)

        showControlStripIcon()
        startWatchdog() // begin persistent Secure Input recovery
    }

    func dismissTouchBar() {
        keysVisible = false
        hiddenSince = nil
        sustainedHiddenNotified = false
        UserDefaults.standard.set(false, forKey: TouchBarManager.keysWantedKey)

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

        let frontmostBundleID = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        let keys = configManager.config.keys(forBundleID: frontmostBundleID)
        self.currentKeys = keys
        self.renderedContextID = configManager.config.contextID(forBundleID: frontmostBundleID)

        let stack = NSStackView()
        stack.orientation = .horizontal
        stack.spacing = 2

        for (index, keyMapping) in keys.enumerated() {
            let button = NSButton(title: keyMapping.label, target: self, action: #selector(keyButtonTapped(_:)))
            button.tag = index
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
        let index = sender.tag
        guard currentKeys.indices.contains(index) else { return }
        ActionRunner.run(currentKeys[index])
    }
}
