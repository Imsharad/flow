import Foundation
import CoreML
import Accelerate

class VADService: VADServiceProtocol {
    private let sampleRate: Int = 16000
    private let contextSize = 512 // Model expects 512 samples (~32ms)

    // PRD-aligned timing parameters
    private let minSpeechDurationSeconds: Float = 0.09 // 90ms
    private let minSilenceDurationSeconds: Float = 0.7 // 700ms

    var onSpeechStart: (() -> Void)?
    var onSpeechEnd: (() -> Void)?

    private var isSpeaking = false
    private var speechRunSamples: Int = 0
    private var silenceRunSamples: Int = 0
    private let energyThreshold: Float = 0.01 // Fallback threshold

    // CoreML Model
    private var model: MLModel?
    private let resourceName = "EnergyVAD"
    
    // Buffer for accumulation
    private var buffer: [Float] = []
    private let bufferLock = NSLock()

    init() {
        loadModel()
    }
    
    private func loadModel() {
        // Try to load CoreML model from bundle
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }
            
            // Resolve model URL
            var packageURL: URL?
            
            // Try Bundle.module (SwiftPM)
            if let url = Bundle.module.url(forResource: self.resourceName, withExtension: "mlpackage") {
                packageURL = url
            } else if let url = Bundle.main.url(forResource: self.resourceName, withExtension: "mlpackage") {
                // Fallback to main bundle (App)
                packageURL = url
            }
            
            guard let modelURL = packageURL else {
                print("VADService: EnergyVAD.mlpackage not found in bundle. Using fallback.")
                return
            }
            
            do {
                print("VADService: Compiling model from \(modelURL.lastPathComponent)...")
                let compiledURL = try MLModel.compileModel(at: modelURL)
                
                let config = MLModelConfiguration()
                config.computeUnits = .all // Use Neural Engine if available
                
                let loadedModel = try MLModel(contentsOf: compiledURL, configuration: config)
                
                DispatchQueue.main.async {
                    self.model = loadedModel
                    print("VADService: Loaded EnergyVAD CoreML model successfully")
                }
            } catch {
                print("VADService: Failed to load model: \(error)")
            }
        }
    }

    func process(buffer inputBuffer: [Float]) {
        bufferLock.lock()
        buffer.append(contentsOf: inputBuffer)
        
        // Process in chunks of 512
        while buffer.count >= contextSize {
            let chunk = Array(buffer.prefix(contextSize))
            buffer.removeFirst(contextSize)
            bufferLock.unlock()
            
            processChunk(chunk)
            
            bufferLock.lock()
        }
        bufferLock.unlock()
    }
    
    private func processChunk(_ chunk: [Float]) {
        var isSpeechFrame = false
        
        if let model = model {
            // CoreML Inference
            if let probability = try? predict(chunk, using: model) {
                isSpeechFrame = probability > 0.5
            } else {
                // Fallback if prediction fails
                isSpeechFrame = calculateEnergy(chunk) >= energyThreshold
            }
        } else {
            // Fallback: RMS Energy (legacy)
            isSpeechFrame = calculateEnergy(chunk) >= energyThreshold
        }
        
        // State Machine update
        updateState(isSpeechFrame: isSpeechFrame, chunkCount: chunk.count)
    }
    
    private func calculateEnergy(_ chunk: [Float]) -> Float {
        var rms: Float = 0
        vDSP_rmsqv(chunk, 1, &rms, vDSP_Length(chunk.count))
        return rms
    }
    
    private func updateState(isSpeechFrame: Bool, chunkCount: Int) {
        if isSpeechFrame {
            speechRunSamples += chunkCount
            silenceRunSamples = 0
        } else {
            silenceRunSamples += chunkCount
            speechRunSamples = 0
        }

        let minSpeechSamples = Int(Float(sampleRate) * minSpeechDurationSeconds)
        let minSilenceSamples = Int(Float(sampleRate) * minSilenceDurationSeconds)

        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            
            if !self.isSpeaking {
                if self.speechRunSamples >= minSpeechSamples {
                    self.isSpeaking = true
                    // print("VAD: Speech Start")
                    self.onSpeechStart?()
                }
            } else {
                if self.silenceRunSamples >= minSilenceSamples {
                    self.isSpeaking = false
                    // print("VAD: Speech End")
                    self.onSpeechEnd?()
                }
            }
        }
    }
    
    private func predict(_ chunk: [Float], using model: MLModel) throws -> Float {
        // Create input array (1, 512)
        let multiArray = try MLMultiArray(shape: [1, NSNumber(value: chunk.count)], dataType: .float32)
        for (i, val) in chunk.enumerated() {
            multiArray[[0, NSNumber(value: i)]] = NSNumber(value: val)
        }
        
        let input = EnergyVADInput(audio: multiArray)
        let output = try model.prediction(from: input)
        
        // Output name "probability"
        if let probValue = output.featureValue(for: "probability")?.multiArrayValue {
            // Assuming shape [1]
            return probValue[[0] as [NSNumber]].floatValue
        }
        return 0
    }

    // Helper for manual triggering in debug/mock mode
    func manualTriggerStart() {
        onSpeechStart?()
    }

    func manualTriggerEnd() {
        onSpeechEnd?()
    }
}

// Input Feature Provider
class EnergyVADInput: MLFeatureProvider {
    let audio: MLMultiArray
    
    var featureNames: Set<String> { ["audio"] }
    
    init(audio: MLMultiArray) {
        self.audio = audio
    }
    
    func featureValue(for featureName: String) -> MLFeatureValue? {
        if featureName == "audio" {
            return MLFeatureValue(multiArray: audio)
        }
        return nil
    }
}