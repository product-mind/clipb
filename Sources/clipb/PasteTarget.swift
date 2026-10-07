import AppKit
import ApplicationServices

/// Where focus was when the hotkey fired, so the paste lands there even if
/// the window or field lost focus, or the user switched apps, in between.
/// Memory only.
struct PasteTarget {
    let app: NSRunningApplication
    let axApp: AXUIElement?
    let window: AXUIElement?
    let element: AXUIElement?

    /// Call before showing the panel, while the user's app is still frontmost.
    static func capture() -> PasteTarget? {
        guard let app = NSWorkspace.shared.frontmostApplication, app != .current else {
            devLog("capture: no target (frontmost is ClipB or unknown)")
            return nil
        }
        guard AXIsProcessTrusted() else {
            devLog("capture: \(app.bundleIdentifier ?? "?") but Accessibility not trusted; app only")
            return PasteTarget(app: app, axApp: nil, window: nil, element: nil)
        }

        let axApp = AXUIElementCreateApplication(app.processIdentifier)
        // A hung target app must not freeze ClipB.
        AXUIElementSetMessagingTimeout(axApp, 0.5)
        let target = PasteTarget(
            app: app,
            axApp: axApp,
            window: attribute(axApp, kAXFocusedWindowAttribute),
            element: attribute(axApp, kAXFocusedUIElementAttribute)
        )
        devLog("capture: \(app.bundleIdentifier ?? "?") pid=\(app.processIdentifier) window=\(target.window != nil) element=\(target.element != nil)")
        return target
    }

    /// Brings the app back to the front, then refocuses the window and field.
    /// `completion(false)` means the app never came forward, so the caller
    /// must not send keystrokes: they would land in the wrong app.
    func restoreFocus(completion: @escaping (_ focused: Bool) -> Void) {
        let frontmostNow = NSWorkspace.shared.frontmostApplication
        devLog("restore: target=\(app.bundleIdentifier ?? "?") frontmost=\(frontmostNow?.bundleIdentifier ?? "?")")
        if frontmostNow != app {
            // AX "frontmost" isn't subject to cooperative activation.
            if let axApp, AXIsProcessTrusted() {
                let result = AXUIElementSetAttributeValue(axApp, kAXFrontmostAttribute as CFString, kCFBooleanTrue)
                devLog("restore: AX frontmost result=\(result.rawValue)")
            }
            app.activate(options: [])
        }
        let started = Date()
        waitUntilFrontmost(until: started.addingTimeInterval(1)) { frontmost in
            devLog("restore: frontmost=\(frontmost) after \(Int(Date().timeIntervalSince(started) * 1000)) ms")
            guard frontmost else { return completion(false) }
            refocus()
            // Let the window take key status before the keystroke.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { completion(true) }
        }
    }

    private func refocus() {
        guard AXIsProcessTrusted() else { return }
        if let window {
            let raise = AXUIElementPerformAction(window, kAXRaiseAction as CFString)
            let main = AXUIElementSetAttributeValue(window, kAXMainAttribute as CFString, kCFBooleanTrue)
            devLog("refocus: window raise=\(raise.rawValue) main=\(main.rawValue)")
        }
        if let element {
            let focused = AXUIElementSetAttributeValue(element, kAXFocusedAttribute as CFString, kCFBooleanTrue)
            devLog("refocus: element focused=\(focused.rawValue)")
        }
        if let axApp, let window, let now = Self.attribute(axApp, kAXFocusedWindowAttribute) {
            devLog("refocus: focused window is the original=\(CFEqual(now, window))")
        }
    }

    private func waitUntilFrontmost(until deadline: Date, then done: @escaping (Bool) -> Void) {
        if NSWorkspace.shared.frontmostApplication == app { return done(true) }
        if Date() >= deadline { return done(false) }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            waitUntilFrontmost(until: deadline, then: done)
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
