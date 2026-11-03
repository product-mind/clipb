import AppKit

/// Where a chooser-style panel opens: above `point`, clamped into the visible
/// area of the screen holding it. Pure, so the clamping is testable.
/// Knobs for where ClipB's panels open (SPEC §2.10). Experimental: tweak
/// here, `make`, try it. `PanelGeometry` reads only these.
enum PanelPlacement {
    /// Every keyboard-opened panel opens centered on the focused window,
    /// never at the caret or the pointer (MODAL.md). False: the caret and
    /// pointer rules below apply again. Only a window-less target (no
    /// Accessibility, or the app reports no window) falls through to them.
    static let alwaysCenterOnWindow = true
    /// Points between the selection or caret and the panel's top edge.
    static let gapBelowText: CGFloat = 8
    /// No caret, pointer inside the focused window: open at the pointer.
    static let followPointerInsideWindow = true
    /// No caret, pointer outside the focused window: open centered on it.
    static let centerOnWindowWhenPointerOutside = true
    /// Where on the window a centered panel's middle sits, from the top:
    /// 0.5 = dead center, 0.33 = upper third (Spotlight-like).
    static let windowCenterFromTop: CGFloat = 0.5
    /// A panel that would stick out of the focused window is pulled back
    /// inside it, when it fits. The screen clamp still runs after.
    static let keepInsideWindow = true
}

/// Where a panel opens. `centered`: the panel's middle goes on `point`;
/// otherwise its top-left corner does.
struct PanelAnchor: Equatable {
    enum Source: Equatable { case text, pointer, window, field }

    var point: NSPoint
    var centered = false
    /// The focused window, for `PanelPlacement.keepInsideWindow`.
    var window: NSRect? = nil
    var source: Source = .pointer

    init(_ point: NSPoint, centered: Bool = false, window: NSRect? = nil, source: Source = .pointer) {
        self.point = point
        self.centered = centered
        self.window = window
        self.source = source
    }
}

enum PanelGeometry {
    /// Where a panel tied to the user's typing opens, first match wins:
    /// just under the selection or caret; the pointer while it rests inside
    /// the focused field or window (Ghostty reports only the whole field,
    /// whose bottom edge can be a screen away from the prompt); centered on
    /// the focused window when the pointer is outside it; under the field;
    /// the pointer. Pure; `PanelPlacement` holds the knobs.
    static func anchor(text: NSRect?, field: NSRect?, window: NSRect? = nil, pointer: NSPoint) -> PanelAnchor {
        let gap = PanelPlacement.gapBelowText
        if PanelPlacement.alwaysCenterOnWindow, let window {
            let y = window.maxY - window.height * PanelPlacement.windowCenterFromTop
            return PanelAnchor(NSPoint(x: window.midX, y: y), centered: true, window: window, source: .window)
        }
        if let text {
            return PanelAnchor(NSPoint(x: text.midX, y: text.minY - gap), window: window, source: .text)
        }
        if let field, NSMouseInRect(pointer, field, false) {
            return PanelAnchor(pointer, window: window, source: .pointer)
        }
        if let window {
            if NSMouseInRect(pointer, window, false) {
                if PanelPlacement.followPointerInsideWindow {
                    return PanelAnchor(pointer, window: window, source: .pointer)
                }
            } else if PanelPlacement.centerOnWindowWhenPointerOutside {
                let y = window.maxY - window.height * PanelPlacement.windowCenterFromTop
                return PanelAnchor(NSPoint(x: window.midX, y: y), centered: true, window: window, source: .window)
            }
        }
        if let field {
            return PanelAnchor(NSPoint(x: field.midX, y: field.minY - gap), window: window, source: .field)
        }
        return PanelAnchor(pointer, window: window, source: .pointer)
    }

    static func origin(size: NSSize, near anchor: PanelAnchor, screens: [(frame: NSRect, visible: NSRect)]) -> NSPoint {
        var frame = NSRect(origin: .zero, size: size)
        if anchor.centered {
            frame.origin = NSPoint(x: anchor.point.x - size.width / 2, y: anchor.point.y - size.height / 2)
        } else {
            frame.origin = NSPoint(x: anchor.point.x, y: anchor.point.y - size.height)
        }
        if PanelPlacement.keepInsideWindow, let window = anchor.window,
           size.width <= window.width, size.height <= window.height {
            frame = clamped(frame, into: window)
        }
        // The window clamp moved the panel; the screen check uses its new top-left.
        return origin(size: size, near: NSPoint(x: frame.minX, y: frame.maxY), screens: screens)
    }

    static func origin(size: NSSize, near point: NSPoint, screens: [(frame: NSRect, visible: NSRect)]) -> NSPoint {
        var origin = NSPoint(x: point.x, y: point.y - size.height)
        // NSMouseInRect misses points exactly on an edge (a caret on a screen's
        // bottom row) and points in the gaps between screens; falling back to
        // the nearest screen keeps the panel on some screen either way.
        guard let screen = screens.first(where: { NSMouseInRect(point, $0.frame, false) })
            ?? screens.min(by: { distance(from: point, to: $0.frame) < distance(from: point, to: $1.frame) })
        else { return origin }
        let area = screen.visible
        origin.x = min(max(origin.x, area.minX), area.maxX - size.width)
        origin.y = min(max(origin.y, area.minY), area.maxY - size.height)
        return origin
    }

