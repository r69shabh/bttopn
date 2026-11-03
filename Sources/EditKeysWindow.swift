import Cocoa
import UniformTypeIdentifiers

// MARK: - Edit Keys Window Controller
//
// Layout:
//   Applies to: [Default (all apps) ▾] [+] [−]      ← default layout or per-app profile
//   ─── Label ── Action ── Parameter ───────────────
//   [↑][↓] label actionPopup paramHolder     [✕]
//
// Every key targets one of the actions in KeyAction. The parameter control is
// swapped in/out of `parameterHolder` when the row's Action popup changes.

class EditKeysWindowController: NSWindowController {

    private let configManager: ConfigManager
    private let onSave: () -> Void

    // In-memory working copy of the whole config (default + profiles).
    // Harvested from / written into the row views when the scope changes;
    // persisted only on Save & Apply.
    private var workingConfig: KeyConfig

    // 0 = default layout, 1...n = profile at index (scopeIndex - 1)
    private var scopeIndex: Int = 0

    private var appliesToPopup: NSPopUpButton!
    private var addProfileButton: NSButton!
    private var removeProfileButton: NSButton!
    private var scrollView: NSScrollView!
    private var stackView: NSStackView!
    private var keyRows: [KeyRow] = []

    // Tag offset to avoid conflicts with separator/header items in popup
    private let tagOffset = 1000

    private final class KeyRow {
        let container: NSStackView
        let upButton: NSButton
        let downButton: NSButton
        let labelField: NSTextField
        let actionPopup: NSPopUpButton
        let parameterHolder: NSView
        let deleteButton: NSButton
        var parameterView: NSView?
        var appBundleIDs: [String] = []

        init(container: NSStackView, upButton: NSButton, downButton: NSButton,
             labelField: NSTextField, actionPopup: NSPopUpButton,
             parameterHolder: NSView, deleteButton: NSButton) {
            self.container = container
            self.upButton = upButton
            self.downButton = downButton
            self.labelField = labelField
            self.actionPopup = actionPopup
            self.parameterHolder = parameterHolder
            self.deleteButton = deleteButton
        }
    }

