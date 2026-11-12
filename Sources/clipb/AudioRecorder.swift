import AVFoundation
import AudioToolbox

/// Records the preferred microphone (`[voice] microphones`, see `Microphone`)
/// into memory as 16 kHz mono Float32, the format Whisper takes. Never writes
/// audio to disk (SPEC §2.13).
///
/// An input-only AudioQueue bound to the device by UID. Not AVAudioEngine:
/// its input node drives an aggregate of the default input and the default
/// output, so every start and stop glitched whatever was playing (AirPods
/// paused and clicked on each Cmd+C). The queue also converts to 16 kHz mono
/// itself. A fresh queue per press keeps start/stop free of buffer bookkeeping.
///
/// Callbacks run on the queue's own thread; `samples` and `queue` liveness are
/// the only shared state, behind `lock`. This is not ClipboardHistory, so the
/// main-thread-only rule does not apply here.
final class AudioRecorder {
    static let sampleRate = 16000.0
    private static let bufferFrames: UInt32 = 320  // 20 ms: the most a stop can cut off
    private static let bufferCount = 4

    private let lock = NSLock()
    private var samples: [Float] = []
    private var queue: AudioQueueRef?
    private var capturing = false

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

    enum StartResult { case recording, noMicrophone, failed }

    /// Opens the first connected mic from `preferences`.
    func start(preferences: [String]) -> StartResult {
        if queue != nil { _ = stop() }
        guard let mic = Microphone.choose(preferences: preferences), !mic.uid.isEmpty else { return .noMicrophone }

        var format = AudioStreamBasicDescription(
            mSampleRate: Self.sampleRate,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
            mBytesPerPacket: 4, mFramesPerPacket: 1, mBytesPerFrame: 4,
            mChannelsPerFrame: 1, mBitsPerChannel: 32, mReserved: 0
        )
        var newQueue: AudioQueueRef?
        let me = Unmanaged.passUnretained(self).toOpaque()
        guard AudioQueueNewInput(&format, { userData, queue, buffer, _, _, _ in
            guard let userData else { return }
            Unmanaged<AudioRecorder>.fromOpaque(userData).takeUnretainedValue().received(buffer, on: queue)
        }, me, nil, nil, 0, &newQueue) == noErr, let newQueue else { return .failed }

        var uid = mic.uid as CFString
        let selected = AudioQueueSetProperty(newQueue, kAudioQueueProperty_CurrentDevice, &uid,
                                             UInt32(MemoryLayout<CFString>.size))
        guard selected == noErr else {
            devLog("voice: input \(mic.name) select failed \(selected)")
            AudioQueueDispose(newQueue, true)
            return .failed
        }
        for _ in 0..<Self.bufferCount {
            var buffer: AudioQueueBufferRef?
            if AudioQueueAllocateBuffer(newQueue, Self.bufferFrames * 4, &buffer) == noErr, let buffer {
                AudioQueueEnqueueBuffer(newQueue, buffer, 0, nil)
            }
        }
        lock.withLock {
            samples.removeAll(keepingCapacity: true)
            capturing = true
        }
        let started = AudioQueueStart(newQueue, nil)
        guard started == noErr else {
            devLog("voice: input \(mic.name) start failed \(started)")
            lock.withLock { capturing = false }
            AudioQueueDispose(newQueue, true)
            return .failed
        }
        queue = newQueue
        devLog("voice: input \(mic.name)")
        return .recording
    }

    /// Samples recorded so far in this take; the mic stays open.
    var sampleCount: Int { lock.withLock { samples.count } }

    /// A copy of `range` of this take's audio, clamped to what was recorded.
    func samples(in range: Range<Int>) -> [Float] {
        lock.withLock {
            let clamped = range.clamped(to: 0..<samples.count)
            return Array(samples[clamped])
        }
    }

    /// Closes the mic and hands over everything recorded since `start`.
    func stop() -> [Float] {
        // Stop first: buffers already delivered land in `samples` before we take them.
        if let queue {
            AudioQueueStop(queue, true)
            AudioQueueDispose(queue, true)
            self.queue = nil
        }
        return lock.withLock {
            capturing = false
            let taken = samples
            samples = []
            return taken
        }
    }

    private func received(_ buffer: AudioQueueBufferRef, on queue: AudioQueueRef) {
        let count = Int(buffer.pointee.mAudioDataByteSize) / MemoryLayout<Float>.size
        let frames = buffer.pointee.mAudioData.assumingMemoryBound(to: Float.self)
        let keepGoing: Bool = lock.withLock {
            guard capturing else { return false }
            samples.append(contentsOf: UnsafeBufferPointer(start: frames, count: count))
            return true
        }
        if keepGoing { AudioQueueEnqueueBuffer(queue, buffer, 0, nil) }
    }
}
