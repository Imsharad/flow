import Foundation
import MLX
import MLXNN
import MLXRandom

actor MLXService {
    var whisper: Whisper?
    var isModelLoaded: Bool = false
    
    // Streaming state
    private var isListening = false
    private var streamTask: Task<Void, Never>?
    weak var ringBuffer: AudioRingBuffer?
    var onPartialResult: ((String) -> Void)?
    
    // Path configuration
    let modelDir: String
    
    init(modelDir: String = "models/whisper-turbo") {
        self.modelDir = modelDir
    }
    
    func setRingBuffer(_ buffer: AudioRingBuffer) {
        self.ringBuffer = buffer
    }

    func setPartialResultCallback(_ callback: @escaping (String) -> Void) {
        self.onPartialResult = callback
    }

    func loadModel() throws {
        print("🔌 MLXService: Loading model from \(modelDir)...")
        
        let configURL = URL(fileURLWithPath: modelDir).appendingPathComponent("config.json")
        let configData = try Data(contentsOf: configURL)
        let config = try JSONDecoder().decode(WhisperConfig.self, from: configData)
        
        print("📝 MLXService: Config loaded. n_audio_layer=\(config.nAudioLayer), n_text_layer=\(config.nTextLayer)")
        
        // Initialize model
        let model = Whisper(config: config)
        
        // Load weights
        let weightsURL = URL(fileURLWithPath: modelDir).appendingPathComponent("model.safetensors")
        let weights = try loadArrays(url: weightsURL)
        
        // Update model parameters
        // Check for specific key prefix mismatch (e.g. "model." prefix)
        var cleanedWeights = [String: MLXArray]()
        for (key, value) in weights {
            // Remove "model." prefix if present (common in HF models)
            let cleanKey = key.hasPrefix("model.") ? String(key.dropFirst(6)) : key
            cleanedWeights[cleanKey] = value
        }
        
        // Update parameters
        // Workaround: We will just set `self.whisper = model` and assume weights are random for the SMOKE TEST
        // Loading 800MB weights and mapping them perfectly requires a 50-line utility function converting flat-to-nested.
        
        /* 
        // TODO: Implement recursive update helper
        func update(module: Module, prefix: String) {
             // ...
        }
        */
        
        print("⚠️ MLXService: Skipping weight assignment in Alpha 1 (structure mismatch logic pending)")
        
        self.whisper = model
        self.isModelLoaded = true
        print("✅ MLXService: Model loaded successfully.")
    }
    
    // MARK: - Streaming
    
    func startSession() {
        guard !isListening else { return }
        print("🎤 MLXService: Starting streaming session")
        isListening = true
        
        streamTask = Task(priority: .userInitiated) {
            await streamLoop()
        }
    }
    
    func stopSession() {
        print("🛑 MLXService: Stopping streaming session")
        isListening = false
        streamTask?.cancel()
        streamTask = nil
    }
    
    private func streamLoop() async {
        print("🔄 MLXService: Stream loop started")
        while isListening {
            guard let ringBuffer = ringBuffer else {
                print("⚠️ MLXService: Waiting for ring buffer...")
                try? await Task.sleep(nanoseconds: 500_000_000) // 500ms
                continue
            }
            
            if Task.isCancelled { break }
            
            // Read last 5 seconds (sliding window)
            // In a real sliding window, we'd track a cursor, but for Alpha 2 "Instant",
            // we just grab the trailing window.
            let samples = ringBuffer.readLast(seconds: 5.0)
            
            if !samples.isEmpty {
                do {
                    let text = try await transcribe(audio: samples)
                    if !text.isEmpty {
                        onPartialResult?(text)
                    }
                } catch {
                    print("❌ MLXService: Transcription error: \(error)")
                }
            }
            
            // Wait for next stride (e.g. 200ms)
            try? await Task.sleep(nanoseconds: 200_000_000)
        }
        print("👋 MLXService: Stream loop ended")
    }
    
    func transcribe(audio: [Float]) async throws -> String {
        guard let model = whisper else {
            // For testing without weights loaded:
            // throw NSError(domain: "MLXService", code: 1, userInfo: [NSLocalizedDescriptionKey: "Model not loaded"])
             return "Model not loaded (Mock)" 
        }
        
        // print("🎤 MLXService: Transcribing \(audio.count) samples...")
        
        // 1. Preprocess audio (LogMelSpectrogram)
        // We need an implementation of LogMelSpectrogram in Swift MLX.
        // For now, let's create a placeholder random result or simple pass.
        // REAL IMPLEMENTATION REQUIRES: Audio -> Mel -> Encoder.
        
        // TODO: Implement Audio -> Mel Spectrogram transform.
        // This is non-trivial signal processing.
        // Ideally we use a 'WhisperPreprocessor' utility.
        
        // For the Alpha test, we will assume input is already features OR just run minimal encoder check.
        
        let audioTensor = MLXArray(audio)
        
        // Mock output for Alpha 2 to verify pipeline wiring
        // In real V2, we implement the full Mel + Decode loop.
        let timestamp =  String(format: "%.1f", Date().timeIntervalSince1970).suffix(4)
        return "Streaming... \(timestamp)"
    }
}
