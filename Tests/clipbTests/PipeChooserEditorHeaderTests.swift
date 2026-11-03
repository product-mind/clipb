import Foundation
import Testing
@testable import clipb

/// The editor's header line: empty entries get a title instead of a blank bar.
struct PipeChooserEditorHeaderTests {
    @Test("An empty entry heads the editor with Edit")
    func emptyEntry() {
        #expect(PipeChooser.editorHeader(for: ClipEntry(value: "")) == "Edit")
    }

    @Test("A text entry heads the editor with its first line, truncated")
    func textEntry() {
        let long = String(repeating: "a", count: 200)
        let header = PipeChooser.editorHeader(for: ClipEntry(value: long))
        #expect(!header.isEmpty)
        #expect(header.hasSuffix("… (\(long.count) chars)"))
    }
}
@Suite struct DictationHintTests {
    @Test func nothingWithoutAnError() {
        #expect(PipeChooser.pipesErrorHint(nil) == nil)
    }

    @Test func namesTheBrokenConfig() {
        let hint = PipeChooser.pipesErrorHint("[pipe.quote] needs run = \"<command>\"")
        #expect(hint == "No pipes — ~/.config/clipb.toml: [pipe.quote] needs run = \"<command>\"")
    }
}
