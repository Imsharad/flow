import Foundation
import CoreML

/// Moonshine ASR (CoreML) wrapper.
///
/// Notes:
/// - The PRD requires Moonshine Tiny converted to CoreML with dynamic input shapes.
/// - Until models are added to `Sources/GhostType/Resources`, this runs in mock mode.
final class Transcriber {
    private var model: MLModel?
    private let sampleRate: Int = 16000
    private var isMockMode = false

    init() {
        // Configure Moonshine Tiny CoreML model (compiled).
        let bundle = Bundle.module
        guard let modelURL = Self.resolveModelURL(bundle: bundle) else {
            print("Warning: Moonshine CoreML model not found. Entering Mock Mode.")
            isMockMode = true
            return
        }

        do {
            self.model = try MLModel(contentsOf: modelURL)
        } catch {
            print("Warning: Failed to load Moonshine CoreML model: \(error). Entering Mock Mode.")
            isMockMode = true
        }
    }

    func transcribe(buffer: [Float]) -> String {
        if isMockMode {
            return "Mock transcription: Hello world"
        }

        guard model != nil else { return "" }

        // TODO(PRD): Implement Moonshine CoreML inference.
        // This depends on the exact converted model I/O signature (feature names, shapes, token decoding).
        // Once the `.mlmodelc` is available in Resources, we can wire up MLMultiArray inputs here.
        return "TODO: Moonshine CoreML inference not yet wired"
    }
}

extension Transcriber {
    /// Looks for a compiled CoreML model in app resources.
    /// We prefer `.mlmodelc` for fast startup (precompiled during build).
    private static func resolveModelURL(bundle: Bundle) -> URL? {
        // Preferred: precompiled model.
        if let url = bundle.url(forResource: "MoonshineTiny", withExtension: "mlmodelc") {
            return url
        }

        // Fallback: compile `.mlpackage` on first run (slow; PRD suggests precompile).
        if let packageURL = bundle.url(forResource: "MoonshineTiny", withExtension: "mlpackage") {
            do {
                let compiledURL = try MLModel.compileModel(at: packageURL)
                return compiledURL
            } catch {
                print("Failed to compile MoonshineTiny.mlpackage: \(error)")
                return nil
            }
        }

        return nil
    }
}
