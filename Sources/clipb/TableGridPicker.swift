import AppKit

/// The ⊞ menu's grid, as in Google Docs: hover to size a table, click to
/// insert it. Lives in an NSMenu item, so opening it never takes key from the
/// editor panel (losing key would save and close it).
final class TableGridPicker: NSView {
    static let maxColumns = 8
    static let maxRows = 8
    private static let cell: CGFloat = 16
    private static let gap: CGFloat = 3
    private static let inset: CGFloat = 10
    private static let labelHeight: CGFloat = 20

    /// (rows including the header, columns)
    private let onPick: (Int, Int) -> Void
    private var hover = (rows: 0, columns: 0)

    init(onPick: @escaping (Int, Int) -> Void) {
        self.onPick = onPick
        let side = { (n: Int) in CGFloat(n) * Self.cell + CGFloat(n - 1) * Self.gap + 2 * Self.inset }
        super.init(frame: NSRect(x: 0, y: 0, width: side(Self.maxColumns), height: side(Self.maxRows) + Self.labelHeight))
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override var isFlipped: Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas { removeTrackingArea(area) }
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
    }

    private func size(at point: NSPoint) -> (rows: Int, columns: Int) {
        let step = Self.cell + Self.gap
        let column = Int((point.x - Self.inset) / step) + 1
        let row = Int((point.y - Self.inset) / step) + 1
        guard point.x >= Self.inset, point.y >= Self.inset else { return (0, 0) }
        return (min(max(row, 0), Self.maxRows), min(max(column, 0), Self.maxColumns))
    }

    override func mouseMoved(with event: NSEvent) {
        let next = size(at: convert(event.locationInWindow, from: nil))
        guard next != hover else { return }
        hover = next
        needsDisplay = true
    }

    override func mouseExited(with event: NSEvent) {
        hover = (0, 0)
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        let picked = size(at: convert(event.locationInWindow, from: nil))
        enclosingMenuItem?.menu?.cancelTracking()
        guard picked.rows > 0, picked.columns > 0 else { return }
        // After the menu is gone, so the insert lands in the editor as usual.
        DispatchQueue.main.async { [onPick] in onPick(picked.rows, picked.columns) }
    }

    override func draw(_ dirtyRect: NSRect) {
        let step = Self.cell + Self.gap
        for row in 0..<Self.maxRows {
            for column in 0..<Self.maxColumns {
                let rect = NSRect(x: Self.inset + CGFloat(column) * step, y: Self.inset + CGFloat(row) * step,
                                  width: Self.cell, height: Self.cell)
                let on = row < hover.rows && column < hover.columns
                (on ? NSColor.controlAccentColor.withAlphaComponent(0.35) : NSColor.quaternaryLabelColor).setFill()
                NSBezierPath(roundedRect: rect, xRadius: 3, yRadius: 3).fill()
                if on {
                    NSColor.controlAccentColor.setStroke()
                    NSBezierPath(roundedRect: rect.insetBy(dx: 0.5, dy: 0.5), xRadius: 3, yRadius: 3).stroke()
                }
            }
        }
        // Columns × rows, as Google Docs labels it; the first row is the header.
        let label = hover.rows > 0 ? "\(hover.columns) × \(hover.rows)" : "Insert table"
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 12, weight: .medium),
            .foregroundColor: NSColor.secondaryLabelColor,
        ]
        let text = NSAttributedString(string: label, attributes: attributes)
        let y = bounds.height - Self.labelHeight - Self.inset / 2 + (Self.labelHeight - text.size().height) / 2
        text.draw(at: NSPoint(x: (bounds.width - text.size().width) / 2, y: y))
    }
}
