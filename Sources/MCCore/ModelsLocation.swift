import Foundation

/// Locates the directory holding pre-fetched FluidAudio model assets so
/// the app can load them without going to HuggingFace on first launch.
///
/// Layout under the resolved root:
/// ```
/// <root>/Models/parakeet-tdt-0.6b-v2/
/// <root>/Models/silero-vad/
/// <root>/Models/kokoro/
/// ```
///
/// The `.pkg` installer drops these under `/Library/Application Support/MasterControl/`.
/// Dev runs without the installer return `nil`, and the per-model
/// loaders fall through to FluidAudio's own download-on-demand defaults.
public enum ModelsLocation {

    /// Env override used for development — `MASTERCONTROL_MODELS_ROOT=/path/to/build/Models/..`
    /// lets `swift run MasterControl` use a freshly-fetched cache without
    /// touching `/Library`.
    public static let envVar = "MASTERCONTROL_MODELS_ROOT"

    /// System-wide install root populated by the .pkg installer.
    public static let systemRoot = URL(
        fileURLWithPath: "/Library/Application Support/MasterControl",
        isDirectory: true
    )

    /// Returns the directory holding pre-fetched models, or `nil` when
    /// none is present. Callers pass the result through to FluidAudio's
    /// loaders; `nil` means "use library defaults".
    public static func bundledRoot() -> URL? {
        if let override = ProcessInfo.processInfo.environment[envVar],
           !override.isEmpty
        {
            let url = URL(fileURLWithPath: override, isDirectory: true)
            return hasModels(at: url) ? url : nil
        }
        return hasModels(at: systemRoot) ? systemRoot : nil
    }

    /// True if the candidate root looks like a populated install — at
    /// minimum the three model subdirs must exist. We don't validate
    /// every file; FluidAudio surfaces missing-file errors at load time.
    private static func hasModels(at root: URL) -> Bool {
        let fm = FileManager.default
        let modelsDir = root.appendingPathComponent("Models", isDirectory: true)
        let required = ["parakeet-tdt-0.6b-v2", "silero-vad", "kokoro"]
        for name in required {
            let dir = modelsDir.appendingPathComponent(name, isDirectory: true)
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: dir.path, isDirectory: &isDir), isDir.boolValue else {
                return false
            }
        }
        return true
    }
}
