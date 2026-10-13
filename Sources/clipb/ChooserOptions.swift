import Foundation

/// One button in the router chooser: a browser and, for Chromium, a profile folder.
struct ChooserOption: Equatable {
    var label: String
    /// A key of `Browsers.known`, e.g. "chrome" or "safari".
    var browser: String
    /// nil = the browser's default profile (Safari has none).
    var profileFolder: String?
}

enum ChooserOptions {
    /// Digit keys 1-9 pick an option, so the list never grows past nine.
    static let maxOptions = 9

    static let safari = ChooserOption(label: "Safari", browser: "safari", profileFolder: nil)

    /// Chrome profiles (Default first), then Safari; Safari stays last, so at most eight profiles show.
    static func build(localState: Data?) -> [ChooserOption] {
        let profiles = chromeProfiles(localState: localState).prefix(maxOptions - 1)
        return Array(profiles) + [safari]
    }

    /// The zero-based option index for a digit key, or nil when no option has that digit.
    static func index(forKey key: String, optionCount: Int) -> Int? {
        guard key.count == 1, let digit = Int(key),
              (1...maxOptions).contains(digit), digit <= optionCount else { return nil }
        return digit - 1
    }

    private static func chromeProfiles(localState: Data?) -> [ChooserOption] {
        guard let localState,
              let root = try? JSONSerialization.jsonObject(with: localState) as? [String: Any],
              let profile = root["profile"] as? [String: Any],
              let cache = profile["info_cache"] as? [String: [String: Any]] else { return [] }

        let folders = cache.keys.sorted()
        let ordered = folders.filter { $0 == "Default" } + folders.filter { $0 != "Default" }
        return ordered.map { folder in
            let name = (cache[folder]?["name"] as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return ChooserOption(label: name.isEmpty ? folder : name, browser: "chrome", profileFolder: folder)
        }
    }
}

/// One "Remember for:" choice. A nil `pattern` saves nothing.
struct RememberOption: Equatable {
    var label: String
    var pattern: String?
}

enum RememberOptions {
    static let dontRemember = RememberOption(label: "Don't remember", pattern: nil)

    /// Second-level labels that make a two-label suffix public, e.g. co.uk or com.au.
    private static let suffixLabels: Set<String> = ["co", "com", "org", "net", "gov", "ac", "edu"]

    /// "Don't remember", the host, its parent domain, then the first folder of the path.
    static func build(for url: URL) -> [RememberOption] {
        guard let host = url.host?.lowercased(), !host.isEmpty else { return [dontRemember] }
        let scheme = (url.scheme ?? "https").lowercased()
        let hostPort = hostWithPort(host, port: url.port, scheme: scheme)

        var patterns = [hostPort]
        if let parent = parentPattern(of: host), parent != hostPort { patterns.append(parent) }
        if let folder = folderPattern(url, scheme: scheme, hostPort: hostPort) { patterns.append(folder) }
        return [dontRemember] + patterns.map { RememberOption(label: $0, pattern: $0) }
    }

    private static func hostWithPort(_ host: String, port: Int?, scheme: String) -> String {
        guard let port, port != (scheme == "http" ? 80 : 443) else { return host }
        return "\(host):\(port)"
    }

    /// `*.parent` for a subdomain; nil for IP addresses and public suffixes.
    private static func parentPattern(of host: String) -> String? {
        let labels = host.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
        guard labels.count > 2, !labels.contains(""), let last = labels.last,
              !last.allSatisfy(\.isNumber) else { return nil }
        if last.count == 2, suffixLabels.contains(labels[labels.count - 2]) { return nil }
        return "*." + labels.suffix(2).joined(separator: ".")
    }

    /// Needs a folder and something under it; a one-segment path is not a folder.
    private static func folderPattern(_ url: URL, scheme: String, hostPort: String) -> String? {
        // The raw path matches the same text the router globs on.
        let path = URLComponents(url: url, resolvingAgainstBaseURL: false)?.percentEncodedPath ?? ""
        let segments = path.split(separator: "/")
        guard segments.count >= 2 else { return nil }
        return "\(scheme)://\(hostPort)/\(segments[0])/*"
    }
}
