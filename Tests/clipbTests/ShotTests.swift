import Foundation
import Testing
@testable import clipb

@Suite struct ShotTests {
    private let utc = TimeZone(identifier: "UTC")!
    /// 2024-01-02 03:04:05 UTC.
    private let date = Date(timeIntervalSince1970: 1_704_164_645)

    private func freshDirectory() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("clipb-shot-\(UUID())")
    }

    @Test func nameIsATimestampedPNG() {
        #expect(Shot.name(at: date, timeZone: utc) == "img-20240102-030405.png")
    }

    @Test func namePadsSingleDigits() {
        #expect(Shot.name(at: Date(timeIntervalSince1970: 0), timeZone: utc) == "img-19700101-000000.png")
    }

    @Test func capturesLandUnderClipbInTheTempDirectory() {
        #expect(Shot.directory(tmp: "/var/folders/xy/T/").path == "/var/folders/xy/T/clipb")
        #expect(Shot.directory(tmp: "/var/folders/xy/T").path == "/var/folders/xy/T/clipb")
    }

    @Test func aFreeNameIsUsedAsIs() {
        let directory = freshDirectory()
        let path = Shot.nextPath(in: directory, now: date, timeZone: utc) { _ in false }
        #expect(path.path == directory.appendingPathComponent("img-20240102-030405.png").path)
    }

    @Test func aTakenNameGetsACounter() {
        let directory = freshDirectory()
        let taken: Set<String> = ["img-20240102-030405.png", "img-20240102-030405-2.png"]
        let path = Shot.nextPath(in: directory, now: date, timeZone: utc) {
            taken.contains($0.lastPathComponent)
        }
        #expect(path.lastPathComponent == "img-20240102-030405-3.png")
    }

    @Test func theDirectoryIsCreatedOwnerOnly() throws {
        let directory = freshDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        #expect(Shot.ensureDirectory(directory))
        var isDirectory: ObjCBool = false
        #expect(FileManager.default.fileExists(atPath: directory.path, isDirectory: &isDirectory))
        #expect(isDirectory.boolValue)
        let attributes = try FileManager.default.attributesOfItem(atPath: directory.path)
        #expect(attributes[.posixPermissions] as? Int == 0o700)
    }

    @Test func anExistingDirectoryKeepsItsPermissions() throws {
        let directory = freshDirectory()
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o755]
        )
        defer { try? FileManager.default.removeItem(at: directory) }
        #expect(Shot.ensureDirectory(directory))
        let attributes = try FileManager.default.attributesOfItem(atPath: directory.path)
        #expect(attributes[.posixPermissions] as? Int == 0o755)
    }
}
