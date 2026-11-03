import Cocoa

// MARK: - Action Palette
//
// A Raycast-style, keyboard-driven launcher — works on ALL Macs, including
// ones without a Touch Bar. Toggle with ⌃⌥⌘Space.
//
// What's in it:
//   - Every configured bttopn action (keys, media, apps, URLs, shell, window
//     snaps) across default + per-app profiles
//   - 20 built-in system actions (window snaps, media keys, screenshots,
//     Lock Screen, Dark Mode…)
//   - Every app installed on this Mac (type "calc" → Calculator)
//   - Clipboard history items (when enabled) — ↩ pastes the item
//   - Instant calculator (type "12*45+3" → "= 543", ↩ copies it)
//
// Design notes:
//   - The panel is a NON-ACTIVATING panel that becomes key: you can type
//     into it, but bttopn never becomes the frontmost app — actions land
//     in the app you were using.
//   - Apps and clipboard items only appear once you start typing.
//   - ↑/↓ move selection, ↩ runs, ⎋ closes; clicking a row runs it.
//   - MRU: recently run entries float to the top (UserDefaults, cap 20).

struct PaletteEntry {
    /// Stable id for MRU ordering, e.g. "Default|key|6|cmd|Undo", "app:/Applications/Calculator.app".
    let id: String
    let title: String
    let detail: String
    /// Apps / clipboard items only appear when there is a query — the
    /// empty palette shows MRU + configured + built-in actions.
    let hideWhenEmptyQuery: Bool
    let symbol: String?
    let icon: NSImage?
    let run: () -> Void
}

final class PalettePanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

final class ActionPalette: NSObject {

    /// Wired by AppDelegate — used to re-assert the Touch Bar after our
    /// floating panel becomes key (the OS hides the system-modal bar when
    /// any panel takes focus, even non-activating ones like Raycast's).
    weak var touchBarManager: TouchBarManager?

    private let configManager: ConfigManager
    private var panel: PalettePanel?
    private var searchField: NSTextField?
    private var tableView: NSTableView?
    private var emptyLabel: NSTextField?
    private var keyMonitor: Any?

    private var entries: [PaletteEntry] = []
    private var filtered: [PaletteEntry] = []

    private static let mruKey = "paletteMRU"
    private static let mruLimit = 20

    init(configManager: ConfigManager) {
        self.configManager = configManager
        super.init()
    }

    // MARK: - Toggle

    func toggle() {
        if let panel = panel, panel.isVisible {
            hide()
        } else {
            show()
        }
    }

    private func show() {
        ensurePanel()
        entries = buildEntries()
        searchField?.stringValue = ""
        applyFilter()

        if let screen = NSScreen.main {
            let visible = screen.visibleFrame
            let size = NSSize(width: 580, height: 400)
            panel?.setFrame(NSRect(x: visible.midX - size.width / 2,
                                   y: visible.maxY - size.height - 90,
                                   width: size.width, height: size.height),
                            display: false)
        }
        installKeyMonitor()
        panel?.orderFrontRegardless()
        panel?.makeKey()
        if let field = searchField { panel?.makeFirstResponder(field) }

        // Becoming key steals the Touch Bar context from the frontmost app —
        // re-present fresh or the keys vanish while the palette is open
        // (same thing Raycast's panel does).
        touchBarManager?.rebuild()
    }

    private func hide() {
        removeKeyMonitor()
        panel?.orderOut(nil)
        // Focus context shifts again on close — bring the keys back
        touchBarManager?.rebuild()
    }

    // MARK: - MRU

    private func loadMRU() -> [String] {
        UserDefaults.standard.stringArray(forKey: Self.mruKey) ?? []
    }

    private func recordRun(id: String) {
        guard !id.hasPrefix("calc:") else { return } // don't pollute MRU with arithmetic
        var mru = loadMRU()
        mru.removeAll { $0 == id }
        mru.insert(id, at: 0)
        if mru.count > Self.mruLimit { mru.removeLast(mru.count - Self.mruLimit) }
        UserDefaults.standard.set(mru, forKey: Self.mruKey)
    }

