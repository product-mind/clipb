import Foundation

struct RouteTarget: Equatable {
    var browser: String
    var profile: String?
}

struct BrowserInfo: Equatable {
    var bundleID: String
    /// Under ~/Library/Application Support; nil = no profile support.
    var supportDir: String?
}

enum Browsers {
    static let known: [String: BrowserInfo] = [
        "chrome": BrowserInfo(bundleID: "com.google.Chrome", supportDir: "Google/Chrome"),
        "brave": BrowserInfo(bundleID: "com.brave.Browser", supportDir: "BraveSoftware/Brave-Browser"),
        "edge": BrowserInfo(bundleID: "com.microsoft.edgemac", supportDir: "Microsoft Edge"),
        "safari": BrowserInfo(bundleID: "com.apple.Safari", supportDir: nil),
        "firefox": BrowserInfo(bundleID: "org.mozilla.firefox", supportDir: nil),
    ]

    /// A known short name, or a raw bundle id (anything containing a dot).
    static func resolve(_ name: String) -> BrowserInfo? {
        let key = name.lowercased()
        if let info = known[key] { return info }
        return key.contains(".") ? BrowserInfo(bundleID: name, supportDir: nil) : nil
    }
}

/// Ordered `[router]` rules plus `[profiles]` aliases. First match wins.
struct RouterConfig {
    var rules: [(pattern: String, target: String)] = []
    var aliases: [String: String] = [:]

    struct ConfigError: Error, CustomStringConvertible {
        let description: String
    }

    static let defaultPath = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".config/clipb.toml")

    init(toml: String) throws {
        for table in try TOML.parse(toml) {
            switch table.name {
            case "router", "profiles":
                for (key, value) in table.entries {
                    guard case .string(let target) = value else {
                        throw ConfigError(description: "[\(table.name)] \(key) must be a string")
                    }
                    if table.name == "router" {
                        rules.append((key, target))
                    } else {
                        aliases[key] = target
                    }
                }
            default:
                continue
            }
        }
    }

    static func load(from url: URL = defaultPath) throws -> RouterConfig {
        try RouterConfig(toml: String(contentsOf: url, encoding: .utf8))
    }

    func target(for url: URL) -> RouteTarget? {
        guard let rule = rules.first(where: { Router.matches($0.pattern, url) }) else { return nil }
        return resolve(rule.target)
    }

    /// "browser" or "browser:profile"; an alias from `[profiles]` is expanded first.
    func resolve(_ spec: String) -> RouteTarget {
        let spec = aliases[spec] ?? spec
        guard let colon = spec.firstIndex(of: ":") else { return RouteTarget(browser: spec) }
        let profile = String(spec[spec.index(after: colon)...])
        return RouteTarget(
            browser: String(spec[..<colon]),
            profile: profile.isEmpty ? nil : profile
        )
    }
}

/// Hands out the parsed config, re-reading the file only when its mtime or size changed.
/// Main-thread only.
final class RouterConfigCache {
    private let url: URL
    private var stamp: (date: Date, size: Int)?
    private var cached: Result<RouterConfig, Error>?
    private(set) var loads = 0

    init(url: URL = RouterConfig.defaultPath) {
        self.url = url
    }

    func current() throws -> RouterConfig {
        let attrs: [FileAttributeKey: Any]
        do {
            attrs = try FileManager.default.attributesOfItem(atPath: url.path)
        } catch {
            stamp = nil
            cached = nil
            throw error
        }
        // Stat before reading: an edit in between only costs one extra reload.
        let fresh = (date: attrs[.modificationDate] as? Date ?? .distantPast, size: attrs[.size] as? Int ?? 0)
        if let stamp, stamp == fresh, let cached { return try cached.get() }
        let result = Result { try RouterConfig.load(from: url) }
        loads += 1
        stamp = fresh
        cached = result
        return try result.get()
    }
}

enum Router {
    /// - Pattern containing `://`: glob on the full URL.
    /// - Pattern with `*` or `:`: glob on the host (`host:port` when it has a colon).
    /// - Plain domain: that host and every subdomain of it.
    static func matches(_ pattern: String, _ url: URL) -> Bool {
        let p = pattern.lowercased()
        if p == "*" { return true }
        if p.contains("://") { return glob(p, url.absoluteString.lowercased()) }
        guard let host = url.host?.lowercased() else { return false }
        if p.contains(":") {
            let hostPort = url.port.map { "\(host):\($0)" } ?? host
            return glob(p, hostPort)
        }
        if p.contains("*") { return glob(p, host) }
        return host == p || host.hasSuffix("." + p)
    }

    /// `*` matches any run of characters, including `/`. Everything else is literal.
    static func glob(_ pattern: String, _ text: String) -> Bool {
        let p = Array(pattern.unicodeScalars)
        let t = Array(text.unicodeScalars)
        var pi = 0, ti = 0
        var star = -1, mark = 0
        while ti < t.count {
            if pi < p.count, p[pi] == "*" {
                star = pi
                mark = ti
                pi += 1
            } else if pi < p.count, p[pi] == t[ti] {
                pi += 1
                ti += 1
            } else if star >= 0 {
                pi = star + 1
                mark += 1
                ti = mark
            } else {
                return false
            }
        }
        while pi < p.count, p[pi] == "*" { pi += 1 }
        return pi == p.count
    }
}

enum ChromiumProfiles {
    /// Finds the profile folder in Chromium's `Local State` JSON. Matches the
    /// signed-in email first, then the display name, then the folder name.
    static func folder(for spec: String, localState: Data) -> String? {
        guard let root = try? JSONSerialization.jsonObject(with: localState) as? [String: Any],
              let profile = root["profile"] as? [String: Any],
              let cache = profile["info_cache"] as? [String: [String: Any]] else { return nil }
        let wanted = spec.lowercased()
        let folders = cache.keys.sorted()
        for field in ["user_name", "name"] {
            if let hit = folders.first(where: { (cache[$0]?[field] as? String)?.lowercased() == wanted }) {
                return hit
            }
        }
        return folders.first { $0.lowercased() == wanted }
    }
}
