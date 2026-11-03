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

    /// Call before showing the panel: the AX key window may belong to a
    /// non-activating panel of an app that is not NSWorkspace's frontmost.
    /// `fallbackToFrontmost` = false refuses a guess when the key app can't
    /// be resolved — pasting into the frontmost app can hit the wrong one.
    static func capture(fallbackToFrontmost: Bool = true) -> PasteTarget? {
        guard let app = focusedApplication(allowFrontmostFallback: fallbackToFrontmost),
              app != .current
        else {
            devLog("capture: no target (focused app is ClipB or unknown)")
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
        for element in [target.window, target.element].compactMap({ $0 }) {
            AXUIElementSetMessagingTimeout(element, 0.5)
        }
        devLog("capture: \(app.bundleIdentifier ?? "?") pid=\(app.processIdentifier) window=\(target.window != nil) element=\(target.element != nil)")
        return target
    }

    /// True only when the focused element reports its selected text and it
    /// is empty. Nil when it can't tell (no Accessibility, or the app does not
    /// report a selection, like Ghostty). Any thread; reads no text into logs.
    static func focusedSelectionIsEmpty() -> Bool? {
        guard AXIsProcessTrusted() else { return nil }
        let system = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(system, 0.1)
        guard let element = attribute(system, kAXFocusedUIElementAttribute) else { return nil }
        AXUIElementSetMessagingTimeout(element, 0.1)
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXSelectedTextAttribute as CFString, &value) == .success,
              let text = value as? String
        else { return nil }
        return text.isEmpty
    }

    /// Screen rect of the current selection, in AppKit coordinates, so the
    /// chooser can open just under it. nil whenever AX cannot say.
    func selectionBounds() -> NSRect? {
        guard AXIsProcessTrusted() else { return nil }
        // A window has no selected range itself; its focused element might.
        let focused = window.flatMap { Self.attribute($0, kAXFocusedUIElementAttribute) }
        for candidate in [element, focused, window].compactMap({ $0 }) {
            if let rect = Self.selectionBounds(in: candidate) { return rect }
        }
        return nil
    }

    /// Where the chooser anchors: under the selection, else at the caret, else
    /// at the focused element. The pointer is the caller's last resort — it can
    /// rest on another screen than the text being edited.
    func anchorBounds() -> NSRect? {
        textBounds() ?? fieldBounds()
    }

    /// The selection, else the caret: where the user's eyes are. Nil in apps
    /// that do not report text bounds over AX (Ghostty, many terminals).
    func textBounds() -> NSRect? {
        selectionBounds() ?? caretBounds()
    }

    /// The focused window's frame, in AppKit coordinates.
    func windowBounds() -> NSRect? {
        guard AXIsProcessTrusted(), let window else { return nil }
        return Self.elementBounds(window)
    }

    /// The focused field (or window) as a whole.
    func fieldBounds() -> NSRect? {
        focusedElementBounds()
    }

    /// The caret's rect when nothing is selected: the focused element's
    /// selected-text range is empty there, but bounds-for-range still resolves.
    private func caretBounds() -> NSRect? {
        guard AXIsProcessTrusted() else { return nil }
        let focused = window.flatMap { Self.attribute($0, kAXFocusedUIElementAttribute) }
        for candidate in [element, focused, window].compactMap({ $0 }) {
            if let rect = Self.selectionBounds(in: candidate, allowEmpty: true) { return rect }
        }
        return nil
    }

    /// The focused element's own rect — the field being typed in — when
    /// neither selection nor caret is readable; the window is the last stop.
    private func focusedElementBounds() -> NSRect? {
        guard AXIsProcessTrusted() else { return nil }
        let focused = window.flatMap { Self.attribute($0, kAXFocusedUIElementAttribute) }
        for candidate in [element, focused, window].compactMap({ $0 }) {
            if let rect = Self.elementBounds(candidate) { return rect }
        }
        return nil
    }

    private static func elementBounds(_ element: AXUIElement) -> NSRect? {
        guard let position = axValue(element, kAXPositionAttribute),
              let size = axValue(element, kAXSizeAttribute),
              let primary = NSScreen.screens.first
        else { return nil }
        var point = CGPoint.zero, dimensions = CGSize.zero
        guard AXValueGetType(position) == .cgPoint, AXValueGetValue(position, .cgPoint, &point),
              AXValueGetType(size) == .cgSize, AXValueGetValue(size, .cgSize, &dimensions),
              dimensions.width > 0, dimensions.height > 0
        else { return nil }
        // AX is top-left origin; NSRect is bottom-left.
        return NSRect(x: point.x, y: primary.frame.maxY - point.y - dimensions.height, width: dimensions.width, height: dimensions.height)
    }

    private static func selectionBounds(in element: AXUIElement, allowEmpty: Bool = false) -> NSRect? {
        guard let range = axValue(element, kAXSelectedTextRangeAttribute),
              let bounds = parameterized(element, kAXBoundsForRangeParameterizedAttribute, range),
              let primary = NSScreen.screens.first
        else { return nil }
        var rect = CGRect.zero
        // A caret's bounds-for-range is zero-width; anything fully zero is unreadable garbage.
        guard AXValueGetType(bounds) == .cgRect, AXValueGetValue(bounds, .cgRect, &rect),
              (allowEmpty ? rect != .zero : !rect.isEmpty) else { return nil }
        // AX is top-left origin; NSRect is bottom-left.
        return NSRect(x: rect.minX, y: primary.frame.maxY - rect.maxY, width: rect.width, height: rect.height)
    }

    /// Returns key focus to the captured window and field, without activating
    /// the target app wherever AX allows: CGEvent Cmd+V lands in the key
    /// window, so the frontmost app stays undisturbed even when the target is
    /// a non-activating panel of a background app. `completion(false)` means
    /// focus could not be restored, so the caller must not send keystrokes:
    /// they would land in the wrong window.
    func restoreFocus(completion: @escaping (_ focused: Bool) -> Void) {
        // AX refocus first: deterministic, and a no-op when key already returned.
        if AXIsProcessTrusted(), let window {
            refocus()
            let started = Date()
            waitUntilKeyFocus(on: window, until: started.addingTimeInterval(0.5)) { restored in
                devLog("restore: AX refocus retook key after \(Int(Date().timeIntervalSince(started) * 1000)) ms: \(restored)")
                guard restored else { return activate(completion) }
                // Let the window take key status before the keystroke.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { completion(true) }
            }
            return
        }
        activate(completion)
    }

    /// Dismissal without a paste: key focus back to the captured window via
    /// AX alone, never activating anything. Silent when AX can't help.
    func refocusKey() {
        refocus()
    }

    /// Fallback once AX refocus is unavailable or failed: cooperative
    /// activation, then the keystroke once the app is frontmost.
    private func activate(_ completion: @escaping (_ focused: Bool) -> Void) {
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

    private func waitUntilKeyFocus(on window: AXUIElement, until deadline: Date, then done: @escaping (Bool) -> Void) {
        let systemWide = AXUIElementCreateSystemWide()
        // Global default is seconds-long; a busy app must not stall the main thread.
        AXUIElementSetMessagingTimeout(systemWide, 0.5)
        if let focused = Self.attribute(systemWide, kAXFocusedWindowAttribute),
           CFEqual(focused, window) { return done(true) }
        if Date() >= deadline { return done(false) }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            waitUntilKeyFocus(on: window, until: deadline, then: done)
        }
    }

    // The key window's app, not NSWorkspace's frontmost: a non-activating panel (Ghostty quick terminal) holds key focus while another app stays frontmost.
    private static func focusedApplication(allowFrontmostFallback: Bool) -> NSRunningApplication? {
        if AXIsProcessTrusted(),
           let focused = attribute(AXUIElementCreateSystemWide(), kAXFocusedApplicationAttribute) {
            var pid: pid_t = 0
            if AXUIElementGetPid(focused, &pid) == .success, pid > 0,
               let app = NSRunningApplication(processIdentifier: pid) {
                return app
            }
        }
        guard allowFrontmostFallback else { return nil }
        return NSWorkspace.shared.frontmostApplication
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

    /// `kAXSelectedTextRangeAttribute`-style value: an AXValue wrapping a range.
    private static func axValue(_ element: AXUIElement, _ name: String) -> AXValue? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success,
              let value, CFGetTypeID(value) == AXValueGetTypeID()
        else { return nil }
        return (value as! AXValue)
    }

    private static func parameterized(_ element: AXUIElement, _ name: String, _ parameter: AXValue) -> AXValue? {
        var value: CFTypeRef?
        guard AXUIElementCopyParameterizedAttributeValue(element, name as CFString, parameter, &value) == .success,
              let value, CFGetTypeID(value) == AXValueGetTypeID()
        else { return nil }
        return (value as! AXValue)
    }
}
