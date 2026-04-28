import FluidAudio
import Foundation

/// Pre-fetches every FluidAudio model the runtime needs into a single
/// directory tree, in the layout the runtime expects:
///
/// ```
/// <out>/Models/parakeet-tdt-0.6b-v2/
/// <out>/Models/silero-vad/
/// <out>/Models/kokoro/
/// ```
///
/// Idempotent: FluidAudio's loaders skip files that already exist on disk,
/// so re-running this against an already-populated tree is fast.

@main
struct FetchModels {
    static func main() async {
        let args = CommandLine.arguments
        guard args.count == 2 else {
            FileHandle.standardError.write(Data("usage: FetchModels <output-dir>\n".utf8))
            exit(2)
        }
        let outDir = URL(fileURLWithPath: args[1], isDirectory: true)
        let modelsDir = outDir.appendingPathComponent("Models", isDirectory: true)

        do {
            try FileManager.default.createDirectory(
                at: modelsDir, withIntermediateDirectories: true
            )

            // Parakeet — `to:` is the leaf model dir; downloadAndLoad puts
            // files there directly.
            let parakeet = modelsDir.appendingPathComponent(
                "parakeet-tdt-0.6b-v2", isDirectory: true
            )
            print("[fetch-models] Parakeet → \(parakeet.path)")
            _ = try await AsrModels.downloadAndLoad(to: parakeet, version: .v2)

            // Silero VAD — `modelDirectory:` is a base; library appends
            // "Models/silero-vad" itself.
            print("[fetch-models] Silero VAD → \(modelsDir.appendingPathComponent("silero-vad").path)")
            _ = try await VadManager(config: .default, modelDirectory: outDir)

            // Kokoro — same convention as VAD.
            print("[fetch-models] Kokoro TTS → \(modelsDir.appendingPathComponent("kokoro").path)")
            let kokoro = KokoroTtsManager(directory: outDir)
            try await kokoro.initialize(preloadVoices: nil)

            print("[fetch-models] done")
        } catch {
            FileHandle.standardError.write(
                Data("[fetch-models] FAILED: \(error.localizedDescription)\n".utf8)
            )
            exit(1)
        }
    }
}