    // MARK: - Entries

    private static func entryID(scope: String, _ m: KeyMapping) -> String {
        [scope, m.action.rawValue, String(m.keyCode), m.value ?? "",
         (m.modifiers ?? []).joined(separator: "+"), m.label].joined(separator: "|")
    }

    private func configuredEntries() -> [PaletteEntry] {
        var out: [PaletteEntry] = []
        func append(_ mapping: KeyMapping, scope: String) {
            var parts = [scope, mapping.action.displayName]
            if mapping.action != .key, let value = mapping.value, !value.isEmpty {
                parts.append(value)
            }
            if let modifiers = mapping.modifiers, !modifiers.isEmpty {
                parts.append(modifiers.joined(separator: "+"))
            }
            out.append(PaletteEntry(id: Self.entryID(scope: scope, mapping),
                                    title: mapping.label,
                                    detail: parts.joined(separator: " · "),
                                    hideWhenEmptyQuery: false,
                                    symbol: "command",
                                    icon: nil) {
                ActionRunner.run(mapping)
            })
        }
        for mapping in configManager.config.keys { append(mapping, scope: "Default") }
        for profile in configManager.config.profiles {
            for mapping in profile.keys { append(mapping, scope: profile.name) }
        }
        return out
    }

    private func buildEntries() -> [PaletteEntry] {
        var out = configuredEntries()

        // Built-in system actions — useful even with zero configuration
        for builtin in SystemActions.all {
            out.append(PaletteEntry(id: builtin.id,
                                    title: builtin.title,
                                    detail: builtin.detail,
                                    hideWhenEmptyQuery: false,
                                    symbol: "gearshape",
                                    icon: nil,
                                    run: builtin.run))
        }

        // Every app on this Mac (query-only visibility)
        for app in AppLauncher.list() {
            let path = app.url.standardizedFileURL.path
            out.append(PaletteEntry(id: "app:\(path)",
                                    title: app.name,
                                    detail: "Application",
                                    hideWhenEmptyQuery: true,
                                    symbol: nil,
                                    icon: NSWorkspace.shared.icon(forFile: app.url.path)) {
                AppLauncher.launch(app)
            })
        }

        // Clipboard history items — ↩ pastes the item (query-only visibility)
        if ClipboardHistory.shared.isEnabled {
            for item in ClipboardHistory.shared.items {
                let preview = ClipboardHistory.preview(item, maxLength: 60)
                out.append(PaletteEntry(id: "clip:\(item.prefix(40))",
                                        title: preview,
                                        detail: "Clipboard · ↩ pastes into current app",
                                        hideWhenEmptyQuery: true,
                                        symbol: "doc.on.clipboard",
                                        icon: nil) {
                    ClipboardHistory.pasteText(item)
                })
            }
        }
        return out
    }

    private func calculatorEntry(for query: String) -> PaletteEntry? {
        guard let value = Calculator.eval(query) else { return nil }
        let formatted = Calculator.format(value)
        return PaletteEntry(id: "calc:\(query)",
                            title: "= \(formatted)",
                            detail: "Calculator · ↩ copies result",
                            hideWhenEmptyQuery: false,
                            symbol: "function",
                            icon: nil) {
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            pasteboard.setString(formatted, forType: .string)
        }
    }

    private func applyFilter() {
        let query = searchField?.stringValue ?? ""
        var list = entries.filter { entry in
            if query.isEmpty && entry.hideWhenEmptyQuery { return false }
            return PaletteFilter.matches(query, in: entry.title + " " + entry.detail)
        }
        list = PaletteMRU.ordered(list, mru: loadMRU(), id: { $0.id })
        if let calc = calculatorEntry(for: query) {
            list.insert(calc, at: 0) // calculator result pinned to the top
        }
        filtered = list
        tableView?.reloadData()
        emptyLabel?.isHidden = !filtered.isEmpty
        selectRow(filtered.isEmpty ? nil : 0)
    }

