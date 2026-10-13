import Foundation

/// Decides whether a tab navigated in one Chrome profile belongs in another.
enum ExtensionRouting {
    struct Decision: Equatable {
        var move: Bool
        var reason: String
        /// Where the rule sends the link; browser and profile names, never the URL.
        var target: String?
        /// The matching rule as written in the config, e.g. `"github.com" = "work"`.
        var rule: String? = nil
    }

    static let chromeBundleID = "com.google.Chrome"

    /// Acts only on explicit rules: a bare `*` catch-all would eject every
    /// unlisted site from the profile it is in.
    static func decide(url: URL, currentEmail: String?, config: RouterConfig, localState: Data?) -> Decision {
        guard url.scheme == "http" || url.scheme == "https" else { return stay("not a web link") }
        guard let rule = config.rule(for: url, includeCatchAll: false) else { return stay("no rule matches") }
        let written = "\"\(rule.pattern)\" = \"\(rule.target)\""
        let target = config.resolve(rule.target)
        // The user picks the browser in ClipB on click; a tab must not move before that.
        guard target.browser.lowercased() != "ask" else { return stay("rule asks the user in ClipB", rule: written) }
        guard let browser = Browsers.resolve(target.browser) else {
            return stay("unknown browser '\(target.browser)'", rule: written)
        }
        let label = target.profile.map { "\(target.browser):\($0)" } ?? target.browser

        guard browser.bundleID == chromeBundleID else {
            return Decision(move: true, reason: "rule targets another browser", target: label, rule: written)
        }
        guard let spec = target.profile else { return stay("rule names no profile", label, rule: written) }
        guard let localState, let wanted = ChromiumProfiles.folder(for: spec, localState: localState) else {
            return stay("target profile not found", label, rule: written)
        }
        guard let email = currentEmail, !email.isEmpty,
              let current = ChromiumProfiles.folder(for: email, localState: localState) else {
            return stay("current profile unknown", label, rule: written)
        }
        return current == wanted
            ? stay("already in the right profile", label, rule: written)
            : Decision(move: true, reason: "rule targets another profile", target: label, rule: written)
    }

    private static func stay(_ reason: String, _ target: String? = nil, rule: String? = nil) -> Decision {
        Decision(move: false, reason: reason, target: target, rule: rule)
    }
}