    init(configManager: ConfigManager, onSave: @escaping () -> Void) {
        self.configManager = configManager
        self.onSave = onSave
        self.workingConfig = configManager.config

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 780, height: 520),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered, defer: false
        )
        window.title = "bttopn — Touch Bar Keys"
        window.center()
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 640, height: 400)

        super.init(window: window)
        setupUI()
        reloadAppliesToPopup()
        reloadRows()
    }

    required init?(coder: NSCoder) { fatalError() }

    // MARK: - UI Setup

    private func setupUI() {
        guard let contentView = window?.contentView else { return }

        // Scope row: "Applies to" popup + add/remove profile buttons
        let scopeLabel = NSTextField(labelWithString: "Applies to:")
        scopeLabel.font = NSFont.systemFont(ofSize: 12, weight: .medium)
        scopeLabel.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(scopeLabel)

        appliesToPopup = NSPopUpButton()
        appliesToPopup.target = self
        appliesToPopup.action = #selector(scopePopupChanged)
        appliesToPopup.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(appliesToPopup)

        addProfileButton = NSButton(title: "+", target: self, action: #selector(addProfile))
        addProfileButton.bezelStyle = .rounded
        addProfileButton.toolTip = "Add per-app profile (choose an .app)"
        addProfileButton.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(addProfileButton)

        removeProfileButton = NSButton(title: "−", target: self, action: #selector(removeProfile))
        removeProfileButton.bezelStyle = .rounded
        removeProfileButton.toolTip = "Remove selected per-app profile"
        removeProfileButton.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(removeProfileButton)

        // Column headers
        let colReorder = NSTextField(labelWithString: "")
        colReorder.widthAnchor.constraint(equalToConstant: 48).isActive = true
        let colLabel = NSTextField(labelWithString: "Label")
        colLabel.font = NSFont.systemFont(ofSize: 11, weight: .semibold)
        colLabel.textColor = .secondaryLabelColor
        colLabel.widthAnchor.constraint(equalToConstant: 100).isActive = true
        let colAction = NSTextField(labelWithString: "Action")
        colAction.font = NSFont.systemFont(ofSize: 11, weight: .semibold)
        colAction.textColor = .secondaryLabelColor
        colAction.widthAnchor.constraint(equalToConstant: 120).isActive = true
        let colParam = NSTextField(labelWithString: "Parameter")
        colParam.font = NSFont.systemFont(ofSize: 11, weight: .semibold)
        colParam.textColor = .secondaryLabelColor
        let colDel = NSTextField(labelWithString: "")
        colDel.widthAnchor.constraint(equalToConstant: 28).isActive = true

        let colHeaders = NSStackView(views: [colReorder, colLabel, colAction, colParam, colDel])
        colHeaders.orientation = .horizontal
        colHeaders.spacing = 6
        colHeaders.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(colHeaders)

        // Scroll view with stack for key rows
        stackView = NSStackView()
        stackView.orientation = .vertical
        stackView.spacing = 6
        stackView.alignment = .leading
        stackView.translatesAutoresizingMaskIntoConstraints = false

        scrollView = NSScrollView()
        scrollView.documentView = stackView
        scrollView.hasVerticalScroller = true
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.drawsBackground = false
        contentView.addSubview(scrollView)

        stackView.widthAnchor.constraint(equalTo: scrollView.widthAnchor, constant: -20).isActive = true

        // Buttons
        let addButton = NSButton(title: "+ Add Key", target: self, action: #selector(addRow))
        addButton.bezelStyle = .rounded
        let saveButton = NSButton(title: "Save & Apply", target: self, action: #selector(saveAndApply))
        saveButton.bezelStyle = .rounded
        saveButton.keyEquivalent = "\r"

        let buttonBar = NSStackView(views: [addButton, NSView(), saveButton])
        buttonBar.orientation = .horizontal
        buttonBar.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(buttonBar)

        // Layout
        NSLayoutConstraint.activate([
            scopeLabel.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 14),
            scopeLabel.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 16),
            scopeLabel.centerYAnchor.constraint(equalTo: appliesToPopup.centerYAnchor),

            appliesToPopup.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 8),
            appliesToPopup.leadingAnchor.constraint(equalTo: scopeLabel.trailingAnchor, constant: 6),
            appliesToPopup.widthAnchor.constraint(greaterThanOrEqualToConstant: 260),

            addProfileButton.leadingAnchor.constraint(equalTo: appliesToPopup.trailingAnchor, constant: 6),
            addProfileButton.centerYAnchor.constraint(equalTo: appliesToPopup.centerYAnchor),
            addProfileButton.widthAnchor.constraint(equalToConstant: 30),

            removeProfileButton.leadingAnchor.constraint(equalTo: addProfileButton.trailingAnchor, constant: 4),
            removeProfileButton.centerYAnchor.constraint(equalTo: appliesToPopup.centerYAnchor),
            removeProfileButton.widthAnchor.constraint(equalToConstant: 30),

            colHeaders.topAnchor.constraint(equalTo: appliesToPopup.bottomAnchor, constant: 12),
            colHeaders.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 16),
            colHeaders.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -16),

            scrollView.topAnchor.constraint(equalTo: colHeaders.bottomAnchor, constant: 4),
            scrollView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 16),
            scrollView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -16),
            scrollView.bottomAnchor.constraint(equalTo: buttonBar.topAnchor, constant: -12),

            buttonBar.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 16),
            buttonBar.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -16),
            buttonBar.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -16),
            buttonBar.heightAnchor.constraint(equalToConstant: 28),
        ])
    }

    // MARK: - Scope (Default vs per-app profile)

    private var currentProfileIndex: Int? {
        scopeIndex == 0 ? nil : scopeIndex - 1
    }

    private func reloadAppliesToPopup() {
        if scopeIndex > workingConfig.profiles.count { scopeIndex = 0 }
        appliesToPopup.removeAllItems()
        appliesToPopup.addItem(withTitle: "Default (all apps)")
        appliesToPopup.menu?.items.last?.tag = 0
        if !workingConfig.profiles.isEmpty {
            appliesToPopup.menu?.addItem(NSMenuItem.separator())
            appliesToPopup.menu?.items.last?.tag = -99
            for (index, profile) in workingConfig.profiles.enumerated() {
                appliesToPopup.addItem(withTitle: "\(profile.name) — \(profile.bundleID)")
                appliesToPopup.menu?.items.last?.tag = index + 1
            }
        }
        if let item = appliesToPopup.itemArray.first(where: { $0.tag == scopeIndex }) {
            appliesToPopup.select(item)
        }
        removeProfileButton.isEnabled = currentProfileIndex != nil
    }

    @objc private func scopePopupChanged() {
        let newScope = appliesToPopup.selectedItem?.tag ?? 0
        guard newScope != scopeIndex else { return }
        harvestRowsIntoWorkingConfig()
        scopeIndex = newScope
        removeProfileButton.isEnabled = currentProfileIndex != nil
        reloadRows()
    }

    @objc private func addProfile() {
        let panel = NSOpenPanel()
        panel.title = "Choose an app for its profile"
        panel.prompt = "Add Profile"
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.allowedContentTypes = [.applicationBundle]
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }

        let bundleID = Bundle(url: url)?.bundleIdentifier ?? url.deletingPathExtension().lastPathComponent
        let name = FileManager.default.displayName(atPath: url.path)
            .replacingOccurrences(of: ".app", with: "")

        harvestRowsIntoWorkingConfig()

        if let existing = workingConfig.profiles.firstIndex(where: { $0.bundleID == bundleID }) {
            scopeIndex = existing + 1
        } else {
            // Seed a new profile with one placeholder key so the Touch Bar isn't empty
            workingConfig.profiles.append(
                AppProfile(bundleID: bundleID, name: name,
                           keys: [KeyMapping(label: "Space", keyCode: 0x31)])
            )
            scopeIndex = workingConfig.profiles.count
        }
        reloadAppliesToPopup()
        reloadRows()
    }

    @objc private func removeProfile() {
        guard let index = currentProfileIndex,
              workingConfig.profiles.indices.contains(index) else { return }
        let profile = workingConfig.profiles[index]

        let alert = NSAlert()
        alert.messageText = "Remove profile for \(profile.name)?"
        alert.informativeText = "Its custom keys will be discarded. The default layout will be used for this app."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Remove")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        workingConfig.profiles.remove(at: index)
        scopeIndex = 0
        reloadAppliesToPopup()
        reloadRows()
    }

    // MARK: - Rows

    private func currentMappings() -> [KeyMapping] {
        if let index = currentProfileIndex, workingConfig.profiles.indices.contains(index) {
            return workingConfig.profiles[index].keys
        }
        return workingConfig.keys
    }

    private func reloadRows() {
        keyRows.forEach { stackView.removeArrangedSubview($0.container); $0.container.removeFromSuperview() }
        keyRows.removeAll()
        for mapping in currentMappings() {
            addRowWithData(mapping)
        }
    }

    private func addRowWithData(_ mapping: KeyMapping) {
        let upButton = NSButton(image: NSImage(systemSymbolName: "chevron.up", accessibilityDescription: "Move up")!,
                                target: self, action: #selector(moveRowUp(_:)))
        upButton.bezelStyle = .rounded
        upButton.controlSize = .small
        upButton.widthAnchor.constraint(equalToConstant: 22).isActive = true

        let downButton = NSButton(image: NSImage(systemSymbolName: "chevron.down", accessibilityDescription: "Move down")!,
                                  target: self, action: #selector(moveRowDown(_:)))
        downButton.bezelStyle = .rounded
        downButton.controlSize = .small
        downButton.widthAnchor.constraint(equalToConstant: 22).isActive = true

        let labelField = NSTextField(string: mapping.label)
        labelField.widthAnchor.constraint(equalToConstant: 100).isActive = true
        labelField.placeholderString = "Label"

        let actionPopup = NSPopUpButton()
        for action in KeyAction.allCasesInMenu {
            actionPopup.addItem(withTitle: action.displayName)
        }
        actionPopup.selectItem(at: KeyAction.allCasesInMenu.firstIndex(of: mapping.action) ?? 0)
        actionPopup.target = self
        actionPopup.action = #selector(actionPopupChanged(_:))
        actionPopup.widthAnchor.constraint(equalToConstant: 120).isActive = true

        let parameterHolder = NSView()
        parameterHolder.widthAnchor.constraint(equalToConstant: 250).isActive = true
        parameterHolder.heightAnchor.constraint(equalToConstant: 26).isActive = true

        let deleteBtn = NSButton(title: "✕", target: self, action: #selector(deleteRow(_:)))
        deleteBtn.bezelStyle = .rounded
        deleteBtn.widthAnchor.constraint(equalToConstant: 28).isActive = true

        let row = NSStackView(views: [upButton, downButton, labelField, actionPopup, parameterHolder, deleteBtn])
        row.orientation = .horizontal
        row.spacing = 6

        let keyRow = KeyRow(container: row, upButton: upButton, downButton: downButton,
                            labelField: labelField, actionPopup: actionPopup,
                            parameterHolder: parameterHolder, deleteButton: deleteBtn)
        swapParameterView(for: keyRow, with: mapping.action, currentValue: mapping.value, keyCode: mapping.keyCode, modifiers: mapping.modifiers)

        stackView.addArrangedSubview(row)
        keyRows.append(keyRow)
    }

    @objc private func addRow() {
        addRowWithData(KeyMapping(label: "␣", keyCode: 0x31))
    }

    @objc private func deleteRow(_ sender: NSButton) {
        guard let index = keyRows.firstIndex(where: { $0.deleteButton === sender }) else { return }
        let row = keyRows.remove(at: index)
        stackView.removeArrangedSubview(row.container)
        row.container.removeFromSuperview()
    }

    @objc private func moveRowUp(_ sender: NSButton) { moveRow(sender, by: -1) }
    @objc private func moveRowDown(_ sender: NSButton) { moveRow(sender, by: +1) }

    private func moveRow(_ sender: NSButton, by delta: Int) {
        guard let index = keyRows.firstIndex(where: { $0.upButton === sender || $0.downButton === sender }) else { return }
        let target = index + delta
        guard keyRows.indices.contains(target) else { return }
        keyRows.swapAt(index, target)
        stackView.removeArrangedSubview(keyRows[target].container) // was at index
        stackView.insertArrangedSubview(keyRows[target].container, at: target)
    }

    // MARK: - Parameter views (swapped per action)

    @objc private func actionPopupChanged(_ sender: NSPopUpButton) {
        guard let row = keyRows.first(where: { $0.actionPopup === sender }) else { return }
        let action = KeyAction.allCasesInMenu[safe: sender.indexOfSelectedItem] ?? .key
        // Seed a sensible default value when switching actions
        switch action {
        case .mediaKey: swapParameterView(for: row, with: action, currentValue: MediaKeys.all.first?.name, keyCode: 0x31)
        case .windowSnap: swapParameterView(for: row, with: action, currentValue: WindowSnaps.all.first?.name, keyCode: 0x31)
        case .launchApp: swapParameterView(for: row, with: action, currentValue: nil, keyCode: 0x31)
        case .openURL, .shell: swapParameterView(for: row, with: action, currentValue: nil, keyCode: 0x31)
        case .key: swapParameterView(for: row, with: action, currentValue: nil, keyCode: 0x31)
        }
    }

    private func swapParameterView(for row: KeyRow, with action: KeyAction, currentValue: String?, keyCode: Int, modifiers: [String]? = nil) {
        if row.parameterView != nil {
            row.parameterHolder.subviews.forEach { $0.removeFromSuperview() }
        }

        let view: NSView
        switch action {
        case .key:
            let container = NSStackView()
            container.orientation = .horizontal
            container.spacing = 4

            let popup = NSPopUpButton()
            popup.tag = 7001
            popup.widthAnchor.constraint(equalToConstant: 108).isActive = true
            populatePopup(popup)
            if popup.menu?.items.contains(where: { $0.tag == keyCode + tagOffset }) == true {
                popup.selectItem(withTag: keyCode + tagOffset)
            } else {
                popup.selectItem(withTag: 0x31 + tagOffset)
            }
            container.addArrangedSubview(popup)

            // One-tap static modifiers: ⌘ ⇧ ⌥ ⌃ (unioned with physically held keys)
            let modifierDefs: [(glyph: String, name: String)] = [("⌘", "cmd"), ("⇧", "shift"), ("⌥", "option"), ("⌃", "control")]
            for (index, def) in modifierDefs.enumerated() {
                let toggle = NSButton(title: def.glyph, target: nil, action: nil)
                toggle.setButtonType(.pushOnPushOff)
                toggle.bezelStyle = .rounded
                toggle.controlSize = .small
                toggle.font = .systemFont(ofSize: 13, weight: .semibold)
                toggle.tag = 7100 + index
                toggle.state = (modifiers ?? []).contains(def.name) ? .on : .off
                toggle.toolTip = "Hold \(def.name) when this key fires"
                toggle.widthAnchor.constraint(equalToConstant: 26).isActive = true
                container.addArrangedSubview(toggle)
            }
            view = container

        case .mediaKey:
            let popup = NSPopUpButton()
            for (index, entry) in MediaKeys.all.enumerated() {
                popup.addItem(withTitle: entry.name)
                popup.menu?.items.last?.tag = index
            }
            if let value = currentValue,
               let index = MediaKeys.all.firstIndex(where: { $0.name == value }) {
                popup.selectItem(at: index)
            }
            popup.frame = row.parameterHolder.bounds
            view = popup

        case .windowSnap:
            let popup = NSPopUpButton()
            for (index, entry) in WindowSnaps.all.enumerated() {
                popup.addItem(withTitle: entry.name)
                popup.menu?.items.last?.tag = index
            }
            if let value = currentValue,
               let index = WindowSnaps.all.firstIndex(where: { $0.name == value }) {
                popup.selectItem(at: index)
            }
            popup.frame = row.parameterHolder.bounds
            view = popup

        case .launchApp:
            let popup = NSPopUpButton()
            popup.target = self
            popup.action = #selector(appPopupChanged(_:))
            populateAppPopup(popup, for: row, current: currentValue)
            popup.frame = row.parameterHolder.bounds
            view = popup

        case .openURL:
            let field = NSTextField()
            field.placeholderString = "https://example.com"
            field.stringValue = currentValue ?? ""
            field.frame = row.parameterHolder.bounds
            view = field

        case .shell:
            let field = NSTextField()
            field.placeholderString = "e.g. open -a Calculator"
            field.stringValue = currentValue ?? ""
            field.frame = row.parameterHolder.bounds
            view = field
        }

        view.translatesAutoresizingMaskIntoConstraints = false
        row.parameterHolder.addSubview(view)
        NSLayoutConstraint.activate([
            view.leadingAnchor.constraint(equalTo: row.parameterHolder.leadingAnchor),
            view.trailingAnchor.constraint(equalTo: row.parameterHolder.trailingAnchor),
            view.centerYAnchor.constraint(equalTo: row.parameterHolder.centerYAnchor),
        ])
        row.parameterView = view
    }

    // Launch App popup: currently running regular apps + optional Choose App… item
    private func populateAppPopup(_ popup: NSPopUpButton, for row: KeyRow, current: String?) {
        popup.removeAllItems()
        row.appBundleIDs = []

        var seen = Set<String>()
        var apps: [(name: String, bundleID: String)] = []
        for app in NSWorkspace.shared.runningApplications where app.activationPolicy == .regular {
            guard let id = app.bundleIdentifier, !seen.contains(id) else { continue }
            seen.insert(id)
            apps.append((app.localizedName ?? id, id))
        }
        apps.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }

        if let current = current, !current.isEmpty, !seen.contains(current) {
            popup.addItem(withTitle: "\(current) (saved)")
            popup.menu?.items.last?.tag = row.appBundleIDs.count
            row.appBundleIDs.append(current)
        }
        for app in apps {
            popup.addItem(withTitle: app.name)
            popup.menu?.items.last?.tag = row.appBundleIDs.count
            row.appBundleIDs.append(app.bundleID)
        }
        if row.appBundleIDs.isEmpty {
            popup.addItem(withTitle: "No running apps")
            popup.menu?.items.last?.isEnabled = false
            popup.menu?.items.last?.tag = -2
        }
        popup.menu?.addItem(NSMenuItem.separator())
        popup.menu?.items.last?.tag = -99
        let choose = NSMenuItem(title: "Choose App…", action: nil, keyEquivalent: "")
        choose.tag = -1
        popup.menu?.addItem(choose)

        if let current = current, let index = row.appBundleIDs.firstIndex(of: current) {
            popup.selectItem(at: index)
        }
    }

    @objc private func appPopupChanged(_ sender: NSPopUpButton) {
        guard let row = keyRows.first(where: { $0.parameterView === sender }) else { return }
        guard sender.selectedItem?.tag == -1 else { return }

        let panel = NSOpenPanel()
        panel.title = "Choose an app"
        panel.prompt = "Select"
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.allowedContentTypes = [.applicationBundle]
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else {
            // Restore selection to first real entry
            sender.selectItem(at: 0)
            return
        }
        let bundleID = Bundle(url: url)?.bundleIdentifier ?? url.path
        let name = FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
        row.appBundleIDs.append(bundleID)
        let insertIndex = max(0, sender.itemArray.count - 2) // before the separator + Choose App…
        sender.insertItem(withTitle: name, at: insertIndex)
        sender.itemArray[insertIndex].tag = row.appBundleIDs.count - 1
        sender.selectItem(at: insertIndex)
    }

    // MARK: - Harvest rows → working config

    private func harvestRowsIntoWorkingConfig() {
        var mappings: [KeyMapping] = []
        for row in keyRows {
            let label = row.labelField.stringValue.trimmingCharacters(in: .whitespaces)
            let action = KeyAction.allCasesInMenu[safe: row.actionPopup.indexOfSelectedItem] ?? .key

            var keyCode = 0
            var value: String? = nil
            var modifiers: [String]? = nil

            switch action {
            case .key:
                if let container = row.parameterView as? NSStackView {
                    if let popup = container.viewWithTag(7001) as? NSPopUpButton {
                        keyCode = (popup.selectedItem?.tag ?? (0x31 + tagOffset)) - tagOffset
                        if keyCode < 0 { keyCode = 0x31 }
                    }
                    let modNames = ["cmd", "shift", "option", "control"]
                    let picked = modNames.enumerated()
                        .filter { (container.viewWithTag(7100 + $0.offset) as? NSButton)?.state == .on }
                        .map { $0.element }
                    modifiers = picked.isEmpty ? nil : picked
                }
            case .mediaKey:
                if let popup = row.parameterView as? NSPopUpButton,
                   MediaKeys.all.indices.contains(popup.indexOfSelectedItem) {
                    value = MediaKeys.all[popup.indexOfSelectedItem].name
                }
            case .windowSnap:
                if let popup = row.parameterView as? NSPopUpButton,
                   WindowSnaps.all.indices.contains(popup.indexOfSelectedItem) {
                    value = WindowSnaps.all[popup.indexOfSelectedItem].name
                }
            case .launchApp:
                if let popup = row.parameterView as? NSPopUpButton {
                    let index = popup.indexOfSelectedItem
                    if row.appBundleIDs.indices.contains(index) { value = row.appBundleIDs[index] }
                }
            case .openURL, .shell:
                if let field = row.parameterView as? NSTextField {
                    let trimmed = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
                    value = trimmed.isEmpty ? nil : trimmed
                }
            }

            let finalLabel = label.isEmpty ? emptyLabelFallback(action: action, value: value, keyCode: keyCode) : label
            mappings.append(KeyMapping(label: finalLabel, keyCode: keyCode, action: action, value: value, modifiers: modifiers))
        }

        if let index = currentProfileIndex, workingConfig.profiles.indices.contains(index) {
            workingConfig.profiles[index].keys = mappings
        } else {
            workingConfig.keys = mappings
        }
    }

    private func emptyLabelFallback(action: KeyAction, value: String?, keyCode: Int) -> String {
        switch action {
        case .key: return KeyCodes.defaultLabel(for: keyCode)
        case .mediaKey: return MediaKeys.defaultLabel(forValue: value)
        case .windowSnap: return WindowSnaps.defaultLabel(forValue: value)
        case .launchApp: return value?.split(separator: ".").last.map { String($0).capitalized } ?? "App"
        case .openURL: return "URL"
        case .shell: return "$_"
        }
    }

    // MARK: - Save

    @objc private func saveAndApply() {
        harvestRowsIntoWorkingConfig()
        configManager.updateConfig(workingConfig)
        onSave()
        window?.close()
    }

    // MARK: - Populate Key Popup

    private func populatePopup(_ popup: NSPopUpButton) {
        popup.removeAllItems()
        for category in KeyCodes.categories {
            let keys = KeyCodes.allKeys.filter { $0.category == category }
            if keys.isEmpty { continue }

            if popup.numberOfItems > 0 {
                popup.menu?.addItem(NSMenuItem.separator())
            }
            let header = NSMenuItem(title: "— \(category) —", action: nil, keyEquivalent: "")
            header.isEnabled = false
            header.tag = -1
            popup.menu?.addItem(header)

            for key in keys {
                let item = NSMenuItem(title: key.name, action: nil, keyEquivalent: "")
                item.tag = key.code + tagOffset
                popup.menu?.addItem(item)
            }
        }
    }
}

// MARK: - Safe index helper

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
