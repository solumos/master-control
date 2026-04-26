@preconcurrency import AVFoundation
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

    public init() {}

    /// Begin streaming. The `sink` is called repeatedly with successive
    /// 16 kHz mono Float32 sample chunks until `stop()` is called.
    public func start(sink: @escaping Sink) throws {
        let input = engine.inputNode
        let inFormat = input.inputFormat(forBus: 0)

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
    }

    /// Stop streaming. Detaches the tap and stops the engine.
    public func stop() {
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        lock.lock()
        sink = nil
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
