import AppKit
import Testing
@testable import clipb

/// The dictation panel opens small and grows with its text (MODAL.md).
/// `CLIPB_SNAPSHOTS=<dir>` writes a PNG of the panel after each step.
@MainActor
@Suite struct DictationPanelTests {
    private func snapshot(_ chooser: PipeChooser, _ name: String) {
        guard let dir = ProcessInfo.processInfo.environment["CLIPB_SNAPSHOTS"],
              let view = chooser.window.contentView else { return }
        view.layoutSubtreeIfNeeded()
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?
            .write(to: URL(fileURLWithPath: dir).appendingPathComponent("dictation-\(name).png"))
    }

    private func open() -> PipeChooser {
        _ = NSApplication.shared
        let chooser = PipeChooser()
        chooser.showListening(near: PanelAnchor(NSPoint(x: 500, y: 700)))
        return chooser
    }

    @Test func opensSmall() {
        let chooser = open()
        defer { chooser.close() }
        snapshot(chooser, "1-listening")
        #expect(chooser.textAreaSize.height < 100)
        #expect(chooser.textAreaSize.width < 600)
        #expect(chooser.window.frame.height < 260)
    }

    @Test func growsLineByLineThenToTheFullEditor() {
        let chooser = open()
        defer { chooser.close() }
        let small = chooser.textAreaSize
        chooser.insertDictation("Hello there.", stillListening: true)
        #expect(chooser.textAreaSize == small)

        let sentence = "This is one sentence of a longer dictation that keeps going for a while."
        for _ in 0..<4 { chooser.insertDictation(sentence, stillListening: true) }
        snapshot(chooser, "2-growing")
        let grown = chooser.textAreaSize
        #expect(grown.height > small.height)
        #expect(grown.width == small.width)

        for _ in 0..<40 { chooser.insertDictation(sentence, stillListening: true) }
        snapshot(chooser, "3-full")
        let full = chooser.textAreaSize
        #expect(full.width > grown.width)
        #expect(full.height > grown.height)

        // Never shrinks back.
        chooser.insertDictation("", stillListening: true)
        #expect(chooser.textAreaSize == full)
    }
}
