import Combine
import Foundation

/// User-facing settings for the menu-bar app. Persisted between launches.
///
/// Audio device choices live in UserDefaults (small, non-sensitive). The
/// Anthropic API key lives in Keychain. All three are observable so the
/// coordinator can react to changes and rewire the audio pipeline / LLM
/// agent without an app restart.
@MainActor
final class AppSettings: ObservableObject {

    static let shared = AppSettings()

    // UserDefaults keys
    private static let inputUIDKey = "audio.inputDeviceUID"
    private static let outputUIDKey = "audio.outputDeviceUID"
    private static let modeKey = "listen.mode"

    // Keychain account
    private static let anthropicKeyAccount = "anthropic-api-key"

    /// Stable HAL UID of the chosen mic, or nil for system default.
    @Published var inputDeviceUID: String? {
        didSet { persistOptional(inputDeviceUID, key: Self.inputUIDKey) }
    }

    /// Stable HAL UID of the chosen TTS output device, or nil for default.
    @Published var outputDeviceUID: String? {
        didSet { persistOptional(outputDeviceUID, key: Self.outputUIDKey) }
    }

    /// Anthropic API key entered via UI. Empty string falls back to
    /// `ANTHROPIC_API_KEY` in the environment, then `~/Downloads/.env`.
    @Published var anthropicAPIKey: String {
        didSet {
            KeychainStore.setString(
                anthropicAPIKey.isEmpty ? nil : anthropicAPIKey,
                account: Self.anthropicKeyAccount
            )
        }
    }

    /// How the app decides which utterances to act on.
    @Published var listenMode: ListenMode {
        didSet {
            UserDefaults.standard.set(listenMode.rawValue, forKey: Self.modeKey)
        }
    }

    private init() {
        let d = UserDefaults.standard
        self.inputDeviceUID = d.string(forKey: Self.inputUIDKey)
        self.outputDeviceUID = d.string(forKey: Self.outputUIDKey)
        self.anthropicAPIKey = KeychainStore.getString(account: Self.anthropicKeyAccount) ?? ""
        if let raw = d.string(forKey: Self.modeKey),
           let mode = ListenMode(rawValue: raw) {
            self.listenMode = mode
        } else {
            self.listenMode = .wakeWord
        }
    }

    private func persistOptional(_ value: String?, key: String) {
        let d = UserDefaults.standard
        if let value, !value.isEmpty {
            d.set(value, forKey: key)
        } else {
            d.removeObject(forKey: key)
        }
    }
}
