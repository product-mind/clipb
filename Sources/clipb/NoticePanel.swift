import AppKit

/// Where a chooser-style panel opens: above `point`, clamped into the visible
/// area of the screen holding it. Pure, so the clamping is testable.
enum PanelGeometry {
    enum AnchorSource: Equatable { case text, pointer, field }

    /// Where a panel tied to the user's typing opens: just under the selection
    /// or caret; else the mouse pointer while it rests inside the focused
    /// field (apps like Ghostty report only the whole field, whose bottom edge
    /// can be a screen away from the prompt); else under the field; else the
    /// pointer. Pure; the caller clamps the point onto the anchor's screen.
    static func anchor(text: NSRect?, field: NSRect?, pointer: NSPoint) -> (point: NSPoint, source: AnchorSource) {
        if let text { return (NSPoint(x: text.midX, y: text.minY - 8), .text) }
        if let field, !NSMouseInRect(pointer, field, false) {
            return (NSPoint(x: field.midX, y: field.minY - 8), .field)
        }
        return (pointer, .pointer)
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
        titleLabel.stringValue = title
        detailLabel.stringValue = detail
        detailLabel.isHidden = detail.isEmpty
        hintLabel.stringValue = hint
        let size = content.fittingSize
        panel.setContentSize(size)
        panel.setFrameOrigin(PanelGeometry.origin(size: size, near: point))
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
