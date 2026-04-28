import MCAudio
import SwiftUI

/// Settings UI shown by the standard `Settings { ... }` SwiftUI scene.
/// Three tabs: Audio (input/output device), Anthropic (API key), About.
struct SettingsView: View {

    @ObservedObject private var settings = AppSettings.shared
    @State private var devices: [AudioDevice] = []

    var body: some View {
        TabView {
            listeningTab
                .tabItem { Label("Listening", systemImage: "ear") }

            audioTab
                .tabItem { Label("Audio", systemImage: "waveform") }

            cloudTab
                .tabItem { Label("Anthropic", systemImage: "cloud") }

            aboutTab
                .tabItem { Label("About", systemImage: "info.circle") }
        }
        .padding(20)
        .frame(width: 520, height: 360)
        .onAppear { devices = AudioDeviceCatalog.devices() }
    }

    // MARK: - Listening mode

    private var listeningTab: some View {
        Form {
            Picker("Mode", selection: $settings.listenMode) {
                ForEach(ListenMode.allCases) { mode in
                    Text(mode.displayName).tag(mode)
                }
            }
            .pickerStyle(.radioGroup)

            Text(modeHelp)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .formStyle(.grouped)
    }

    private var modeHelp: String {
        switch settings.listenMode {
        case .wakeWord:
            return "Mic is always on. Anything starting with \u{201C}master control, …\u{201D} is acted on; everything else is ignored."
        case .optionToggle:
            return "Mic is closed by default. Tap Fn (\u{1F310}) to start listening; tap again to stop. Requires Input Monitoring permission (System Settings → Privacy & Security → Input Monitoring → MasterControl). If Fn doesn't respond, set System Settings → Keyboard → \u{201C}Press \u{1F310} key to\u{201D} to \u{201C}Do Nothing\u{201D} so macOS stops intercepting it."
        }
    }

    // MARK: - Audio

    private var audioTab: some View {
        Form {
            Picker("Input device", selection: $settings.inputDeviceUID) {
                Text("System default").tag(String?.none)
                ForEach(devices.filter { $0.hasInput }) { dev in
                    Text(dev.name).tag(String?.some(dev.uid))
                }
            }

            Picker("Output device", selection: $settings.outputDeviceUID) {
                Text("System default").tag(String?.none)
                ForEach(devices.filter { $0.hasOutput }) { dev in
                    Text(dev.name).tag(String?.some(dev.uid))
                }
            }

            HStack {
                Text("Avoids the AirPods/HFP downgrade — pick a built-in mic for input and your AirPods will keep playing high-quality stereo.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer()
                Button("Refresh") { devices = AudioDeviceCatalog.devices() }
            }
        }
        .formStyle(.grouped)
    }

    // MARK: - Anthropic

    private var cloudTab: some View {
        Form {
            SecureField(
                "API key",
                text: $settings.anthropicAPIKey,
                prompt: Text("sk-ant-…")
            )

            Text(keyStatus)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Link(
                "Get an API key at console.anthropic.com",
                destination: URL(string: "https://console.anthropic.com/settings/keys")!
            )
            .font(.caption)
        }
        .formStyle(.grouped)
    }

    private var keyStatus: String {
        if !settings.anthropicAPIKey.isEmpty {
            return "Stored in your Keychain. Takes precedence over ~/Downloads/.env."
        }
        return "Empty — falls back to $ANTHROPIC_API_KEY, then ~/Downloads/.env."
    }

    // MARK: - About

    private var aboutTab: some View {
        let info = Bundle.main.infoDictionary
        let version = (info?["CFBundleShortVersionString"] as? String) ?? "?"
        let build = (info?["CFBundleVersion"] as? String) ?? "?"

        return VStack(alignment: .leading, spacing: 10) {
            Text("MasterControl").font(.title2).bold()
            Text("Version \(version) (build \(build))")
                .foregroundStyle(.secondary)
            Text("Voice-controlled Mac assistant. Say \u{201C}master control, …\u{201D} and it does the thing.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
