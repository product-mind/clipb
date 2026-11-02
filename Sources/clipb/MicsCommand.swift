import Foundation

/// `clipb mics`: lists the input devices by the exact names `[voice]
/// microphones` matches, and marks the one voice copy would record from now.
enum MicsCommand {
    static func run(_ args: [String]) -> Int32 {
        guard args.isEmpty else {
            fputs("usage: clipb mics\n", stderr)
            return 2
        }
        let (config, error) = VoiceConfig.load()
        if let error { fputs("clipb: \(RouterConfig.displayPath): \(error); using the defaults\n", stderr) }
        let inputs = Microphone.all().filter(\.hasInput)
        let defaultID = Microphone.defaultInputID()
        let chosen = Microphone.choose(preferences: config.microphones, devices: inputs, defaultID: defaultID)
        print(render(inputs: inputs, defaultID: defaultID, chosen: chosen, preferences: config.microphones))
        return chosen == nil ? 1 : 0
    }

    /// Pure, tested.
    static func render(inputs: [Microphone], defaultID: UInt32?, chosen: Microphone?, preferences: [String]) -> String {
        var lines = inputs.map { mic in
            var tags: [String] = []
            if mic.builtIn { tags.append(Microphone.builtInKeyword) }
            if mic.id == defaultID { tags.append("system \(Microphone.defaultKeyword)") }
            let tagText = tags.isEmpty ? "" : "  (\(tags.joined(separator: ", ")))"
            return "\(mic == chosen ? "*" : " ") \(mic.name)\(tagText)"
        }
        if inputs.isEmpty { lines.append("  no input devices") }
        let list = preferences.map { "\"\($0)\"" }.joined(separator: ", ")
        lines.append("")
        lines.append(chosen == nil
            ? "No match: voice copy has no microphone. [voice] microphones = [\(list)]"
            : "* = voice copy records from it: first connected of [voice] microphones = [\(list)]")
        return lines.joined(separator: "\n")
    }
}