    private func selectRow(_ row: Int?) {
        guard let tableView = tableView else { return }
        guard let row = row, !filtered.isEmpty else {
            tableView.deselectAll(nil)
            return
        }
        let clamped = min(max(row, 0), filtered.count - 1)
        tableView.selectRowIndexes(IndexSet(integer: clamped), byExtendingSelection: false)
        tableView.scrollRowToVisible(clamped)
    }

    private var selectedRow: Int {
        tableView?.selectedRow ?? -1
    }

    private func moveSelection(by delta: Int) {
        guard !filtered.isEmpty else { return }
        let current = selectedRow < 0 ? 0 : selectedRow
        selectRow(current + delta)
    }

    private func runSelected() {
        let row = selectedRow
        guard filtered.indices.contains(row) else { return }
        run(filtered[row])
    }

    private func run(_ entry: PaletteEntry) {
        recordRun(id: entry.id)
        hide()
        entry.run()
    }

    // MARK: - Key monitor

    private func installKeyMonitor() {
        removeKeyMonitor()
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self = self, let panel = self.panel, panel.isVisible else { return event }
            switch event.keyCode {
            case 53:                    // ⎋
                self.hide(); return nil
            case 36, 76:                // ↩ / numpad ↩
                self.runSelected(); return nil
            case 125:                   // ↓
                self.moveSelection(by: 1); return nil
            case 126:                   // ↑
                self.moveSelection(by: -1); return nil
            default:
                return event
            }
        }
    }

    private func removeKeyMonitor() {
        if let monitor = keyMonitor {
            NSEvent.removeMonitor(monitor)
            keyMonitor = nil
        }
    }

    // MARK: - Panel construction

    private func ensurePanel() {
        if panel != nil { return }

        let size = NSSize(width: 580, height: 400)
        let panel = PalettePanel(contentRect: NSRect(origin: .zero, size: size),
                                 styleMask: [.borderless, .nonactivatingPanel],
                                 backing: .buffered,
                                 defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.hasShadow = true
        panel.isFloatingPanel = true
        panel.becomesKeyOnlyIfNeeded = false
        panel.hidesOnDeactivate = false
        panel.delegate = self

        // Rounded, translucent background
        let root = NSVisualEffectView(frame: NSRect(origin: .zero, size: size))
        root.material = .hudWindow
        root.blendingMode = .behindWindow
        root.state = .active
        root.wantsLayer = true
        root.layer?.cornerRadius = 14
        root.layer?.masksToBounds = true
        root.autoresizingMask = [.width, .height]
        panel.contentView = root

        // Search field
        let field = NSTextField(frame: NSRect(x: 18, y: size.height - 58, width: size.width - 36, height: 34))
        field.placeholderString = "Type to search apps, actions, clipboard… or a sum"
        field.font = .systemFont(ofSize: 19, weight: .medium)
        field.isBezeled = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.autoresizingMask = [.width, .minYMargin]
        field.delegate = self
        root.addSubview(field)

        // Results table
        let scroll = NSScrollView(frame: NSRect(x: 10, y: 12, width: size.width - 20, height: size.height - 74))
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.autoresizingMask = [.width, .height]

        let table = NSTableView()
        table.headerView = nil
        table.rowHeight = 44
        table.intercellSpacing = NSSize(width: 0, height: 2)
        table.backgroundColor = .clear
        table.selectionHighlightStyle = .regular
        table.style = .plain
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("entry"))
        column.width = size.width - 40
        table.addTableColumn(column)
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.action = #selector(tableClicked)
        scroll.documentView = table
        root.addSubview(scroll)

        // Empty state
        let empty = NSTextField(labelWithString: "No matches")
        empty.font = .systemFont(ofSize: 13, weight: .medium)
        empty.textColor = .secondaryLabelColor
        empty.alignment = .center
        empty.frame = NSRect(x: 0, y: size.height / 2 - 30, width: size.width, height: 20)
        empty.isHidden = true
        empty.autoresizingMask = [.width, .minYMargin]
        root.addSubview(empty)

        self.panel = panel
        self.searchField = field
        self.tableView = table
        self.emptyLabel = empty
    }

    @objc private func tableClicked() {
        guard let tableView = tableView else { return }
        let row = tableView.clickedRow
        guard filtered.indices.contains(row) else { return }
        selectRow(row)
        run(filtered[row])
    }
}

