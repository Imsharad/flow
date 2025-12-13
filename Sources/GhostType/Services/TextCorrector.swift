import Foundation
import CoreML

/// T5-Small correction (CoreML) wrapper.
///
/// For now this falls back to a lightweight local formatter until a converted
/// CoreML T5 model is added to Resources and wired up.
final class TextCorrector {
    private var model: MLModel?
    private let formatter = TextFormatter()
    private var isMockMode = false

    init() {
        let bundle = Bundle.module
        guard let modelURL = Self.resolveModelURL(bundle: bundle) else {
            // Not fatal; we can still do basic formatting.
            isMockMode = true
            return
        }

        do {
            self.model = try MLModel(contentsOf: modelURL)
        } catch {
            print("Warning: Failed to load T5 CoreML model: \(error). Falling back to formatter.")
            isMockMode = true
        }
    }

    func correct(text: String, context: String?) -> String {
        // TODO(PRD): Wire T5 CoreML inference.
        // This depends on the exact converted model I/O (tokenization + decoding).
        // Until then, do basic capitalization via TextFormatter.
        return formatter.format(text: text, context: context)
    }
}

extension TextCorrector {
    private static func resolveModelURL(bundle: Bundle) -> URL? {
        if let url = bundle.url(forResource: "T5Small", withExtension: "mlmodelc") {
            return url
        }

        if let packageURL = bundle.url(forResource: "T5Small", withExtension: "mlpackage") {
            do {
                let compiledURL = try MLModel.compileModel(at: packageURL)
                return compiledURL
            } catch {
                print("Failed to compile T5Small.mlpackage: \(error)")
                return nil
            }
        }

        return nil
    }
}
