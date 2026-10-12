import Foundation

/// Who sent a link across profiles. Browser and rule names only.
struct RedirectInfo: Codable, Equatable {
    /// Email of the profile the link came from.
    var from: String
    var target: String?
    /// The matching rule as written in the config.
    var rule: String?
}

/// Remembers, for a minute and in memory only, which links the Chrome extension
/// just moved, so the extension in the target profile can tell its tab was a
/// redirect. Main-thread only, like the history.
struct RedirectLedger {
    static let ttl: TimeInterval = 60

    private var entries: [String: (info: RedirectInfo, time: Date)] = [:]

    mutating func record(_ url: URL, _ info: RedirectInfo, now: Date = Date()) {
        prune(now)
        entries[Self.key(url)] = (info, now)
    }

    /// Returns the entry once; a second claim for the same link finds nothing.
    mutating func claim(_ url: URL, now: Date = Date()) -> RedirectInfo? {
        prune(now)
        return entries.removeValue(forKey: Self.key(url))?.info
    }

    private mutating func prune(_ now: Date) {
        entries = entries.filter { now.timeIntervalSince($0.value.time) < Self.ttl }
    }

    /// Ignores fragment, host case and a trailing slash, which browsers tweak.
    static func key(_ url: URL) -> String {
        guard var parts = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return url.absoluteString }
        parts.fragment = nil
        parts.scheme = parts.scheme?.lowercased()
        parts.host = parts.host?.lowercased()
        var key = parts.string ?? url.absoluteString
        if key.hasSuffix("/") { key.removeLast() }
        return key
    }
}
