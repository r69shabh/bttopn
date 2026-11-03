import Cocoa

// MARK: - Clipboard History
//
// A small, privacy-conscious clipboard history (text only).
//
//   - OFF by default; menu bar → Clipboard History → Enabled toggles it.
//   - In-memory only — nothing is written to disk. Quitting clears history.
//   - Concealed/transient pasteboards (password managers) are never stored.
//   - Polls NSPasteboard.changeCount on a 0.5s timer ONLY while enabled,
//     so there is zero overhead (and zero clipboard snooping) when off.

final class ClipboardHistory {

    static let shared = ClipboardHistory()

    /// Called on the main thread whenever the history changes.
    var onChange: (() -> Void)?

    let maxItems = 20

    private(set) var items: [String] = []
    private var timer: Timer?
    private var lastChangeCount: Int

    static let enabledKey = "clipboardHistoryEnabled"

    private init() {
        lastChangeCount = NSPasteboard.general.changeCount
    }

    var isEnabled: Bool {
        UserDefaults.standard.bool(forKey: Self.enabledKey)
    }

    func setEnabled(_ enabled: Bool) {
        UserDefaults.standard.set(enabled, forKey: Self.enabledKey)
        if enabled {
            start()
        } else {
            stop()
            items.removeAll()
            onChange?()
        }
    }

    func start() {
        stop()
        lastChangeCount = NSPasteboard.general.changeCount
        let timer = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in
            self?.poll()
        }
        timer.tolerance = 0.1
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    func clear() {
        items.removeAll()
        onChange?()
    }

    // MARK: - Polling

    private func poll() {
        let pasteboard = NSPasteboard.general
        guard pasteboard.changeCount != lastChangeCount else { return }
        lastChangeCount = pasteboard.changeCount

        let types = pasteboard.types?.map(\.rawValue) ?? []
        guard let text = pasteboard.string(forType: .string) else { return }
        guard ClipboardFilter.shouldStore(types: types, text: text) else { return }

        if items.first == text { return } // consecutive duplicate
        items.insert(text, at: 0)
        if items.count > maxItems { items.removeLast() }
        onChange?()
    }

    // MARK: - Preview for menu titles

    static func preview(_ text: String, maxLength: Int = 48) -> String {
        let firstLine = text.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
        let collapsed = firstLine.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        if collapsed.count <= maxLength { return collapsed }
        return String(collapsed.prefix(maxLength - 1)) + "…"
    }

    // MARK: - Paste a history item into the frontmost app

    static func pasteText(_ text: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        usleep(50_000) // let the pasteboard propagate before ⌘V
        KeySimulator.simulateKeyPress(keyCode: 0x09, modifiers: ["cmd"]) // ⌘V
    }
}
