import Foundation
import Speech
import AVFoundation
import CoreML

// MARK: - MoonshineTokenizer
struct MoonshineTokenizer {
    let vocabulary: [String: Int]
    let inverseVocabulary: [Int: String]
    let specialTokens: [String: Int]
    
    var bosTokenID: Int { specialTokens["bos_token_id"] ?? 1 }
    var eosTokenID: Int { specialTokens["eos_token_id"] ?? 2 }
    var padTokenID: Int { specialTokens["pad_token_id"] ?? 0 }

    struct VocabFile: Decodable {
        let vocab: [String: Int]
        let special_tokens: [String: Int?]
    }

    init(vocabularyData: Data) throws {
        // Try decoding as the new nested format first
        if let file = try? JSONDecoder().decode(VocabFile.self, from: vocabularyData) {
            self.vocabulary = file.vocab
            self.specialTokens = file.special_tokens.compactMapValues { $0 }
        } else {
            // Fallback for simple map (legacy)
            self.vocabulary = try JSONDecoder().decode([String: Int].self, from: vocabularyData)
            self.specialTokens = [:]
        }
        self.inverseVocabulary = Dictionary(uniqueKeysWithValues: vocabulary.map { ($1, $0) })
    }

    func decode(tokens: [Int]) -> String {
        // Simple word reconstruction. 
        // Real tokenizer (SentencePiece) often uses " " (U+2581) for space.
        // We'll replace it with space.
        let words = tokens.compactMap { inverseVocabulary[$0] }
        var text = words.joined(separator: "")
        text = text.replacingOccurrences(of: " ", with: " ")
        return text.trimmingCharacters(in: .whitespaces)
    }
}

final class Transcriber: TranscriberProtocol {
    private let speechRecognizer: SFSpeechRecognizer?
    private let audioEngine = AVAudioEngine()
    
    // Moonshine properties
    private var moonshineModel: MLModel?
    private var moonshineTokenizer: MoonshineTokenizer?

    // TEMPORARY: Force disable Moonshine to test Apple SFSpeechRecognizer (OPTION A)
    private let forceDisableMoonshine = true
    private var isMoonshineEnabled = false
    private let bundle: Bundle

    // Static Constants for Moonshine Tiny (Static Shape)
    private let staticAudioSamples = 16000 * 10 // 10 seconds
    private let staticSeqLen = 128
    
    private var isMockMode = false
    private let sampleRate: Int = 16000
    
    var onPartialResult: ((String) -> Void)?
    var onFinalResult: ((String) -> Void)?
    
    init(resourceBundle: Bundle) {
        self.bundle = resourceBundle
        speechRecognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US"))
        setupMoonshine()
    }
    
    private func setupMoonshine() {
        do {
            let config = MLModelConfiguration()
            config.computeUnits = .all 

            // Load Combined Model
            if let modelURL = self.bundle.url(forResource: "MoonshineTiny", withExtension: "mlpackage") {
                print("Transcriber: Compiling MoonshineTiny...")
                let compiledURL = try MLModel.compileModel(at: modelURL)
                moonshineModel = try MLModel(contentsOf: compiledURL, configuration: config)
                print("Transcriber: ✅ MoonshineTiny model loaded.")
            } else {
                print("Transcriber: ❌ MoonshineTiny.mlpackage not found.")
                throw TranscriberError.modelLoadingFailed(NSError(domain: "Transcriber", code: 1, userInfo: nil))
            }
            
            // Load Vocabulary
            if let vocabURL = self.bundle.url(forResource: "moonshine_vocab", withExtension: "json"),
               let vocabData = try? Data(contentsOf: vocabURL) {
                moonshineTokenizer = try MoonshineTokenizer(vocabularyData: vocabData)
                print("Transcriber: ✅ Moonshine vocabulary loaded.")
            } else {
                throw TranscriberError.modelLoadingFailed(NSError(domain: "Transcriber", code: 2, userInfo: nil))
            }

            isMoonshineEnabled = !forceDisableMoonshine
            if forceDisableMoonshine {
                print("Transcriber: ⚠️ Moonshine DISABLED (forceDisableMoonshine=true). Using Apple SFSpeechRecognizer.")
            } else {
                print("Transcriber: ✅ Moonshine ASR ready.")
            }
        } catch {
            print("Transcriber: ⚠️ Failed to load Moonshine: \(error.localizedDescription). Using fallback.")
            isMoonshineEnabled = false
        }
    }
    
    func requestAuthorization(completion: @escaping (Bool) -> Void) {
        SFSpeechRecognizer.requestAuthorization { status in
            DispatchQueue.main.async { completion(status == .authorized) }
        }
    }
    
    func startStreaming() throws {
        // Streaming not implemented for Moonshine yet (requires split model).
        // Fallback to SFSpeechRecognizer for streaming if needed, 
        // but for now we focus on the main "Dictation" mode which is buffer-based.
        print("Transcriber: Streaming not fully supported in this mode.")
    }
    
    func stopStreaming() {
        // No-op
    }
    
