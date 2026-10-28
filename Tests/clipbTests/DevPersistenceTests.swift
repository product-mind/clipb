#if DEV_PERSIST
import Foundation
import Testing
@testable import clipb

@Suite struct DevPersistenceTests {
    private func tempURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("clipb-test-\(UUID().uuidString)/history.json")
    }

    @Test func roundTripsTagsOrderAndObfuscation() {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        let h = ClipboardHistory()
        h.push("old")
        h.push("secret")
        h.push("spoken", tag: "dictation")
        h.toggleObfuscation(at: 0)
        DevPersistence(url: url).save(h)

        let restored = ClipboardHistory()
        DevPersistence(url: url).restore(into: restored)
        #expect(restored.entries.map(\.value) == ["secret", "old"])
        #expect(restored.entries[0].obfuscated)
        #expect(restored.entries(for: "dictation").map(\.value) == ["spoken"])
    }

    @Test func roundTripsAThousandItems() {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        let h = ClipboardHistory()
        for i in 0..<ClipboardHistory.capacity {
            h.push("value-\(i)", tag: i.isMultiple(of: 2) ? "even" : nil)
        }
        DevPersistence(url: url).save(h)

        let restored = ClipboardHistory()
        DevPersistence(url: url).restore(into: restored)
        #expect(restored.allEntries.count == ClipboardHistory.capacity)
        #expect(restored.allEntries.map(\.value) == h.allEntries.map(\.value))
    }

    @Test func missingOrCorruptFileRestoresNothing() throws {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        let h = ClipboardHistory()
        DevPersistence(url: url).restore(into: h)
        #expect(h.entries.isEmpty)

        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("not json".utf8).write(to: url)
        DevPersistence(url: url).restore(into: h)
        #expect(h.entries.isEmpty)
    }

    @Test func roundTripsAnImageEntry() {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        let h = ClipboardHistory()
        h.push("text")
        h.push(ClipEntry(value: "[image]", source: "Safari", image: Data([1, 2, 3, 4])))
        DevPersistence(url: url).save(h)

        let restored = ClipboardHistory()
        DevPersistence(url: url).restore(into: restored)
        #expect(restored.allEntries.map(\.value) == ["[image]", "text"])
        #expect(restored.allEntries[0].image == Data([1, 2, 3, 4]))
    }

    @Test func roundTripsAFileEntry() {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        let files = [URL(fileURLWithPath: "/tmp/Report.pdf")]
        let h = ClipboardHistory()
        h.push(ClipEntry(value: "[file] Report.pdf", fileURLs: files))
        DevPersistence(url: url).save(h)

        let restored = ClipboardHistory()
        DevPersistence(url: url).restore(into: restored)
        #expect(restored.allEntries[0].value == "[file] Report.pdf")
        #expect(restored.allEntries[0].fileURLs == files)
    }

    @Test func loadsRecordsWrittenBeforeImages() throws {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(#"[{"value":"old","obfuscated":false}]"#.utf8).write(to: url)

        let restored = ClipboardHistory()
        DevPersistence(url: url).restore(into: restored)
        #expect(restored.allEntries.map(\.value) == ["old"])
        #expect(restored.allEntries[0].image == nil)
    }

    @Test func fileIsOwnerOnly() throws {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        DevPersistence(url: url).save(ClipboardHistory())
        let perms = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int
        #expect(perms == 0o600)
    }

    @Test func parsesFlagForms() {
        let home = NSString(string: DevPersistence.defaultPath).expandingTildeInPath
        #expect(DevPersistence.fromCommandLine(["clipb"]).url.path == home)
        #expect(DevPersistence.fromCommandLine(["clipb", "--persist-file", "/tmp/a.json"]).url.path == "/tmp/a.json")
        #expect(DevPersistence.fromCommandLine(["clipb", "--persist-file=/tmp/b.json"]).url.path == "/tmp/b.json")
    }
}
#endif
