import Foundation

/// `clipb route <url>`: dry run. Prints where the config would send a link
/// and opens nothing, so rules and profile lookups can be checked safely.
enum RouteCommand {
    static func run(_ args: [String]) -> Int32 {
        guard args.count == 1, let url = URL(string: args[0]) else {
            fputs("usage: clipb route <url>\n", stderr)
            return 2
        }
        guard let plan = BrowserLauncher.plan(for: url) else {
            fputs("no browser available\n", stderr)
            return 1
        }
        if plan.needsChoice {
            print("browser: ask")
            if let problem = plan.problem { print("note:    \(problem)") }
            print("note:    the chooser opens in ClipB when the link is clicked")
            return plan.problem == nil ? 0 : 1
        }
        print("browser: \(plan.bundleID)")
        print("profile: \(plan.profileFolder ?? "(default)")")
        for note in plan.notes { print("note:    \(note)") }
        return 0
    }
}
