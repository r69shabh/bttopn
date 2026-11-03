import Cocoa

// MARK: - Action Palette
//
// A Raycast-style, keyboard-driven command palette for every action you
// have configured in bttopn — works on ALL Macs, including ones without a
// Touch Bar. Toggle with ⌃⌥⌘Space.
//
// Design notes:
//   - The panel is a NON-ACTIVATING panel that becomes key: you can type
//     into it, but bttopn itself never becomes the frontmost app — so
//     keystroke/media actions land in the app you were using, not here.
//   - ↑/↓ move selection, ↩ runs, ⎋ closes; clicking a row runs it.
//   - Clicking outside closes the palette (windowDidResignKey).

struct PaletteEntry {
    let title: String
    let detail: String
    let mapping: KeyMapping
}

final class PalettePanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

final class ActionPalette: NSObject {

    private let configManager: ConfigManager
    private var panel: PalettePanel?
    private var searchField: NSTextField?
    private var tableView: NSTableView?
    private var emptyLabel: NSTextField?
    private var keyMonitor: Any?

    private var entries: [PaletteEntry] = []
    private var filtered: [PaletteEntry] = []

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
        filtered = entries
        tableView?.reloadData()
        searchField?.stringValue = ""
        emptyLabel?.isHidden = true
        selectRow(filtered.isEmpty ? nil : 0)

        if let screen = NSScreen.main {
            let visible = screen.visibleFrame
            let size = NSSize(width: 580, height: 380)
            panel?.setFrame(NSRect(x: visible.midX - size.width / 2,
                                   y: visible.maxY - size.height - 90,
                                   width: size.width, height: size.height),
                            display: false)
        }
        installKeyMonitor()
        panel?.orderFrontRegardless()
        panel?.makeKey()
        if let field = searchField { panel?.makeFirstResponder(field) }
    }

    private func hide() {
        removeKeyMonitor()
        panel?.orderOut(nil)
    }

    // MARK: - Entries

    private func buildEntries() -> [PaletteEntry] {
        var out: [PaletteEntry] = []
        func append(_ mapping: KeyMapping, scope: String) {
            var parts = [scope, mapping.action.displayName]
            if mapping.action != .key, let value = mapping.value, !value.isEmpty {
                parts.append(value)
            }
            if let modifiers = mapping.modifiers, !modifiers.isEmpty {
                parts.append(modifiers.joined(separator: "+"))
            }
            out.append(PaletteEntry(title: mapping.label,
                                    detail: parts.joined(separator: " · "),
                                    mapping: mapping))
        }
        for mapping in configManager.config.keys { append(mapping, scope: "Default") }
        for profile in configManager.config.profiles {
            for mapping in profile.keys { append(mapping, scope: profile.name) }
        }
        // Dedupe identical (label, detail) pairs (e.g. same key in two profiles is NOT deduped — scope differs)
        return out
    }

    private func applyFilter() {
        let query = searchField?.stringValue ?? ""
        filtered = entries.filter { PaletteFilter.matches(query, in: $0.title + " " + $0.detail) }
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
        hide()
        ActionRunner.run(entry.mapping)
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

        let size = NSSize(width: 580, height: 380)
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
        let field = NSTextField(frame: NSRect(x: 18, y: size.height - 56, width: size.width - 36, height: 34))
        field.placeholderString = "Search actions…"
        field.font = .systemFont(ofSize: 20, weight: .medium)
        field.isBezeled = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.autoresizingMask = [.width, .minYMargin]
        field.delegate = self
        root.addSubview(field)

        // Results table
        let scroll = NSScrollView(frame: NSRect(x: 10, y: 12, width: size.width - 20, height: size.height - 72))
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.autoresizingMask = [.width, .height]

        let table = NSTableView()
        table.headerView = nil
        table.rowHeight = 46
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
        let empty = NSTextField(labelWithString: "No matching actions")
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

    private let titleField = NSTextField(labelWithString: "")
    private let detailField = NSTextField(labelWithString: "")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)

        titleField.font = .systemFont(ofSize: 14, weight: .semibold)
        titleField.lineBreakMode = .byTruncatingTail
        titleField.translatesAutoresizingMaskIntoConstraints = false

        detailField.font = .systemFont(ofSize: 11, weight: .regular)
        detailField.textColor = .secondaryLabelColor
        detailField.lineBreakMode = .byTruncatingTail
        detailField.translatesAutoresizingMaskIntoConstraints = false

        addSubview(titleField)
        addSubview(detailField)
        NSLayoutConstraint.activate([
            titleField.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            titleField.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            titleField.topAnchor.constraint(equalTo: topAnchor, constant: 5),
            titleField.heightAnchor.constraint(equalToConstant: 18),

            detailField.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            detailField.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            detailField.topAnchor.constraint(equalTo: titleField.bottomAnchor, constant: 1),
            detailField.heightAnchor.constraint(equalToConstant: 14),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    func configure(with entry: PaletteEntry) {
        titleField.stringValue = entry.title
        detailField.stringValue = entry.detail
    }
}
