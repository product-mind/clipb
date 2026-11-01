import AppKit
import Testing
@testable import clipb

@Suite struct PanelGeometryTests {
    private let screens = [(
        frame: NSRect(x: 0, y: 0, width: 1000, height: 800),
        visible: NSRect(x: 0, y: 0, width: 1000, height: 750)
    )]
    private let size = NSSize(width: 200, height: 100)

    @Test func opensAboveThePoint() {
        let origin = PanelGeometry.origin(size: size, near: NSPoint(x: 100, y: 400), screens: screens)
        #expect(origin == NSPoint(x: 100, y: 300))
    }

    @Test func clampsIntoTheVisibleArea() {
        // Near the right edge it is pulled back in, below the bottom it is lifted.
        #expect(PanelGeometry.origin(size: size, near: NSPoint(x: 950, y: 400), screens: screens).x == 800)
        #expect(PanelGeometry.origin(size: size, near: NSPoint(x: 100, y: 20), screens: screens).y == 0)
    }

    @Test func fallsBackToTheNearestScreenOnAnEdge() {
        // A caret on the bottom row anchors at the screen's edge, which
        // NSMouseInRect misses; the nearest screen still gets the panel.
        #expect(PanelGeometry.origin(size: size, near: NSPoint(x: 500, y: 0), screens: screens).y == 0)
    }

    @Test func clampsAFarPointOntoTheNearestScreen() {
        // Nothing anchors off-screen: a point no screen holds clamps to the nearest one.
        let origin = PanelGeometry.origin(size: size, near: NSPoint(x: 5000, y: 5000), screens: screens)
        #expect(origin == NSPoint(x: 800, y: 650))
    }

    private let preferred = NSSize(width: 620, height: 420)

    @Test func aSizeThatFitsIsUntouched() {
        let size = PanelGeometry.constrainedSize(
            preferred, minimum: NSSize(width: 240, height: 160),
            padding: NSSize(width: 20, height: 40), near: NSPoint(x: 100, y: 400), screens: screens
        )
        #expect(size == preferred)
    }

    @Test func aSizeShrinksToFitTheVisibleArea() {
        // 1000×750 visible: 40 px vertical and 20 px horizontal of padding.
        let small = [(frame: NSRect(x: 0, y: 0, width: 400, height: 300),
                      visible: NSRect(x: 0, y: 0, width: 400, height: 300))]
        let size = PanelGeometry.constrainedSize(
            preferred, minimum: NSSize(width: 240, height: 160),
            padding: NSSize(width: 20, height: 40), near: NSPoint(x: 100, y: 100), screens: small
        )
        #expect(size == NSSize(width: 380, height: 260))
    }

    @Test func aSizeNeverGoesBelowTheMinimum() {
        let tiny = [(frame: NSRect(x: 0, y: 0, width: 100, height: 100),
                     visible: NSRect(x: 0, y: 0, width: 100, height: 100))]
        let size = PanelGeometry.constrainedSize(
            preferred, minimum: NSSize(width: 240, height: 160),
            padding: NSSize(width: 20, height: 40), near: NSPoint(x: 10, y: 10), screens: tiny
        )
        #expect(size == NSSize(width: 240, height: 160))
    }

    @Test func aSizeShrinksToTheNearestScreenOnAnEdge() {
        // A point on the bottom edge is in no frame; the nearest screen still fits it.
        let small = [(frame: NSRect(x: 0, y: 0, width: 320, height: 200),
                      visible: NSRect(x: 0, y: 0, width: 320, height: 200))]
        let size = PanelGeometry.constrainedSize(
            preferred, minimum: NSSize(width: 240, height: 160),
            padding: NSSize(width: 20, height: 40), near: NSPoint(x: 100, y: 0), screens: small
        )
        #expect(size == NSSize(width: 300, height: 160))
    }
}
