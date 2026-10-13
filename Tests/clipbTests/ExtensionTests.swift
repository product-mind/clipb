import Foundation
import Testing
@testable import clipb

@Suite struct ExtensionRoutingTests {
    private let localState = Data("""
    {"profile":{"info_cache":{
      "Default":{"user_name":"me@work.example","name":"Work"},
      "Profile 3":{"user_name":"me@home.example","name":"Home"}
    }}}
    """.utf8)

    private func config(_ toml: String) throws -> RouterConfig { try RouterConfig(toml: toml) }
    private func url(_ s: String) -> URL { URL(string: s)! }

    @Test func staysInTheRightProfile() throws {
        let c = try config("[router]\n\"github.com\" = \"chrome:me@work.example\"")
        let d = ExtensionRouting.decide(url: url("https://github.com/x"), currentEmail: "me@work.example", config: c, localState: localState)
        #expect(!d.move)
        #expect(d.reason == "already in the right profile")
    }

    @Test func movesToAnotherProfile() throws {
        let c = try config("[router]\n\"github.com\" = \"chrome:me@work.example\"")
        let d = ExtensionRouting.decide(url: url("https://github.com/x"), currentEmail: "me@home.example", config: c, localState: localState)
        #expect(d.move)
        #expect(d.target == "chrome:me@work.example")
        #expect(d.rule == #""github.com" = "chrome:me@work.example""#)
    }

    @Test func ruleIsReportedAsWrittenBeforeAliasExpansion() throws {
        let c = try config("[profiles]\nwork = \"chrome:me@work.example\"\n[router]\n\"github.com\" = \"work\"")
        let d = ExtensionRouting.decide(url: url("https://github.com/x"), currentEmail: "me@home.example", config: c, localState: localState)
        #expect(d.move)
        #expect(d.rule == #""github.com" = "work""#)
        #expect(d.target == "chrome:me@work.example")
    }

    @Test func movesToAnotherBrowser() throws {
        let c = try config("[router]\n\"example.com\" = \"safari\"")
        let d = ExtensionRouting.decide(url: url("https://example.com"), currentEmail: "me@home.example", config: c, localState: localState)
        #expect(d.move)
    }

    @Test func catchAllNeverEjectsUnlistedSites() throws {
        let c = try config("[router]\n\"*\" = \"chrome:me@home.example\"")
        let d = ExtensionRouting.decide(url: url("https://unlisted.example"), currentEmail: "me@work.example", config: c, localState: localState)
        #expect(!d.move)
        #expect(d.reason == "no rule matches")
    }

    @Test func staysWhenSomethingIsUnknown() throws {
        let c = try config("[router]\n\"github.com\" = \"chrome:nobody@x.example\"")
        let unknownTarget = ExtensionRouting.decide(url: url("https://github.com"), currentEmail: "me@work.example", config: c, localState: localState)
        #expect(!unknownTarget.move)

        let c2 = try config("[router]\n\"github.com\" = \"chrome:me@work.example\"")
        #expect(!ExtensionRouting.decide(url: url("https://github.com"), currentEmail: nil, config: c2, localState: localState).move)
        #expect(!ExtensionRouting.decide(url: url("https://github.com"), currentEmail: "", config: c2, localState: localState).move)
        #expect(!ExtensionRouting.decide(url: url("https://github.com"), currentEmail: "me@home.example", config: c2, localState: nil).move)
        #expect(!ExtensionRouting.decide(url: url("ftp://github.com"), currentEmail: "me@home.example", config: c2, localState: localState).move)
    }

    @Test func askRuleStaysBecauseTheUserChoosesInClipB() throws {
        let c = try config("[router]\n\"github.com\" = \"ask\"")
        let d = ExtensionRouting.decide(url: url("https://github.com/x"), currentEmail: "me@home.example", config: c, localState: localState)
        #expect(!d.move)
        #expect(d.reason == "rule asks the user in ClipB")
        #expect(d.rule == #""github.com" = "ask""#)
    }

