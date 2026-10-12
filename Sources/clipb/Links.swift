import Foundation

enum Links {
    /// The value as a web URL, if it is exactly one http(s) URL and nothing else.
    static func webURL(in value: String) -> URL? {
        let text = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty,
              text.rangeOfCharacter(from: .whitespacesAndNewlines) == nil,
              let url = URL(string: text),
              let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https",
              url.host?.isEmpty == false else { return nil }
        return url
    }
}
