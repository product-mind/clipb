import Foundation

/// `[voice]` in ~/.config/clipb.toml (SPEC §2.13). Pure parse, tested. Read on
/// every press, so edits apply without a restart.
struct VoiceConfig: Equatable {
    /// The Mac's own mic; with the lid closed, whatever the system uses.
    static let defaultMicrophones = [Microphone.builtInKeyword, Microphone.defaultKeyword]

    /// Preference order: the first connected device wins.
    var microphones = defaultMicrophones
    /// Hold Right Option alone to dictate and paste, like a Cmd+V hold.
    var rightOption = false

    struct ConfigError: Error, CustomStringConvertible {
        let description: String
    }

    init() {}

    init(tables: [TOML.Table]) throws {
        for table in tables where table.name == "voice" {
            for (key, value) in table.entries where key == "right_option" {
                guard case .bool(let on) = value else {
                    throw ConfigError(description: "[voice] right_option must be true or false")
                }
                rightOption = on
            }
            for (key, value) in table.entries where key == "microphones" {
                guard case .strings(let names) = value else {
                    throw ConfigError(description: "[voice] microphones must be a list, e.g. [\"built-in\", \"default\"]")
                }
                let cleaned = names.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
                guard !cleaned.isEmpty else {
                    throw ConfigError(description: "[voice] microphones is empty; remove it to use the defaults")
                }
                microphones = cleaned
            }
        }
    }

    /// A missing file means defaults. A broken one also falls back to the
    /// defaults, with the reason, so dictation keeps working.
    static func load(from url: URL = RouterConfig.defaultPath) -> (config: VoiceConfig, error: String?) {
        guard FileManager.default.fileExists(atPath: url.path) else { return (VoiceConfig(), nil) }
        do {
            return (try VoiceConfig(tables: TOML.parse(String(contentsOf: url, encoding: .utf8))), nil)
        } catch {
            return (VoiceConfig(), "\(error)")
        }
    }
}
