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
