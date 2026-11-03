import Cocoa
import Carbon

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

    // Secure Input (Raycast's field, password fields, Wi-Fi prompts): macOS
    // hides the Touch Bar and drops synthetic keystrokes, BY DESIGN. The
    // only winning move is not to fight it: we pause all re-asserts while
    // it holds (each present call re-lays-out the whole Control Strip —
    // that was the remaining flicker source) and re-present the moment it
    // releases. secureInputActive tracks our paused state for the menu bar.
    private(set) var secureInputActive = false
    var onSecureInputChanged: ((Bool) -> Void)?

    // Sustained-loss handling: past a threshold of rejected presents, macOS
    // stops accepting this client entirely (see PresentBudget). The breaker
    // trips → we stop hammering and ask AppDelegate to re-register by
    // restarting (once per hour, rate-limited there). ⌃⌥⌘B always re-arms
    // manually as the escape hatch.
    var onSustainedHidden: (() -> Void)?

    /// Written on every present/dismiss so a relaunch (login item or our own
    /// auto-restart) can restore the keys the user had on.
    static let keysWantedKey = "touchBarKeysWanted"

    // Anti-flicker state. Every presentSystemModalTouchBar makes ALL Control
    // Strip icons (camera, volume, brightness…) re-layout, and past a point
    // macOS bans this client outright. We present only when the bar is
    // hidden, back off exponentially, and trip a circuit breaker after
    // repeated failures.
    private var lastPresentAttempt = Date.distantPast
    private var budget = PresentBudget.State()
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
    // Fires every 0.5s while keysVisible == true. Only acts when the bar is
    // hidden: re-presents with exponential backoff (attempt-based). After
    // maxConsecutiveFailures rejected presents it trips the circuit breaker
    // (PresentBudget) and stops entirely instead of getting bttopn banned by
    // the Touch Bar arbitration — the app then relies on the explicit user
    // toggle (⌃⌥⌘B) or the auto-restart to re-register.

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

        // Secure Input wins — never re-assert against it
        if IsSecureEventInputEnabled() {
            if !secureInputActive {
                secureInputActive = true
                NSLog("bttopn: Secure Input active — pausing Touch Bar re-asserts")
                onSecureInputChanged?(true)
            }
            return
        } else if secureInputActive {
            secureInputActive = false
            NSLog("bttopn: Secure Input released — restoring Touch Bar")
            onSecureInputChanged?(false)
            budget.reset()
            if touchBar == nil || touchBar?.isVisible == false {
                repaintTouchBar(force: true)
            }
        }
        // Only act if the Touch Bar is currently hidden — no-op if already visible
        guard let tb = touchBar, !tb.isVisible else {
            budget.reset()
            return
        }

        // Circuit breaker open — stop all presents entirely. The user can
        // force a fresh attempt with ⌃⌥⌘B; otherwise the auto-restart
        // re-registers us (rate-limited) and keys come back on their own.
        if budget.suspended { return }

        // Attempt-based exponential backoff: 2s, 4s, 8s … capped at 8s.
        // Every present re-lays-out the whole Control Strip — hammering
        // gets the client banned, so each attempt is precious.
        let backoff = min(2.0 * pow(2.0, Double(budget.failures)), 8.0)
        guard Date().timeIntervalSince(lastPresentAttempt) >= backoff else { return }

        // Count this attempt before presenting; at the threshold the
        // breaker trips and we don't even make the call.
        budget.noteAttempt()
        if budget.suspended {
            NSLog("bttopn: \(PresentBudget.maxConsecutiveFailures) rejected presents — suspending (keys stay hidden until ⌃⌥⌘B or auto-restart)")
            onSustainedHidden?()
            return
        }

        // The OS is ignoring the stale instance (common when Raycast or
        // Spotlight overlays the UI). Only rebuild it after several failed
        // attempts — rebuilding on every tick is what caused the flicker.
        if budget.failures >= 4 {
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
    // Fired after an app-switch or a KVO dismissal. Kept lean on purpose:
    // every present call re-lays-out the whole Control Strip, so we only
    // make a few attempts at staggered moments; the backoff watchdog covers
    // anything slower, and the circuit breaker covers rejection.

    private func scheduleStaggeredRepaints() {
        representTimers.forEach { $0.invalidate() }
        representTimers.removeAll()

        // Immediately try once — catches fast app switches right away
        repaintTouchBar()

        // Then a couple of retries to outlast slower cold-start animations
        // (Raycast cold start: 200–800ms). Watchdog handles anything longer.
        let delays = [0.3, 0.9, 1.6]
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
        // Discard any observer from a previous bar instance before
        // creating a new one — repeated rebuilds would leak observers
        touchBarObserver?.invalidate()
        touchBarObserver = nil

        let tb = NSTouchBar()
        tb.delegate = self
        tb.defaultItemIdentifiers = [.keyGroup]

        // KVO: catches EVERY OS-initiated dismissal, including floating panels
        // like Raycast that don't send NSWorkspace.didActivateApplicationNotification.
        self.touchBarObserver = tb.observe(\.isVisible, options: [.new]) { [weak self] _, change in
            guard let self = self, !self.isSleeping, self.keysVisible else { return }
            if let visible = change.newValue {
                if visible {
                    // Bar is back — breaker is clear, full budget restored
                    self.budget.reset()
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
        // macOS hides the bar under Secure Input; presenting anyway just
        // re-lays-out the Control Strip for nothing (flicker).
        if IsSecureEventInputEnabled() { return }
        // Circuit breaker open — components stop making present calls entirely
        if budget.suspended { return }
        // Bar is already visible — never re-present just because something
        // asked for a repaint. Every redundant present re-lays-out the whole
        // Control Strip.
        if let tb = touchBar, tb.isVisible { return }

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
        budget.reset()
        keysVisible = true
        UserDefaults.standard.set(true, forKey: TouchBarManager.keysWantedKey)

        showControlStripIcon()
        startWatchdog() // begin persistent Secure Input recovery
    }

    func dismissTouchBar() {
        keysVisible = false
        budget.reset()
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
        budget.reset()

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
        // Escape hatch: breaker tripped and bar is hidden — a press means
        // "try again fresh", not "dismiss" (keys are already invisible)
        if keysVisible && budget.suspended {
            presentTouchBar()
            return
        }
        if keysVisible {
            dismissTouchBar()
        } else {
            presentTouchBar()
        }
    }

    /// Rebuild after config change
    func rebuild() {
        if keysVisible && !IsSecureEventInputEnabled() {
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