// MARK: - Table view data source / delegate

extension ActionPalette: NSTableViewDataSource, NSTableViewDelegate {

    func numberOfRows(in tableView: NSTableView) -> Int {
        filtered.count
    }

    func tableView(_ tableView: NSTableView,
                   viewFor tableColumn: NSTableColumn?,
                   row: Int) -> NSView? {
        guard filtered.indices.contains(row) else { return nil }
        let identifier = NSUserInterfaceItemIdentifier("paletteCell")

        let cell: PaletteEntryCell
        if let reused = tableView.makeView(withIdentifier: identifier, owner: self) as? PaletteEntryCell {
            cell = reused
        } else {
            cell = PaletteEntryCell()
            cell.identifier = identifier
        }
        cell.configure(with: filtered[row])
        return cell
    }

    func tableView(_ tableView: NSTableView,
                   shouldSelectRow row: Int) -> Bool {
        true
    }
}

// MARK: - Search field delegate (live filtering)

extension ActionPalette: NSTextFieldDelegate {

    func controlTextDidChange(_ obj: Notification) {
        applyFilter()
    }
}

// MARK: - Panel delegate (click-outside to dismiss)

extension ActionPalette: NSWindowDelegate {

    func windowDidResignKey(_ notification: Notification) {
        hide()
    }
}

// MARK: - Cell view

private final class PaletteEntryCell: NSTableCellView {

    private let iconView = NSImageView()
    private let titleField = NSTextField(labelWithString: "")
    private let detailField = NSTextField(labelWithString: "")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)

        iconView.imageScaling = .scaleProportionallyUpOrDown
        iconView.translatesAutoresizingMaskIntoConstraints = false

        titleField.font = .systemFont(ofSize: 13, weight: .semibold)
        titleField.lineBreakMode = .byTruncatingTail
        titleField.translatesAutoresizingMaskIntoConstraints = false

        detailField.font = .systemFont(ofSize: 11, weight: .regular)
        detailField.textColor = .secondaryLabelColor
        detailField.lineBreakMode = .byTruncatingTail
        detailField.translatesAutoresizingMaskIntoConstraints = false

        addSubview(iconView)
        addSubview(titleField)
        addSubview(detailField)
        NSLayoutConstraint.activate([
            iconView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            iconView.centerYAnchor.constraint(equalTo: centerYAnchor),
            iconView.widthAnchor.constraint(equalToConstant: 24),
            iconView.heightAnchor.constraint(equalToConstant: 24),

            titleField.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: 10),
            titleField.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            titleField.topAnchor.constraint(equalTo: topAnchor, constant: 4),
            titleField.heightAnchor.constraint(equalToConstant: 18),

            detailField.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: 10),
            detailField.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            detailField.topAnchor.constraint(equalTo: titleField.bottomAnchor, constant: 1),
            detailField.heightAnchor.constraint(equalToConstant: 14),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    func configure(with entry: PaletteEntry) {
        if let icon = entry.icon {
            iconView.image = icon
            iconView.contentTintColor = nil
        } else if let symbol = entry.symbol,
                  let image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil) {
            image.size = NSSize(width: 20, height: 20)
            iconView.image = image
            iconView.contentTintColor = .secondaryLabelColor
        } else {
            iconView.image = NSImage(systemSymbolName: "circle", accessibilityDescription: nil)
            iconView.contentTintColor = .tertiaryLabelColor
        }
        titleField.stringValue = entry.title
        detailField.stringValue = entry.detail
    }
}
