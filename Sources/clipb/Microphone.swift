import CoreAudio
import Foundation

/// An audio input device, and the rule voice copy uses to choose one
/// (SPEC §2.13): the first entry of `[voice] microphones` that is connected.
/// Besides exact device names (case-insensitive), two keywords:
/// "built-in" is the Mac's own mic, "default" the system default input.
struct Microphone: Equatable {
    let id: AudioDeviceID
    let name: String
    let builtIn: Bool
    let hasInput: Bool

    static let builtInKeyword = "built-in"
    static let defaultKeyword = "default"

    /// Pure. `defaultID`: the system default input, if any. Nil when nothing
    /// in `preferences` is connected. Built-in speakers share the built-in
    /// transport, so only devices with input streams count.
    static func choose(preferences: [String], devices: [Microphone], defaultID: AudioDeviceID?) -> Microphone? {
        let inputs = devices.filter(\.hasInput)
        for preference in preferences {
            let wanted = preference.trimmingCharacters(in: .whitespaces)
            let match: Microphone? = switch wanted.lowercased() {
            case builtInKeyword: inputs.first(where: \.builtIn)
            case defaultKeyword: inputs.first { $0.id == defaultID }
            default: inputs.first { $0.name.compare(wanted, options: .caseInsensitive) == .orderedSame }
            }
            if let match { return match }
        }
        return nil
    }

    /// Reads the live device list.
    static func choose(preferences: [String]) -> Microphone? {
        choose(preferences: preferences, devices: all(), defaultID: defaultInputID())
    }

    static func defaultInputID() -> AudioDeviceID? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var id = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &id) == noErr,
              id != kAudioObjectUnknown else { return nil }
        return id
    }

    static func all() -> [Microphone] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size) == noErr else { return [] }
        var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &ids) == noErr else { return [] }
        return ids.map { id in
            Microphone(id: id, name: name(of: id), builtIn: transport(of: id) == kAudioDeviceTransportTypeBuiltIn,
                       hasInput: hasInputStreams(id))
        }
    }

    private static func name(of id: AudioDeviceID) -> String {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioObjectPropertyName,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var name: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, &name) == noErr,
              let name else { return "" }
        return name.takeRetainedValue() as String
    }

    private static func transport(of id: AudioDeviceID) -> UInt32 {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyTransportType,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var transport: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, &transport) == noErr else { return 0 }
        return transport
    }

    private static func hasInputStreams(_ id: AudioDeviceID) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreams,
            mScope: kAudioDevicePropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        return AudioObjectGetPropertyDataSize(id, &address, 0, nil, &size) == noErr && size > 0
    }
}
