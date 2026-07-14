import AVFoundation
import CoreAudio
import Foundation

public struct RecordingResult: Sendable {
    public let audioURL: URL
    public let duration: TimeInterval
    public let peakLevel: Float
}

/// Captures microphone audio with `AVAudioEngine`, converts it to
/// 16 kHz mono PCM16 on the fly and writes a temporary WAV file suitable
/// for whisper.cpp. The temporary file lives only for the duration of one
/// dictation session; callers must delete it via the returned URL (the
/// `DictationController` does) and `cancel()` deletes it immediately.
public final class AudioRecorder {
    public var levelHandler: ((Float) -> Void)?
    /// Called when the input device disappears mid-recording.
    public var deviceInterruptionHandler: (() -> Void)?

    private let engine = AVAudioEngine()
    // `lock` guards converter/writer/peak: process(buffer:) runs on the
    // audio tap thread while start/stop/cancel run on the main actor, and
    // removeTap does not guarantee in-flight callbacks have finished.
    private let lock = NSLock()
    private var converter: AVAudioConverter?
    private var writer: WAVWriter?
    private var peak: Float = 0
    private var observer: NSObjectProtocol?
    private let targetFormat = AVAudioFormat(
        commonFormat: .pcmFormatInt16, sampleRate: 16000, channels: 1, interleaved: true)!
    private(set) public var isRecording = false

    public init() {}

    public func start(deviceUID: String?) throws {
        guard !isRecording else { throw VoxLocalError.recordingFailed("already recording") }
        lock.lock()
        peak = 0
        lock.unlock()

        if let uid = deviceUID, let deviceID = AudioDeviceFinder.deviceID(forUID: uid) {
            try setInputDevice(deviceID)
        }

        let input = engine.inputNode
        let inputFormat = input.outputFormat(forBus: 0)
        guard inputFormat.sampleRate > 0, inputFormat.channelCount > 0 else {
            throw VoxLocalError.microphoneUnavailable
        }
        guard let converter = AVAudioConverter(from: inputFormat, to: targetFormat) else {
            throw VoxLocalError.recordingFailed("cannot build converter from \(inputFormat)")
        }

        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("voxlocal-\(UUID().uuidString).wav")
        let writer = try WAVWriter(url: tempURL, sampleRate: 16000)
        lock.lock()
        self.converter = converter
        self.writer = writer
        lock.unlock()

        input.installTap(onBus: 0, bufferSize: 4096, format: inputFormat) { [weak self] buffer, _ in
            self?.process(buffer: buffer)
        }

        observer = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main
        ) { [weak self] _ in
            guard let self, self.isRecording else { return }
            Log.shared.info("audio engine configuration changed mid-recording (device change/disconnect)")
            self.deviceInterruptionHandler?()
        }

