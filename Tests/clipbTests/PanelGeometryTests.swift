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

    @Test func leavesAPointOnNoScreenAlone() {
        let origin = PanelGeometry.origin(size: size, near: NSPoint(x: 5000, y: 5000), screens: screens)
        #expect(origin == NSPoint(x: 5000, y: 4900))
    }
}
