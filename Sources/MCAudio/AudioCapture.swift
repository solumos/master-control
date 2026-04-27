@preconcurrency import AVFoundation
import AudioToolbox
import CoreAudio
import Foundation
import MCCore

/// Continuous microphone capture. Streams 16 kHz mono Float32 samples to
/// the configured `sink` for as long as `start()` has been called. The
/// `sink` callback fires on AVFoundation's audio worker thread, so the
/// implementation should be cheap (e.g. enqueue onto an `AsyncStream`
/// continuation).
///
/// Sample chunk size is determined by AVAudioEngine's hardware buffer (~5
/// ms typical), then resampled. Consumers that need a fixed window (e.g.
/// VAD's 4096-sample chunk) must do their own re-buffering downstream.
public final class AudioCapture: @unchecked Sendable {
    public static let targetSampleRate: Double = 16_000

    public typealias Sink = @Sendable ([Float]) -> Void

    private let engine = AVAudioEngine()
    private let lock = NSLock()
    private var sink: Sink?
    private var converter: AVAudioConverter?
    private var converterOutputFormat: AVAudioFormat?
    private var firstChunkLogged = false

    public init() {}

    /// Begin streaming. The `sink` is called repeatedly with successive
    /// 16 kHz mono Float32 sample chunks until `stop()` is called.
    ///
    /// `inputDeviceUID` selects the hardware input. Pass `nil` to use
    /// the system default. UIDs are stable across reboots; resolve via
    /// `AudioDeviceCatalog`.
    public func start(inputDeviceUID: String? = nil, sink: @escaping Sink) throws {
        let input = engine.inputNode

        // Pin the input to a specific HAL device before pulling the
        // input format — `inputFormat(forBus:)` reflects whichever
        // device the input audio unit is currently bound to. Set the
        // device first so the converter picks up the right sample rate.
        if let uid = inputDeviceUID, !uid.isEmpty {
            if let deviceID = AudioDeviceCatalog.deviceID(forUID: uid),
               let audioUnit = input.audioUnit
            {
                var id = deviceID
                let status = AudioUnitSetProperty(
                    audioUnit,
                    kAudioOutputUnitProperty_CurrentDevice,
                    kAudioUnitScope_Global,
                    0,
                    &id,
                    UInt32(MemoryLayout<AudioDeviceID>.size)
                )
                let name = AudioDeviceCatalog.displayName(forUID: uid) ?? uid
                if status == noErr {
                    NSLog("[AudioCapture] input pinned to \"\(name)\" (uid=\(uid))")
                } else {
                    NSLog("[AudioCapture] failed to set input device \"\(name)\": OSStatus=\(status); falling back to system default")
                }
            } else {
                NSLog("[AudioCapture] persisted input UID \(uid) not found among current devices — using system default")
            }
        }

        let inFormat = input.inputFormat(forBus: 0)
        NSLog("[AudioCapture] inputFormat: \(inFormat.sampleRate) Hz, \(inFormat.channelCount) ch")

        guard let outFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: Self.targetSampleRate,
            channels: 1,
            interleaved: false
        ) else {
            throw AudioCaptureError.formatUnavailable
        }

        guard let conv = AVAudioConverter(from: inFormat, to: outFormat) else {
            throw AudioCaptureError.converterUnavailable(from: inFormat, to: outFormat)
        }

        lock.lock()
        self.sink = sink
        self.converter = conv
        self.converterOutputFormat = outFormat
        lock.unlock()

        let tapBufferSize = AVAudioFrameCount(inFormat.sampleRate * 0.05)
        input.removeTap(onBus: 0)
        input.installTap(onBus: 0, bufferSize: tapBufferSize, format: inFormat) { [weak self] buffer, _ in
            self?.handleInput(buffer: buffer)
        }

        engine.prepare()
        try engine.start()
        NSLog("[AudioCapture] engine started; tap installed at \(inFormat.sampleRate) Hz")
    }

    /// Stop streaming. Detaches the tap and stops the engine.
    public func stop() {
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        lock.lock()
        sink = nil
        firstChunkLogged = false
        lock.unlock()
    }

    private func handleInput(buffer: AVAudioPCMBuffer) {
        lock.lock()
        let currentSink = sink
        let currentConverter = converter
        let currentOutFormat = converterOutputFormat
        lock.unlock()
        guard let sink = currentSink,
              let converter = currentConverter,
              let outFormat = currentOutFormat
        else { return }

        let ratio = outFormat.sampleRate / buffer.format.sampleRate
        let outCapacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio + 32)
        guard let outBuf = AVAudioPCMBuffer(
            pcmFormat: outFormat,
            frameCapacity: outCapacity
        ) else { return }

        let consumed = ConsumedFlag()
        var error: NSError?
        let status = converter.convert(to: outBuf, error: &error) { _, inputStatus in
            if consumed.value {
                inputStatus.pointee = .noDataNow
                return nil
            }
            consumed.value = true
            inputStatus.pointee = .haveData
            return buffer
        }

        guard status != .error, error == nil,
              let channelData = outBuf.floatChannelData?[0]
        else { return }

        let frames = Int(outBuf.frameLength)
        guard frames > 0 else { return }

        let chunk = Array(UnsafeBufferPointer(start: channelData, count: frames))
        if !firstChunkLogged {
            firstChunkLogged = true
            NSLog("[AudioCapture] first audio chunk received (\(frames) frames)")
        }
        sink(chunk)
    }
}

/// Box for the converter pull-callback's "have I returned the buffer yet"
/// flag. Wrapping it in a class side-steps Swift 6's concurrent-capture
/// check on the non-sendable converter closure.
private final class ConsumedFlag: @unchecked Sendable {
    var value = false
}

public enum AudioCaptureError: Error, LocalizedError {
    case formatUnavailable
    case converterUnavailable(from: AVAudioFormat, to: AVAudioFormat)
    case engineNotStarted

    public var errorDescription: String? {
        switch self {
        case .formatUnavailable:
            return "Could not create 16 kHz mono Float32 audio format."
        case .converterUnavailable(let from, let to):
            return "No AVAudioConverter from \(from) to \(to)."
        case .engineNotStarted:
            return "AVAudioEngine failed to start."
        }
    }
}