        engine.prepare()
        do {
            try engine.start()
        } catch {
            cleanupEngine()
            lock.lock()
            self.writer = nil
            self.converter = nil
            lock.unlock()
            writer.cancelAndDelete()
            throw VoxLocalError.recordingFailed(error.localizedDescription)
        }
        isRecording = true
        Log.shared.info("recording started (input: \(Int(inputFormat.sampleRate)) Hz, \(inputFormat.channelCount) ch)")
    }

    private func process(buffer: AVAudioPCMBuffer) {
        // Entire body under the lock: stop()/cancel() nil out writer and
        // converter under the same lock, so no append can race finalize().
        lock.lock()
        defer { lock.unlock() }
        guard let converter, let writer else { return }

        // Level metering on the raw input buffer.
        if let ch = buffer.floatChannelData?[0] {
            let n = Int(buffer.frameLength)
            var sum: Float = 0
            var i = 0
            while i < n {
                let v = ch[i]
                sum += v * v
                i += 16 // sample every 16th frame; enough for a meter
            }
            let rms = sqrtf(sum / Float(max(1, n / 16)))
            let level = min(1.0, rms * 18)
            peak = max(peak, level)
            if let handler = levelHandler {
                DispatchQueue.main.async { handler(level) }
            }
        }

        let ratio = targetFormat.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 64
        guard let out = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: capacity) else { return }
        var supplied = false
        var convError: NSError?
        let status = converter.convert(to: out, error: &convError) { _, outStatus in
            if supplied {
                outStatus.pointee = .noDataNow
                return nil
            }
            supplied = true
            outStatus.pointee = .haveData
            return buffer
        }
        guard status != .error, convError == nil else {
            Log.shared.error("audio conversion failed: \(convError?.localizedDescription ?? "unknown")")
            return
        }
        if out.frameLength > 0, let samples = out.int16ChannelData?[0] {
            try? writer.append(samples, count: Int(out.frameLength))
        }
    }

    /// Stops the engine, finalizes the WAV and returns it. Throws
    /// `.emptyRecording` (and deletes the file) when almost nothing was
    /// captured — e.g. a too-short press or a dead microphone.
    public func stop() throws -> RecordingResult {
        guard isRecording else { throw VoxLocalError.recordingFailed("not recording") }
        cleanupEngine()
        isRecording = false

        // Detach shared state under the lock; any in-flight tap callback
        // either finished before this or sees nil and bails out.
        lock.lock()
        let writer = self.writer
        self.writer = nil
        self.converter = nil
        let capturedPeak = peak
        lock.unlock()
        guard let writer else { throw VoxLocalError.recordingFailed("not recording") }

        let duration = writer.duration
        // Below ~0.35 s or near-silence there is nothing Whisper can use.
        if duration < 0.35 || capturedPeak < 0.005 {
            writer.cancelAndDelete()
            Log.shared.info("recording rejected as empty (duration \(String(format: "%.2f", duration))s, peak \(String(format: "%.3f", capturedPeak)))")
            throw VoxLocalError.emptyRecording
        }
        try writer.finalize()
        Log.shared.info("recording stopped (\(String(format: "%.2f", duration))s)")
        return RecordingResult(audioURL: writer.url, duration: duration, peakLevel: capturedPeak)
    }

    /// Stops immediately and deletes the temporary audio.
    public func cancel() {
        lock.lock()
        let writer = self.writer
        self.writer = nil
        self.converter = nil
        lock.unlock()
        guard isRecording || writer != nil else { return }
        cleanupEngine()
        isRecording = false
        writer?.cancelAndDelete()
        Log.shared.info("recording cancelled; temp audio deleted")
    }

    private func cleanupEngine() {
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        if let observer {
            NotificationCenter.default.removeObserver(observer)
            self.observer = nil
        }
    }

    private func setInputDevice(_ deviceID: AudioDeviceID) throws {
        guard let unit = engine.inputNode.audioUnit else {
            throw VoxLocalError.microphoneUnavailable
        }
        var device = deviceID
        let status = AudioUnitSetProperty(
            unit,
            kAudioOutputUnitProperty_CurrentDevice,
            kAudioUnitScope_Global,
            0,
            &device,
            UInt32(MemoryLayout<AudioDeviceID>.size))
        if status != noErr {
            Log.shared.error("failed to select input device (OSStatus \(status)); falling back to default")
        }
    }
}

/// CoreAudio lookups for input-device selection in Settings.
public enum AudioDeviceFinder {
    public struct Device: Identifiable, Hashable, Sendable {
        public let uid: String
        public let name: String
        public var id: String { uid }
    }

    public static func inputDevices() -> [Device] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size) == noErr else {
            return []
        }
        let count = Int(size) / MemoryLayout<AudioDeviceID>.size
        var ids = [AudioDeviceID](repeating: 0, count: count)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &ids) == noErr else {
            return []
        }
        return ids.compactMap { id in
            guard inputChannelCount(id) > 0, let uid = stringProperty(id, kAudioDevicePropertyDeviceUID),
                  let name = stringProperty(id, kAudioObjectPropertyName) else { return nil }
            return Device(uid: uid, name: name)
        }
    }

    public static func deviceID(forUID uid: String) -> AudioDeviceID? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size) == noErr else {
            return nil
        }
        let count = Int(size) / MemoryLayout<AudioDeviceID>.size
        var ids = [AudioDeviceID](repeating: 0, count: count)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &ids) == noErr else {
            return nil
        }
        return ids.first { stringProperty($0, kAudioDevicePropertyDeviceUID) == uid }
    }

    private static func inputChannelCount(_ id: AudioDeviceID) -> Int {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: kAudioDevicePropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(id, &address, 0, nil, &size) == noErr, size > 0 else { return 0 }
        let bufferList = UnsafeMutablePointer<AudioBufferList>.allocate(capacity: Int(size))
        defer { bufferList.deallocate() }
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, bufferList) == noErr else { return 0 }
        let buffers = UnsafeMutableAudioBufferListPointer(bufferList)
        return buffers.reduce(0) { $0 + Int($1.mNumberChannels) }
    }

    private static func stringProperty(_ id: AudioDeviceID, _ selector: AudioObjectPropertySelector) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var cfString: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        let status = withUnsafeMutablePointer(to: &cfString) { ptr in
            AudioObjectGetPropertyData(id, &address, 0, nil, &size, ptr)
        }
        guard status == noErr, let value = cfString?.takeRetainedValue() else { return nil }
        return value as String
    }
}