    /// Transcribe audio buffer using Moonshine (Combined Model)
    func transcribe(buffer: [Float]) -> String {
        let startTime = Date()
        let audioLengthSeconds = Double(buffer.count) / Double(sampleRate)
        print("⏱️  Transcriber: Starting transcription for \(String(format: "%.2f", audioLengthSeconds))s of audio (\(buffer.count) samples)")

        guard isMoonshineEnabled, let model = moonshineModel, let tokenizer = moonshineTokenizer else {
            return fallbackTranscribe(buffer: buffer, startTime: startTime)
        }

        print("Transcriber: Running Moonshine (Static Combined)...")
        
        do {
            // 1. Prepare Audio Input (Static 10s padding)
            let audioInput = try MLMultiArray(shape: [1, NSNumber(value: staticAudioSamples)], dataType: .float32)
            
            // Normalize audio safely (loop to avoid huge allocation)
            var maxAbs: Float = 0.0
            for sample in buffer {
                let val = abs(sample)
                if val > maxAbs { maxAbs = val }
            }
            
            let scale: Float = (maxAbs > 0.0001) ? (0.9 / maxAbs) : 1.0
            print("Transcriber: Input max=\(maxAbs), applying scale=\(scale)")
            
            // Fill audio data (pad with zeros)
            for i in 0..<staticAudioSamples {
                if i < buffer.count {
                    audioInput[i] = NSNumber(value: buffer[i] * scale)
                } else {
                    audioInput[i] = 0.0
                }
            }
            
            // 2. Autoregressive Generation Loop
            var tokenIDs = [tokenizer.bosTokenID]
            
            // Pre-allocate decoder input buffer (Static 128)
            let decoderInput = try MLMultiArray(shape: [1, NSNumber(value: staticSeqLen)], dataType: .int32)
            
            // Initialize with pad tokens
            for i in 0..<staticSeqLen {
                decoderInput[i] = NSNumber(value: tokenizer.padTokenID)
            }
            
            print("Transcriber: Decoding...")
            
            for step in 0..<(staticSeqLen - 1) {
                // Update decoder input with current tokens
                for (index, token) in tokenIDs.enumerated() {
                    decoderInput[index] = NSNumber(value: token)
                }
                
                // Run Prediction
                let inputFeatures = try MLDictionaryFeatureProvider(dictionary: [
                    "input_values": MLFeatureValue(multiArray: audioInput),
                    "decoder_input_ids": MLFeatureValue(multiArray: decoderInput)
                ])
                
                let output = try model.prediction(from: inputFeatures)
                
                guard let logits = output.featureValue(for: "logits")?.multiArrayValue else {
                    throw TranscriberError.modelInferenceFailed(NSError(domain: "Transcriber", code: 3, userInfo: nil))
                }
                
                // Logits shape: (1, 128, vocab_size)
                // We want the prediction for the LAST generated token (index `step`)
                let vocabSize = logits.shape[2].intValue
                let offset = step * vocabSize
                
                // Argmax to find next token
                var maxVal: Float = -Float.greatestFiniteMagnitude
                var nextToken = 0
                
                if logits.dataType == .float32 {
                    let ptr = UnsafeBufferPointer<Float32>(start: logits.dataPointer.bindMemory(to: Float32.self, capacity: logits.count), count: logits.count)
                    for v in 0..<vocabSize {
                        let val = ptr[offset + v]
                        if val > maxVal {
                            maxVal = val
                            nextToken = v
                        }
                    }
                } else {
                    // Slow fallback for non-float32
                    for v in 0..<vocabSize {
                        let val = logits[[0, NSNumber(value: step), NSNumber(value: v)] as [NSNumber]].floatValue
                        if val > maxVal {
                            maxVal = val
                            nextToken = v
                        }
                    }
                }
                
                if nextToken == tokenizer.eosTokenID {
                    break
                }
                
                tokenIDs.append(nextToken)
            }
            
            let text = tokenizer.decode(tokens: tokenIDs)
            let latency = Date().timeIntervalSince(startTime) * 1000
            print("⏱️  Transcriber: Moonshine completed in \(String(format: "%.0f", latency))ms")
            print("Transcriber: Result: '\(text)'")
            return text

        } catch {
            print("Transcriber: ❌ Error: \(error)")
            return fallbackTranscribe(buffer: buffer, startTime: startTime)
        }
    }

    private func fallbackTranscribe(buffer: [Float], startTime: Date) -> String {
        guard let recognizer = speechRecognizer, recognizer.isAvailable else { return "Recognizer unavailable" }
        guard let audioBuffer = createAudioBuffer(from: buffer) else { return "Buffer creation failed" }

        print("⏱️  Transcriber: Using Apple SFSpeechRecognizer (on-device)")
        let recognitionStartTime = Date()

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = false
        if #available(macOS 13.0, *) { request.requiresOnDeviceRecognition = true }

        request.append(audioBuffer)
        request.endAudio()

        var text = ""
        let semaphore = DispatchSemaphore(value: 0)

        recognizer.recognitionTask(with: request) { result, error in
            if let r = result, r.isFinal {
                text = r.bestTranscription.formattedString
                let recognitionLatency = Date().timeIntervalSince(recognitionStartTime) * 1000
                print("⏱️  Transcriber: SFSpeech recognition completed in \(String(format: "%.0f", recognitionLatency))ms")
            }
            if error != nil || result?.isFinal == true {
                semaphore.signal()
            }
        }

        _ = semaphore.wait(timeout: .now() + 10)

        let totalLatency = Date().timeIntervalSince(startTime) * 1000
        print("⏱️  Transcriber: Total transcription latency: \(String(format: "%.0f", totalLatency))ms")
        print("📝 Transcriber: Result: '\(text)'")

        return text
    }
    
    private func createAudioBuffer(from samples: [Float]) -> AVAudioPCMBuffer? {
        guard !samples.isEmpty,
              let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: Double(sampleRate), channels: 1, interleaved: false),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count)) else {
            return nil
        }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        if let data = buffer.floatChannelData?[0] {
            data.update(from: samples, count: samples.count)
        }
        return buffer
    }
}

enum TranscriberError: Error {
    case recognizerUnavailable
    case requestCreationFailed
    case authorizationDenied
    case modelLoadingFailed(Error)
    case modelInferenceFailed(Error)
}