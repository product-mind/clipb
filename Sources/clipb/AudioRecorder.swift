import AVFoundation
import AudioToolbox

/// Records the built-in microphone (`Microphone.builtIn()`, never the system
/// default) into memory as 16 kHz mono Float32, the
/// format Whisper takes. Never writes audio to disk (SPEC §2.13).
///
/// The tap runs on a Core Audio thread; `samples` is the only state it shares
/// with the main thread, behind `lock`. This is not ClipboardHistory, so the
/// main-thread-only rule does not apply here.
final class AudioRecorder {
    static let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16000, channels: 1, interleaved: false)!

    private let engine = AVAudioEngine()
    private let lock = NSLock()
    private var samples: [Float] = []
    private var running = false

    enum Permission { case granted, pending, denied }

    /// Asks once; the answer lands on a later press.
    static func permission() -> Permission {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: return .granted
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .audio) { _ in }
            return .pending
        default: return .denied
        }
    }

    enum StartResult { case recording, noBuiltInMic, failed }

    /// Opens the built-in mic.
    func start() -> StartResult {
        if running { _ = stop() }
        guard let mic = Microphone.builtIn() else { return .noBuiltInMic }
        let input = engine.inputNode
        guard select(mic, on: input) else { return .failed }
        let inFormat = input.outputFormat(forBus: 0)
        guard inFormat.sampleRate > 0, inFormat.channelCount > 0,
              let converter = AVAudioConverter(from: inFormat, to: Self.format) else { return .failed }
        lock.withLock { samples.removeAll(keepingCapacity: true) }
        input.installTap(onBus: 0, bufferSize: 1024, format: inFormat) { [weak self] buffer, _ in
            self?.append(buffer, converter: converter)
        }
        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            return .failed
        }
        running = true
        return .recording
    }

    /// Points the input node's audio unit at `mic`, skipping the call when it
    /// already is: switching devices costs start-up time.
    private func select(_ mic: Microphone, on input: AVAudioInputNode) -> Bool {
        guard let unit = input.audioUnit else { return false }
        var current = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        if AudioUnitGetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, &current, &size) == noErr,
           current == mic.id { return true }
        var id = mic.id
        let status = AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0,
                                          &id, UInt32(MemoryLayout<AudioDeviceID>.size))
        devLog("voice: input \(mic.name) (\(status == noErr ? "selected" : "select failed \(status)"))")
        return status == noErr
    }

    /// Closes the mic and hands over everything recorded since `start`.
    func stop() -> [Float] {
        if running {
            engine.stop()
            engine.inputNode.removeTap(onBus: 0)
            running = false
        }
        return lock.withLock {
            let taken = samples
            samples = []
            return taken
        }
    }

    private func append(_ buffer: AVAudioPCMBuffer, converter: AVAudioConverter) {
        let ratio = Self.format.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 32
        guard let out = AVAudioPCMBuffer(pcmFormat: Self.format, frameCapacity: capacity) else { return }
        var fed = false
        let status = converter.convert(to: out, error: nil) { _, inputStatus in
            if fed {
                inputStatus.pointee = .noDataNow
                return nil
            }
            fed = true
            inputStatus.pointee = .haveData
            return buffer
        }
        guard status != .error, let channel = out.floatChannelData?[0] else { return }
        let chunk = UnsafeBufferPointer(start: channel, count: Int(out.frameLength))
        lock.withLock { samples.append(contentsOf: chunk) }
    }
}