    /// `preferred` shrunk by `padding` so it fits the visible area of the
    /// screen holding `point`, never below `minimum`. The nearest-screen
    /// fallback matches `origin`, so a gap or edge anchor still shrinks to fit.
    static func constrainedSize(
        _ preferred: NSSize,
        minimum: NSSize = .zero,
        padding: NSSize,
        near point: NSPoint,
        screens: [(frame: NSRect, visible: NSRect)]
    ) -> NSSize {
        guard let screen = screens.first(where: { NSMouseInRect(point, $0.frame, false) })
            ?? screens.min(by: { distance(from: point, to: $0.frame) < distance(from: point, to: $1.frame) })
        else { return preferred }
        let area = screen.visible
        return NSSize(
            width: max(minimum.width, min(preferred.width, area.width - padding.width)),
            height: max(minimum.height, min(preferred.height, area.height - padding.height))
        )
    }

    /// `frame` moved (not resized) so it lies inside `area`; a frame taller or
    /// wider than `area` keeps its top or left edge visible.
    static func clamped(_ frame: NSRect, into area: NSRect) -> NSRect {
        var origin = frame.origin
        origin.x = max(min(origin.x, area.maxX - frame.width), area.minX)
        origin.y = min(max(origin.y, area.minY), area.maxY - frame.height)
        return NSRect(origin: origin, size: frame.size)
    }

    /// The live screens, in AppKit coordinates.
    static func constrainedSize(
        _ preferred: NSSize,
        minimum: NSSize = .zero,
        padding: NSSize,
        near point: NSPoint
    ) -> NSSize {
        constrainedSize(preferred, minimum: minimum, padding: padding, near: point, screens: NSScreen.screens.map { (frame: $0.frame, visible: $0.visibleFrame) })
    }

    /// Distance from a point to a rect: zero inside it or on its edge.
    private static func distance(from point: NSPoint, to rect: NSRect) -> CGFloat {
        let dx = max(0, max(rect.minX - point.x, point.x - rect.maxX))
        let dy = max(0, max(rect.minY - point.y, point.y - rect.maxY))
        return sqrt(dx * dx + dy * dy)
    }

    /// The live screens, in AppKit coordinates.
    static func origin(size: NSSize, near point: NSPoint) -> NSPoint {
        origin(size: size, near: point, screens: NSScreen.screens.map { (frame: $0.frame, visible: $0.visibleFrame) })
    }

    /// The live screens, in AppKit coordinates.
    static func origin(size: NSSize, near anchor: PanelAnchor) -> NSPoint {
        origin(size: size, near: anchor, screens: NSScreen.screens.map { (frame: $0.frame, visible: $0.visibleFrame) })
    }
}

/// Owns the keyboard only long enough to catch Esc; a click inside dismisses too.
private final class NoticeView: NSVisualEffectView {
    var onDismiss: (() -> Void)?

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 {
            onDismiss?()
            return
        }
        super.keyDown(with: event)
    }

    override func mouseDown(with event: NSEvent) {
        onDismiss?()
    }
}

/// A one-shot message where the chooser would have been. Non-activating, never
/// steals the app's activation. Closes on Esc, a click, or losing key: the
/// put-back it reports already happened before it shows.
final class NoticePanel: NSObject, NSWindowDelegate {
    private let panel: KeyablePanel
    private let content = NoticeView(frame: .zero)
    private let titleLabel = NSTextField(labelWithString: "")
    private let detailLabel = NSTextField(labelWithString: "")
    private let hintLabel = NSTextField(labelWithString: "")

    override init() {
        panel = KeyablePanel(
            contentRect: NSRect(x: 0, y: 0, width: 200, height: 100),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: true
        )
        super.init()

        panel.level = .popUpMenu
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.delegate = self

        content.material = .menu
        content.state = .active
        content.wantsLayer = true
        content.layer?.cornerRadius = 8
        content.onDismiss = { [weak self] in self?.close() }
        panel.contentView = content

        titleLabel.font = .systemFont(ofSize: 13)
        titleLabel.textColor = .labelColor
        detailLabel.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        detailLabel.textColor = .secondaryLabelColor
        detailLabel.lineBreakMode = .byWordWrapping
        detailLabel.maximumNumberOfLines = 0
        detailLabel.preferredMaxLayoutWidth = 392
        hintLabel.font = .systemFont(ofSize: 11)
        hintLabel.textColor = .tertiaryLabelColor

        let outer = NSStackView(views: [titleLabel, detailLabel, hintLabel])
        outer.orientation = .vertical
        outer.alignment = .leading
        outer.spacing = 4
        outer.edgeInsets = NSEdgeInsets(top: 12, left: 14, bottom: 12, right: 14)
        outer.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(outer)
        NSLayoutConstraint.activate([
            outer.topAnchor.constraint(equalTo: content.topAnchor),
            outer.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            outer.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            outer.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            outer.widthAnchor.constraint(greaterThanOrEqualToConstant: 240),
            outer.widthAnchor.constraint(lessThanOrEqualToConstant: 420),
        ])
    }

    var isVisible: Bool { panel.isVisible }

    func show(title: String, hint: String, detail: String = "", near point: NSPoint) {
        show(title: title, hint: hint, detail: detail, near: PanelAnchor(point))
    }

    func show(title: String, hint: String, detail: String = "", near anchor: PanelAnchor) {
        titleLabel.stringValue = title
        detailLabel.stringValue = detail
        detailLabel.isHidden = detail.isEmpty
        hintLabel.stringValue = hint
        let size = content.fittingSize
        panel.setContentSize(size)
        panel.setFrameOrigin(PanelGeometry.origin(size: size, near: anchor))
        panel.orderFrontRegardless()
        panel.makeKey()
    }

    func close() {
        panel.orderOut(nil)
    }

    func windowDidResignKey(_ notification: Notification) {
        close()
    }
}
