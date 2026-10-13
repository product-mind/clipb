import AppKit

struct LaunchPlan {
    var appURL: URL
    var bundleID: String
    /// nil = open in the browser's default profile.
    var profileFolder: String?
    /// The rule target is `ask`: the user picks in the chooser, so nothing opens yet.
    var needsChoice = false
    /// Why a fallback was used; app ids and profile names only, never the URL.
    var notes: [String] = []
    var configError: String?
}

/// Opens a clicked link in the browser (and Chromium profile) the config picks.
enum BrowserLauncher {
    private static let fallback = RouteTarget(browser: "safari")
    private static let configCache = RouterConfigCache()
    private static let chooser = RouterChooser()

    static func route(_ url: URL) {
        guard let plan = plan(for: url) else { return }
        if plan.configError != nil { NSSound.beep() }
        if plan.needsChoice {
            devLog("router: ask")
            chooser.show(host: url.host ?? "link", options: ChooserOptions.build(localState: chromeLocalState())) { option in
                openChoice(url, option)
            }
            return
        }
        devLog("router: \(plan.bundleID) profile=\(plan.profileFolder ?? "-") \(plan.notes)")
        launch(url, plan)
    }

    /// Opens the link in the browser and profile the user picked in the chooser.
    static func openChoice(_ url: URL, _ option: ChooserOption) {
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
        var target = fallback
        var notes: [String] = []
        var configError: String?
        if url.scheme == "http" || url.scheme == "https" {
            do {
                if let routed = try config.current().target(for: url) {
                    target = routed
                } else {
                    notes.append("no rule matched")
                }
            } catch {
                configError = "\(error)"
                notes.append("config unusable: \(error)")
            }
        }
        return resolve(target, notes: notes, configError: configError)
    }

    private static func resolve(_ target: RouteTarget, notes: [String], configError: String?) -> LaunchPlan? {
        var notes = notes
        if target.browser.lowercased() == "ask" {
            // Safari is only a placeholder app here; the chooser picks the real target on click.
            guard var plan = resolve(fallback, notes: notes, configError: configError) else { return nil }
            plan.needsChoice = true
            return plan
        }
        // Never route back into ourselves: we are the default browser.
        guard let browser = Browsers.resolve(target.browser),
              browser.bundleID != Bundle.main.bundleIdentifier,
              let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: browser.bundleID) else {
            guard target != fallback else { return nil }
            return resolve(fallback, notes: notes + ["browser '\(target.browser)' unavailable"], configError: configError)
        }

        var folder: String?
        if let profile = target.profile {
            folder = profileFolder(profile, of: browser)
            if folder == nil { notes.append("no profile matches '\(profile)', using the default one") }
        }
        return LaunchPlan(
            appURL: appURL, bundleID: browser.bundleID,
            profileFolder: folder, notes: notes, configError: configError
        )
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
