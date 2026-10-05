import AppKit
import ApplicationServices

/// Where focus was when the hotkey fired, so the paste lands there even if
/// the window or field lost key status while the panel was up. Memory only.
struct PasteTarget {
    let app: NSRunningApplication
    let window: AXUIElement?
    let element: AXUIElement?

    /// Call before showing the panel, while the user's app is still frontmost.
    static func capture() -> PasteTarget? {
        guard let app = NSWorkspace.shared.frontmostApplication, app != .current else { return nil }
        guard AXIsProcessTrusted() else { return PasteTarget(app: app, window: nil, element: nil) }

        let axApp = AXUIElementCreateApplication(app.processIdentifier)
        // A hung target app must not freeze ClipB.
        AXUIElementSetMessagingTimeout(axApp, 0.5)
        return PasteTarget(
            app: app,
            window: attribute(axApp, kAXFocusedWindowAttribute),
            element: attribute(axApp, kAXFocusedUIElementAttribute)
        )
    }

    /// Re-activates the app if needed, then refocuses the window and field.
    func restoreFocus() {
        if NSWorkspace.shared.frontmostApplication != app {
            app.activate(options: [])
        }
        guard AXIsProcessTrusted() else { return }
        if let window {
            AXUIElementPerformAction(window, kAXRaiseAction as CFString)
            AXUIElementSetAttributeValue(window, kAXMainAttribute as CFString, kCFBooleanTrue)
        }
        if let element {
            AXUIElementSetAttributeValue(element, kAXFocusedAttribute as CFString, kCFBooleanTrue)
        }
    }

    private static func attribute(_ element: AXUIElement, _ name: String) -> AXUIElement? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success,
              let value, CFGetTypeID(value) == AXUIElementGetTypeID()
        else { return nil }
        return (value as! AXUIElement)
    }
}