    @Test func catchAllFlagOnlyAffectsTheBareStar() throws {
        let c = try config("[router]\n\"*\" = \"safari\"")
        #expect(c.target(for: url("https://a.example")) != nil)
        #expect(c.target(for: url("https://a.example"), includeCatchAll: false) == nil)
    }
}

@Suite struct NativeHostTests {
    private func request(_ json: String, config: String = "[router]\n\"github.com\" = \"chrome:me@work.example\"") -> NativeHost.Response {
        NativeHost.respond(
            to: Data(json.utf8),
            config: { try RouterConfig(toml: config) },
            localState: { nil },
            open: { _, _ in }
        )
    }

    @Test func decideAnswersWithoutLeakingTheURL() throws {
        let r = request(#"{"op":"decide","url":"https://github.com/secret-path","email":"me@home.example"}"#)
        #expect(r.ok)
        // Local State is missing here, so the host must stay put rather than guess.
        #expect(r.move == false)
        let encoded = String(decoding: try JSONEncoder().encode(r), as: UTF8.self)
        #expect(!encoded.contains("secret-path"))
    }

    @Test func openHandsTheLinkToTheApp() {
        var opened: [URL] = []
        let r = NativeHost.respond(
            to: Data(#"{"op":"open","url":"https://github.com/x"}"#.utf8),
            config: { try RouterConfig(toml: "") },
            localState: { nil },
            open: { url, _ in opened.append(url) }
        )
        #expect(r.ok)
        #expect(opened == [URL(string: "https://github.com/x")!])
    }

    @Test func openPassesTheRedirectDetailsToTheApp() {
        var received: RedirectInfo?
        _ = NativeHost.respond(
            to: Data(#"{"op":"open","url":"https://github.com/x","email":"me@home.example","target":"chrome:work","rule":"\"github.com\" = \"work\""}"#.utf8),
            config: { try RouterConfig(toml: "") },
            localState: { nil },
            open: { _, info in received = info }
        )
        #expect(received == RedirectInfo(from: "me@home.example", target: "chrome:work", rule: #""github.com" = "work""#))
    }

    @Test func arrivedReportsWhoRedirectedTheLink() {
        let info = RedirectInfo(from: "me@home.example", target: "chrome:work", rule: "r")
        let hit = NativeHost.respond(
            to: Data(#"{"op":"arrived","url":"https://github.com/x"}"#.utf8),
            config: { try RouterConfig(toml: "") }, localState: { nil },
            open: { _, _ in }, arrived: { _ in info }
        )
        #expect(hit.ok && hit.from == "me@home.example" && hit.rule == "r")

        let miss = NativeHost.respond(
            to: Data(#"{"op":"arrived","url":"https://github.com/x"}"#.utf8),
            config: { try RouterConfig(toml: "") }, localState: { nil },
            open: { _, _ in }, arrived: { _ in nil }
        )
        #expect(miss.ok && miss.from == nil)
    }

    @Test func rejectsBadRequests() {
        #expect(!request("not json").ok)
        #expect(!request(#"{"op":"open","url":"javascript:alert(1)"}"#).ok)
        #expect(!request(#"{"op":"open","url":"file:///etc/passwd"}"#).ok)
        #expect(!request(#"{"op":"explode","url":"https://a.example"}"#).ok)
    }

    @Test func brokenConfigIsAnErrorNotAMove() {
        let r = request(#"{"op":"decide","url":"https://a.example"}"#, config: "[router]\n\"a\" = ")
        #expect(!r.ok)
    }
}

@Suite struct NativeMessagingTests {
    @Test func framingRoundTripsThroughAPipe() throws {
        var fds: [Int32] = [0, 0]
        #expect(pipe(&fds) == 0)
        defer { close(fds[0]); close(fds[1]) }

        let payload = Data(#"{"op":"decide","url":"https://příliš.example/🐴"}"#.utf8)
        #expect(NativeMessaging.write(payload, to: fds[1]))
        #expect(NativeMessaging.readMessage(from: fds[0]) == payload)
    }

    @Test func eofAndOversizedMessagesAreNil() {
        var fds: [Int32] = [0, 0]
        #expect(pipe(&fds) == 0)
        defer { close(fds[0]) }

        var huge = UInt32(NativeMessaging.maxMessageBytes + 1)
        _ = IPC.writeAll(fds[1], Data(bytes: &huge, count: 4))
        #expect(NativeMessaging.readMessage(from: fds[0]) == nil)

        close(fds[1])
        #expect(NativeMessaging.readMessage(from: fds[0]) == nil)
    }
}

@Suite struct IPCOpenMessageTests {
    @Test func oldMessagesStillDecode() throws {
        let m = try JSONDecoder().decode(IPCMessage.self, from: Data(#"{"tag":null,"text":"x"}"#.utf8))
        #expect(m == IPCMessage(tag: nil, text: "x"))
        #expect(m.open == nil)
    }

    @Test func openRoundTrips() throws {
        let m = IPCMessage(tag: nil, text: "", open: "https://github.com/x")
        #expect(try JSONDecoder().decode(IPCMessage.self, from: JSONEncoder().encode(m)) == m)
    }
}

@Suite struct NativeHostInstallerTests {
    @Test func manifestNamesTheHostAndAllowsOnlyTheGivenExtensions() throws {
        let data = NativeHostInstaller.manifest(executable: "/Apps/ClipB.app/Contents/MacOS/clipb", extensionIDs: ["abc", "def"])
        let json = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(json["name"] as? String == "com.productmind.clipb")
        #expect(json["type"] as? String == "stdio")
        #expect(json["path"] as? String == "/Apps/ClipB.app/Contents/MacOS/clipb")
        #expect(json["allowed_origins"] as? [String] == ["chrome-extension://abc/", "chrome-extension://def/"])
    }
}

@Suite struct RedirectLedgerTests {
    private let info = RedirectInfo(from: "me@home.example", target: "chrome:work", rule: "r")
    private func url(_ s: String) -> URL { URL(string: s)! }

    @Test func claimReturnsTheEntryOnce() {
        var ledger = RedirectLedger()
        ledger.record(url("https://github.com/x"), info)
        #expect(ledger.claim(url("https://github.com/x")) == info)
        #expect(ledger.claim(url("https://github.com/x")) == nil)
    }

    @Test func browsersTweakingTheURLStillMatches() {
        var ledger = RedirectLedger()
        ledger.record(url("https://GitHub.com/org/repo"), info)
        #expect(ledger.claim(url("https://github.com/org/repo/#readme")) == info)
    }

    @Test func differentLinksDoNotMatch() {
        var ledger = RedirectLedger()
        ledger.record(url("https://github.com/org/a"), info)
        #expect(ledger.claim(url("https://github.com/org/b")) == nil)
        #expect(ledger.claim(url("https://github.com/org/a?tab=1")) == nil)
    }

    @Test func entriesExpire() {
        var ledger = RedirectLedger()
        let start = Date()
        ledger.record(url("https://github.com/x"), info, now: start)
        #expect(ledger.claim(url("https://github.com/x"), now: start.addingTimeInterval(RedirectLedger.ttl + 1)) == nil)
    }
}

@Suite struct IPCArrivedTests {
    @Test func serverAnswersArrivedQuestionsWithJSON() throws {
        let dir = NSTemporaryDirectory() + "clipb-\(UUID().uuidString.prefix(8))"
        let path = dir + "/s.sock"
        defer { try? FileManager.default.removeItem(atPath: dir) }

        let server = IPCServer(path: path, queue: DispatchQueue(label: "arrived-test"))
        server.onMessage = { _ in }
        server.onArrived = { link in
            link == "https://github.com/x" ? RedirectInfo(from: "me@home.example", target: nil, rule: "r") : nil
        }
        try server.start()
        defer { server.stop() }

        let hit = try IPCClient.request(IPCMessage(tag: nil, text: "", arrived: "https://github.com/x"), path: path)
        let info = try JSONDecoder().decode(RedirectInfo.self, from: Data(hit.utf8))
        #expect(info.from == "me@home.example")

        let miss = try IPCClient.request(IPCMessage(tag: nil, text: "", arrived: "https://github.com/y"), path: path)
        #expect(miss == "{}\n")
    }
}
