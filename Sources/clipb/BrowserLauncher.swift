import AppKit

struct LaunchPlan {
    var appURL: URL
    var bundleID: String
    /// nil = open in the browser's default profile.
    var profileFolder: String?
    /// The chooser picks the target: the rule says `ask`, or a problem blocks the rule.
    var needsChoice = false
    /// Shown in the chooser when a problem blocks the rule; config and app names only, never the URL.
    var problem: String?
    /// Offers "Continue anyway" in Safari when a rule names a browser that cannot open the link.
    var continueInSafari = false
    /// Why a fallback was used; app ids and profile names only, never the URL.
    var notes: [String] = []
}

/// Opens a clicked link in the browser (and Chromium profile) the config picks.
enum BrowserLauncher {
    private static let fallback = RouteTarget(browser: "safari")
    private static let configCache = RouterConfigCache()
    private static let chooser = RouterChooser()

    static func route(_ url: URL) {
        guard let plan = plan(for: url) else { return }
        if plan.needsChoice {
            devLog("router: ask")
            chooser.show(
                host: url.host ?? "link",
                problem: plan.problem,
                options: ChooserOptions.build(localState: chromeLocalState()),
                continueOption: plan.continueInSafari ? ChooserOptions.safari : nil,
                // No rule is saved while the config or the rule's browser is broken.
                remember: plan.problem == nil ? RememberOptions.build(for: url) : []
            ) { option, remember in
                openChoice(url, option, remember: remember)
            }
            return
        }
        devLog("router: \(plan.bundleID) profile=\(plan.profileFolder ?? "-") \(plan.notes)")
        launch(url, plan)
    }

    /// Saves the chosen "Remember for:" rule (if any), then opens the link in the browser and profile the user picked.
    static func openChoice(_ url: URL, _ option: ChooserOption, remember: RememberOption? = nil) {
        if let pattern = remember?.pattern {
            do {
                try ConfigRuleWriter.remember(pattern: pattern, option: option, localState: chromeLocalState())
                devLog("router: remembered rule")
            } catch {
                NSSound.beep()
                devLog("router: could not save rule: \(describe(error))")
            }
        }
        guard let browser = Browsers.known[option.browser],
              let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: browser.bundleID) else {
            NSSound.beep()
            return
        }
        devLog("router: chose \(option.browser) profile=\(option.profileFolder ?? "-")")
        launch(url, LaunchPlan(appURL: appURL, bundleID: browser.bundleID, profileFolder: option.profileFolder))
    }

    /// Decides where a link goes without opening anything.
    static func plan(for url: URL, config: RouterConfigCache = configCache) -> LaunchPlan? {
        guard url.scheme == "http" || url.scheme == "https" else { return resolve(fallback) }
        do {
            guard let routed = try config.current().target(for: url) else {
                // Never guess a profile: with no rule and no "*", the user chooses.
                return askPlan(notes: ["no rule matched"])
            }
            return resolve(routed)
        } catch {
            // Never fall back to Safari for an unusable config: the user picks.
            return askPlan(problem: "Can't read \(RouterConfig.displayPath): \(describe(error))")
        }
    }

    private static func resolve(_ target: RouteTarget) -> LaunchPlan? {
        if target.browser.lowercased() == "ask" { return askPlan() }
        guard let browser = Browsers.resolve(target.browser) else {
            return askPlan(problem: "Rule says '\(target.browser)', which is not a known browser", continueInSafari: true)
        }
        // Never route back into ourselves: we are the default browser.
        guard browser.bundleID != Bundle.main.bundleIdentifier else {
            return askPlan(problem: "Rule says '\(target.browser)', which is ClipB itself", continueInSafari: true)
        }
        guard let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: browser.bundleID) else {
            return askPlan(problem: "Rule says '\(target.browser)', which is not installed", continueInSafari: true)
        }

        var notes: [String] = []
        var folder: String?
        if let profile = target.profile {
            folder = profileFolder(profile, of: browser)
            if folder == nil { notes.append("no profile matches '\(profile)', using the default one") }
        }
        return LaunchPlan(appURL: appURL, bundleID: browser.bundleID, profileFolder: folder, notes: notes)
    }

    /// A chooser plan. Safari is only a placeholder app here; the chooser picks the real target on click.
    private static func askPlan(problem: String? = nil, notes: [String] = [], continueInSafari: Bool = false) -> LaunchPlan? {
        guard var plan = resolve(fallback) else { return nil }
        plan.needsChoice = true
        plan.problem = problem
        plan.continueInSafari = continueInSafari
        plan.notes = notes
        return plan
    }

    private static func describe(_ error: Error) -> String {
        if let error = error as? TOML.ParseError { return error.description }
        if let error = error as? RouterConfig.ConfigError { return error.description }
        return error.localizedDescription
    }

    private static func launch(_ url: URL, _ plan: LaunchPlan) {
        let config = NSWorkspace.OpenConfiguration()
        guard let folder = plan.profileFolder else {
            NSWorkspace.shared.open([url], withApplicationAt: plan.appURL, configuration: config)
            return
        }
        // Arguments only reach a running browser through a fresh process, like `open -n`;
        // Chromium hands them to the live instance and the new process exits.
        config.createsNewApplicationInstance = true
        config.arguments = ["--profile-directory=\(folder)", url.absoluteString]
        NSWorkspace.shared.openApplication(at: plan.appURL, configuration: config)
    }

    private static func profileFolder(_ spec: String, of browser: BrowserInfo) -> String? {
        guard let data = localState(of: browser) else { return nil }
        return ChromiumProfiles.folder(for: spec, localState: data)
    }

    private static func chromeLocalState() -> Data? {
        Browsers.known["chrome"].flatMap(localState(of:))
    }

    private static func localState(of browser: BrowserInfo) -> Data? {
        guard let dir = browser.supportDir else { return nil }
        let url = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/\(dir)/Local State")
        return try? Data(contentsOf: url)
    }
}
