import AppKit

/// Where a chooser-style panel opens: above `point`, clamped into the visible
/// area of the screen holding it. Pure, so the clamping is testable.
enum PanelGeometry {
    static func origin(size: NSSize, near point: NSPoint, screens: [(frame: NSRect, visible: NSRect)]) -> NSPoint {
        var origin = NSPoint(x: point.x, y: point.y - size.height)
        guard let screen = screens.first(where: { NSMouseInRect(point, $0.frame, false) }) else { return origin }
        let area = screen.visible
        origin.x = min(max(origin.x, area.minX), area.maxX - size.width)
        origin.y = min(max(origin.y, area.minY), area.maxY - size.height)
        return origin
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
