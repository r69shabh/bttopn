import Cocoa

// MARK: - Window Snap Definitions

enum WindowSnaps {

    struct Entry {
        let name: String    // stored in config, shown in the editor popup
        let label: String   // short label shown on the Touch Bar
    }

    static let all: [Entry] = [
        Entry(name: "Left Half",  label: "Left ½"),
        Entry(name: "Right Half", label: "Right ½"),
        Entry(name: "Left Third", label: "Left ⅓"),
        Entry(name: "Right Third",label: "Right ⅓"),
        Entry(name: "Maximize",   label: "Fill"),
        Entry(name: "Center",     label: "Center"),
    ]

    static func entry(named name: String) -> Entry? {
        all.first { $0.name == name }
    }

    static func defaultLabel(forValue value: String?) -> String {
        value.flatMap { entry(named: $0)?.label } ?? "▢"
    }
}

// MARK: - Window Manager
//
// Snaps the frontmost app's focused window using the Accessibility API.
// Requires the same Accessibility permission bttopn already needs for
// CGEvent posting.
//
// Coordinate systems: AX uses global coords with origin at the top-left of
// the primary display (y-down). NSScreen uses bottom-left origin (y-up).
// Convert with primaryScreenHeight().

enum WindowManager {

    static func snap(_ name: String) {
        guard WindowSnaps.entry(named: name) != nil else { return }
        guard let window = focusedWindow(),
              let axFrame = windowFrameAX(window) else {
            NSLog("bttopn: window snap — no focused window (or Accessibility not granted)")
            return
        }
        guard let screen = screen(containingAXFrame: axFrame) else { return }
        let target = targetFrame(for: name, in: screen)
        setFrame(target, of: window)
    }

    // MARK: - Focused window

    private static func focusedWindow() -> AXUIElement? {
        let system = AXUIElementCreateSystemWide()
        var appRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(system, kAXFocusedApplicationAttribute as CFString, &appRef) == .success,
              let appRef = appRef else { return nil }
        var windowRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(appRef as! AXUIElement, kAXFocusedWindowAttribute as CFString, &windowRef) == .success,
              let windowRef = windowRef else { return nil }
        return (windowRef as! AXUIElement)
    }

    // MARK: - Frames

    private static func primaryScreenHeight() -> CGFloat {
        NSScreen.screens.first?.frame.height ?? 0
    }

    /// AX y of a Cocoa rect's top edge.
    private static func axY(ofCocoaY y: CGFloat, height: CGFloat) -> CGFloat {
        primaryScreenHeight() - (y + height)
    }

    /// A screen expressed in AX coordinates (for intersection math).
    private static func axFrame(of screen: NSScreen) -> CGRect {
        let f = screen.frame
        return CGRect(x: f.origin.x, y: axY(ofCocoaY: f.origin.y, height: f.height),
                      width: f.width, height: f.height)
    }

    private static func windowFrameAX(_ window: AXUIElement) -> CGRect? {
        var posRef: CFTypeRef?
        var sizeRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(window, kAXPositionAttribute as CFString, &posRef) == .success,
              AXUIElementCopyAttributeValue(window, kAXSizeAttribute as CFString, &sizeRef) == .success,
              let posRef = posRef, let sizeRef = sizeRef else { return nil }
        var point = CGPoint.zero, size = CGSize.zero
        AXValueGetValue(posRef as! AXValue, .cgPoint, &point)
        AXValueGetValue(sizeRef as! AXValue, .cgSize, &size)
        return CGRect(origin: point, size: size)
    }

    private static func screen(containingAXFrame frame: CGRect) -> NSScreen? {
        func area(_ a: CGRect, _ b: CGRect) -> CGFloat {
            let i = a.intersection(b)
            return i.isNull ? 0 : i.width * i.height
        }
        return NSScreen.screens.max(by: { area(axFrame(of: $0), frame) < area(axFrame(of: $1), frame) })
            ?? NSScreen.main
    }

    /// Target rect in AX coordinates, based on the screen's visible frame
    /// (menu bar / Dock excluded).
    private static func targetFrame(for snap: String, in screen: NSScreen) -> CGRect {
        let vf = screen.visibleFrame // Cocoa coords
        let axFrameY = axY(ofCocoaY: vf.origin.y, height: vf.height)
        let full = CGRect(x: vf.origin.x, y: axFrameY, width: vf.width, height: vf.height)

        switch snap {
        case "Left Half":   return CGRect(x: full.minX, y: full.minY, width: full.width / 2, height: full.height)
        case "Right Half":  return CGRect(x: full.midX, y: full.minY, width: full.width / 2, height: full.height)
        case "Left Third":  return CGRect(x: full.minX, y: full.minY, width: full.width / 3, height: full.height)
        case "Right Third": return CGRect(x: full.maxX - full.width / 3, y: full.minY, width: full.width / 3, height: full.height)
        case "Maximize":    return full
        case "Center":
            let w = full.width * 0.6, h = full.height * 0.75
            return CGRect(x: full.midX - w / 2, y: full.midY - h / 2, width: w, height: h)
        default:            return full
        }
    }

    private static func setFrame(_ target: CGRect, of window: AXUIElement) {
        var point = target.origin
        var size = target.size
        guard let axPoint = AXValueCreate(.cgPoint, &point),
              let axSize = AXValueCreate(.cgSize, &size) else { return }
        // Size first, then position: some apps clamp resize against the
        // pre-move edge if the order is reversed.
        AXUIElementSetAttributeValue(window, kAXSizeAttribute as CFString, axSize)
        AXUIElementSetAttributeValue(window, kAXPositionAttribute as CFString, axPoint)
        AXUIElementSetAttributeValue(window, kAXSizeAttribute as CFString, axSize)
    }
}
