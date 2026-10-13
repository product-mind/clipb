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
