import AudioToolbox
import Foundation

/// Short UI sounds via System Sound Services: the lowest-latency playback path,
/// meant for UI feedback. Built-in sounds only, loaded once. Measured: Tink
/// is audible 4 ms in, peaks at 6.5 ms and is gone by 32 ms, the sharpest
/// and shortest of the 14 system sounds; Pop is audible at 3 ms, peaks at 7 ms.
enum Cue {
    static let start = SystemSound(name: "Tink")
    static let stop = SystemSound(name: "Pop")

    /// Knobs (SPEC §2.13). Experimental: tweak, `make`, try it.
    /// The start cue waits for the hold (`VoiceCopyGesture.holdThreshold`),
    /// so a plain Cmd+C or Cmd+V tap stays silent. False: beep at key-down.
    static let startOnHold = true
    /// Cmd+C where the focused field reports an empty selection beeps at
    /// key-down anyway: nothing to copy, so the press is dictation. Apps that
    /// don't report a selection (Ghostty) wait for the hold.
    static let startAtOnceWhenNothingSelected = true

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
