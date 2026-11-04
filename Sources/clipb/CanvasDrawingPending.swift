import Foundation

// TEMPORARY: stand-ins for the API being written in CanvasDrawing.swift; removed on merge.
extension CanvasDrawing {
    enum Side: Equatable { case top, bottom, left, right }
    struct Segment: Equatable { var arrow: Int; var cells: [Cell]; var horizontal: Bool }
    struct TextRun: Equatable { var cells: Rect; var text: String }
    func connecting(_ from: Int, side fromSide: Side?, to: Int, side toSide: Side?) -> (CanvasDrawing, Int)? { connecting(from, to: to) }
    func segment(at c: Cell) -> Segment? { nil }
    func movingSegment(_ s: Segment, by offset: Int) -> CanvasDrawing? { nil }
    func textRun(at c: Cell) -> TextRun? { nil }
    func movingText(_ run: TextRun, dx: Int, dy: Int) -> CanvasDrawing? { nil }
    func typing(_ text: String, at c: Cell) -> (CanvasDrawing, Cell)? { nil }
    func deletingBackward(at c: Cell) -> (CanvasDrawing, Cell)? { nil }
    func isFree(_ c: Cell) -> Bool { true }
}
