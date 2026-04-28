@preconcurrency import AVFoundation
import FluidAudio
import Foundation
import MCCore

/// Local neural text-to-speech via FluidAudio's Kokoro model.
///
/// Sounds dramatically more natural than Apple's basic AVSpeechSynthesizer
/// voices. First call downloads the Kokoro model and a default voice
/// embedding (~200 MB). Subsequent calls synthesize on Apple Silicon
/// at >1.0 RTFx, so a 5-second response takes <5 seconds to generate.
///
/// Output is a complete WAV-format `Data` blob. We feed it to
/// AVAudioPlayer to play. The active player is held actor-isolated so
/// a new `speak()` call replaces (and stops) the previous one.
public actor KokoroSpeaker: MCCore.Speaker {

    public nonisolated var name: String { "kokoro" }

    /// `KokoroTtsManager` isn't Sendable. We wrap it in an
    /// @unchecked-Sendable box; the actor's isolation already serializes
    /// access, so the unchecked promise is honored in practice.
    private struct ManagerBox: @unchecked Sendable {
        let inner: KokoroTtsManager
    }

    private var manager: ManagerBox?
    private var player: AVAudioPlayer?
    private var outputDeviceUID: String?

    public init() {}

    public var isLoaded: Bool { manager != nil }

    /// Pins TTS playback to a specific output device by UID. `nil`
    /// routes to the system default. Applies to the next `speak()`,
    /// and updates any in-flight player so a long response can be
    /// rerouted live.
    public func setOutputDeviceUID(_ uid: String?) {
        self.outputDeviceUID = (uid?.isEmpty == false) ? uid : nil
        // AVAudioPlayer.currentDevice is macOS-only and accepts the
        // device's HAL UID directly. Setting nil reverts to default.
        player?.currentDevice = self.outputDeviceUID
    }

    /// Download (if needed) and load the model. Call once at startup.
    /// First call downloads ~200 MB; subsequent calls are 1–3 s on warm
    /// storage.
    public func warmLoad() async throws {
        guard manager == nil else { return }
        let m: KokoroTtsManager
        if let root = ModelsLocation.bundledRoot() {
            // KokoroTtsManager appends "Models/kokoro" to the directory
            // it's given, matching the install layout.
            m = KokoroTtsManager(directory: root)
        } else {
            m = KokoroTtsManager()
        }
        try await m.initialize(preloadVoices: nil)
        self.manager = ManagerBox(inner: m)
    }

    public func speak(_ text: String) async throws {
        guard let manager else {
            throw KokoroSpeakerError.notLoaded
        }
        guard !text.isEmpty else { return }

        let audioData = try await manager.inner.synthesize(text: text)
        let p = try AVAudioPlayer(data: audioData)
        p.currentDevice = outputDeviceUID
        p.prepareToPlay()
        p.play()
        // Hold a strong reference on the actor so the player isn't
        // ARC'd while audio is still playing. Replacing on next call
        // stops the old playback automatically.
        self.player = p
    }

    public func stopSpeaking() {
        player?.stop()
        player = nil
    }
}

public enum KokoroSpeakerError: Error, LocalizedError {
    case notLoaded

    public var errorDescription: String? {
        switch self {
        case .notLoaded: return "KokoroSpeaker.warmLoad() was not called before speak()."
        }
    }
}
