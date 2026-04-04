import Cocoa

// MARK: - Edit Keys Window Controller

class EditKeysWindowController: NSWindowController {

    private let configManager: ConfigManager
    private let onSave: () -> Void

    private var scrollView: NSScrollView!
    private var stackView: NSStackView!
    private var keyRows: [KeyRow] = []

    // Tag offset to avoid conflicts with separator/header items in popup
    private let tagOffset = 1000

    struct KeyRow {
        let container: NSStackView
        let labelField: NSTextField
        let keyPopup: NSPopUpButton
        let deleteButton: NSButton
    }

    init(configManager: ConfigManager, onSave: @escaping () -> Void) {
        self.configManager = configManager
        self.onSave = onSave

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 480, height: 420),
            styleMask: [.titled, .closable],
            backing: .buffered, defer: false
        )
        window.title = "Edit Touch Bar Keys"
        window.center()
        window.isReleasedWhenClosed = false

        super.init(window: window)
        setupUI()
        loadCurrentConfig()
    }

    required init?(coder: NSCoder) { fatalError() }

    // MARK: - UI Setup

    private func setupUI() {
        guard let contentView = window?.contentView else { return }

        // Header
        let header = NSTextField(labelWithString: "Configure your Touch Bar keys:")
        header.font = NSFont.systemFont(ofSize: 13, weight: .medium)
        header.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(header)

        // Column labels
        let colLabel = NSTextField(labelWithString: "Label")
        colLabel.font = NSFont.systemFont(ofSize: 11, weight: .semibold)
        colLabel.textColor = .secondaryLabelColor
        let colKey = NSTextField(labelWithString: "Key")
        colKey.font = NSFont.systemFont(ofSize: 11, weight: .semibold)
        colKey.textColor = .secondaryLabelColor
        let colDel = NSTextField(labelWithString: "")
        colDel.widthAnchor.constraint(equalToConstant: 28).isActive = true

        let colHeaders = NSStackView(views: [colLabel, colKey, colDel])
        colHeaders.orientation = .horizontal
        colHeaders.spacing = 8
        colHeaders.translatesAutoresizingMaskIntoConstraints = false
        colLabel.widthAnchor.constraint(equalToConstant: 100).isActive = true
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

        // Pin stack view width to scroll view
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
            header.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 16),
            header.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 16),

            colHeaders.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 12),
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

    // MARK: - Load current config into UI

    private func loadCurrentConfig() {
        // Clear existing rows
        keyRows.forEach { stackView.removeArrangedSubview($0.container); $0.container.removeFromSuperview() }
        keyRows.removeAll()

        for mapping in configManager.config.keys {
            addRowWithData(label: mapping.label, keyCode: mapping.keyCode)
        }
    }

    // MARK: - Row Management

    private func addRowWithData(label: String, keyCode: Int) {
        let labelField = NSTextField(string: label)
        labelField.widthAnchor.constraint(equalToConstant: 100).isActive = true
        labelField.placeholderString = "Label"

        let popup = NSPopUpButton()
        popup.removeAllItems()
        populatePopup(popup)
        popup.selectItem(withTag: keyCode + tagOffset)
        popup.widthAnchor.constraint(greaterThanOrEqualToConstant: 140).isActive = true

        let deleteBtn = NSButton(title: "✕", target: self, action: #selector(deleteRow(_:)))
        deleteBtn.bezelStyle = .rounded
        deleteBtn.widthAnchor.constraint(equalToConstant: 28).isActive = true

        let row = NSStackView(views: [labelField, popup, deleteBtn])
        row.orientation = .horizontal
        row.spacing = 8

        stackView.addArrangedSubview(row)
        keyRows.append(KeyRow(container: row, labelField: labelField, keyPopup: popup, deleteButton: deleteBtn))
    }

    @objc private func addRow() {
        // Default to Space key
        addRowWithData(label: "␣", keyCode: 0x31)
    }

    @objc private func deleteRow(_ sender: NSButton) {
        guard let index = keyRows.firstIndex(where: { $0.deleteButton === sender }) else { return }
        let row = keyRows.remove(at: index)
        stackView.removeArrangedSubview(row.container)
        row.container.removeFromSuperview()
    }

    // MARK: - Save

    @objc private func saveAndApply() {
        var mappings: [KeyMapping] = []
        for row in keyRows {
            let label = row.labelField.stringValue.isEmpty ? "?" : row.labelField.stringValue
            let keyCode = (row.keyPopup.selectedItem?.tag ?? (0x31 + tagOffset)) - tagOffset
            mappings.append(KeyMapping(label: label, keyCode: keyCode))
        }
        configManager.updateConfig(KeyConfig(keys: mappings))
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
