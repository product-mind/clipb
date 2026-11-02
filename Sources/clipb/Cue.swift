import AudioToolbox
import Foundation

/// Short UI sounds via System Sound Services: the lowest-latency playback path,
/// meant for UI feedback. Built-in sounds only, loaded once. Tink and Pop have
/// under 5 ms of leading silence, so they sound the moment they are played.
enum Cue {
    static let start = SystemSound(name: "Tink")
    static let stop = SystemSound(name: "Pop")

    /// Call at launch so the first press does not pay for loading.
    static func preload() {
        _ = start
        _ = stop
    }
}

final class SystemSound {
    private var id: SystemSoundID = 0

    init(name: String) {
        let url = URL(fileURLWithPath: "/System/Library/Sounds/\(name).aiff")
        if AudioServicesCreateSystemSoundID(url as CFURL, &id) != noErr { id = 0 }
    }

    func play() {
        guard id != 0 else { return }
        AudioServicesPlaySystemSound(id)
    }
}
