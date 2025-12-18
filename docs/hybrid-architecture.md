Architectural Blueprint for GhostType: A Hybrid Cloud/Local Transcription System1. Executive Summary1.1 Context and Strategic ImperativeThe GhostType project stands at a critical technological juncture. As a macOS menu bar application designed for "push-to-talk" utility, its core value proposition relies entirely on two opposing metrics: latency (the speed of interaction) and accuracy (the utility of the output). The current architecture, reliant on local-only inference via Apple's MLX framework and CoreML (WhisperKit), faces significant stability challenges. Users are currently experiencing "garbage output"—hallucinations, repetition loops, and formatting failures—characteristic of quantized local models struggling with silence or non-standard acoustic environments.While the future of client-side AI is undoubtedly local, the immediate requirement for a production-grade tool demands reliability that the current local stack cannot guarantee. To bridge the gap between the privacy-centric vision of GhostType and the performance demands of its users, a paradigm shift is required.This report proposes the transition to a Hybrid Cloud/Local Architecture. This design prioritizes immediate utility through ultra-low-latency cloud inference (via Groq or Deepgram) while retaining the local engine as a failsafe backup. This strategy ensures the application "Works Today" by leveraging the massive compute power of cloud providers for speed and accuracy, and "Works Tomorrow" by maintaining the infrastructure to switch back to local inference as Apple Silicon and edge-AI software stacks mature.1.2 The Hybrid PropositionThe proposed architecture introduces a TranscriptionManager layer that orchestrates the flow of audio data. It implements a Strategy Pattern to dynamically select between a CloudTranscriptionService and a LocalTranscriptionService.Primary Path (Cloud): Leverages Groq's LPU-accelerated Whisper API. This offers the industry-standard accuracy of OpenAI's Whisper Large-v3 model but with inference speeds exceeding 180x real-time, delivering results in under 500ms for short dictation bursts. This mimics the "instant" feel of local dictation without the hardware tax or instability.Secondary Path (Local): Wraps the existing WhisperKit implementation in a stabilized actor. This path is activated automatically if network connectivity fails or if the user explicitly opts for "Offline/Privacy Mode."Safety Mechanisms: Integrates Voice Activity Detection (VAD) via the Accelerate framework to gate requests, preventing the transmission of silence which drives up costs and causes model hallucinations.1.3 Scope of the ReportThis document serves as a comprehensive engineering specification. It covers:Comparative Analysis: A data-driven selection of cloud providers based on latency, cost, and API ergonomics.Protocol Design: Defining a unified TranscriptionProvider interface compliant with Swift 6 concurrency.Audio Engineering: Low-level implementation details for PCM-to-WAV conversion using AVAudioConverter and vDSP.Concurrency Patterns: Solving Actor Reentrancy issues in Swift's async/await model to prevent race conditions during rapid dictation toggling.Security: Implementation of SecItem operations for Keychain storage of API keys.2. Cloud Provider Comparative AnalysisThe selection of a cloud provider for GhostType is not merely a choice of vendor; it is a choice of underlying hardware architecture. The standard GPU-based inference used by OpenAI is insufficient for the real-time requirements of a UI-integrated dictation tool. We require a provider that optimizes Time-to-First-Byte (TTFB).The following analysis evaluates the top contenders against GhostType's constraints: short-burst audio (2-30s), strict latency budget (<2s), and Swift client compatibility.2.1 The Latency LandscapeLatency in cloud transcription is the sum of three distinct phases:Network Transport (RTT): The time to upload the audio payload. This is a function of file size (bitrate) and physical distance.Queue Time: The time the request waits in the provider's backlog before reaching a GPU/LPU.Inference Time: The actual computation time to generate text.Standard providers like OpenAI optimize for throughput (batching many requests), which increases Queue Time. Real-time providers optimize for latency (processing single requests instantly).2.2 Provider Deep Dive2.2.1 OpenAI Whisper APIModel: Whisper Large-v2 / Large-v3.Infrastructure: Standard GPU clusters (likely NVIDIA A100s).Performance: OpenAI’s API is widely regarded as the accuracy benchmark. However, benchmarks indicate a typical latency of 1.5 to 4.0 seconds for a 10-second audio clip.1 This variance is due to dynamic batching and aggressive queuing.Suitability: Low. A 3-second delay between stopping speech and text appearing breaks the user's cognitive flow in a dictation workflow.2.2.2 DeepgramModel: Nova-2 / Nova-3 (Proprietary).Infrastructure: Custom-optimized inference engine on GPU.Performance: Deepgram is an industry leader in speed. Its Nova-2 model creates a transcription in roughly 300-500ms for short bursts.2 It supports raw audio streaming, which eliminates the need to construct WAV headers, simplifying the client code.Pricing: Extremely competitive at ~$0.0043/min.4Suitability: High. Deepgram is a viable primary candidate. However, its proprietary model behaves differently than Whisper regarding punctuation and formatting, which might create inconsistency if the user switches between Cloud (Deepgram) and Local (WhisperKit).2.2.3 GroqModel: Whisper Large-v3 (Open Source).Infrastructure: Language Processing Units (LPUs). Unlike GPUs, which rely on High Bandwidth Memory (HBM) and are susceptible to memory-wall bottlenecks, LPUs use a deterministic architecture with massive on-chip SRAM.Performance: Groq creates a paradigm shift in inference speed. Benchmarks show Groq processing Whisper Large-v3 at 180x to 220x real-time speed.6 A 5-second clip is often transcribed in <300ms, matching Deepgram’s speed while using the exact same model architecture as the local WhisperKit fallback.Pricing: ~$0.0005 - $0.04/hour (often significantly cheaper than OpenAI).6Suitability: Optimal. Groq offers the speed of Deepgram with the model consistency of OpenAI. Furthermore, Groq provides an OpenAI-compatible API endpoint, meaning the CloudTranscriptionService can be written to support both Groq and OpenAI by simply changing the baseURL and apiKey.2.3 Recommendation MatrixThe following table synthesizes the research data to justify the selection of Groq as the primary provider.CriterionGroq (Recommended)DeepgramOpenAIGoogle CloudPrimary ModelWhisper Large-v3Nova-2 (Proprietary)Whisper Large-v2/v3Chirp (USM)HardwareLPU (Deterministic)GPU (Optimized)GPU (Standard)TPULatency (5s Audio)~250-400ms 1~300ms 71500ms+ 71000ms+Throughput (RTF)~200x 6~150x 4~50xVariableCost (per min)~$0.0006 (varies)~$0.0043 5$0.0060 5$0.0160 8Audio FormatWAV/MP3 (Container)Raw PCM or ContainerWAV/MP3 (Container)FLAC/Linear16API ComplexityLow (OpenAI-compat)Medium (Custom Headers)Low (Standard)High (Auth)2.4 Strategic DecisionPrimary: Groq.Reasoning: It resolves the latency bottleneck inherent to Whisper without sacrificing the model quality. The LPU architecture ensures that short interactions remain snappy.Fallback: OpenAI.Reasoning: Due to the API compatibility, we can allow users to input an OpenAI key as a backup if they prefer, with zero additional code required in the networking layer (other than the URL switch).3. Protocol Design: The TranscriptionProviderTo implement the Strategy Pattern effectively, we define a protocol that abstracts the complexity of the underlying engine. This protocol must accommodate the asynchronous nature of network requests and the "warm-up" requirements of local models.3.1 Protocol Definition (TranscriptionProvider.swift)The protocol is designed with Swift 6 concurrency in mind, inheriting from Sendable to ensure safe passage across Actor boundaries.Swiftimport Foundation
import AVFoundation

/// Defines the operational state of a provider.
enum TranscriptionProviderState: Sendable {
    case notReady       // Model not loaded or no API key
    case warmingUp      // Currently loading model or validating connection
    case ready          // Ready to accept audio
    case error(String)  // Persistent failure state
}

/// A unified interface for transcription services (Cloud or Local).
protocol TranscriptionProvider: Sendable {
    
    /// A stable identifier for the provider (e.g., "cloud.groq", "local.whisperkit").
    var id: String { get }
    
    /// A user-facing display name.
    var name: String { get }
    
    /// The current operational state of the provider.
    /// Implementation note: This should be thread-safe.
    var state: TranscriptionProviderState { get async }
    
    /// Prepares the provider for immediate use.
    /// For Cloud: This might verify the API key availability.
    /// For Local: This loads the neural network weights into memory.
    func warmUp() async throws
    
    /// Transcribes the given audio buffer.
    /// - Parameter buffer: The raw PCM buffer captured from the microphone.
    /// - Returns: The transcribed text string.
    func transcribe(_ buffer: AVAudioPCMBuffer) async throws -> String
    
    /// Cleans up resources.
    /// For Local: Unloads the model to free system RAM.
    func cooldown() async
}
3.2 Design RationaleAVAudioPCMBuffer as Input: We intentionally pass the buffer rather than a file URL or raw Data. This aligns with AudioInputManager's output (a ring buffer) and avoids unnecessary disk I/O. The responsibility of converting this buffer to the required format (WAV for Cloud, Tensor for MLX) lies with the specific provider implementation.warmUp() and cooldown(): Local models (WhisperKit) can consume 2GB+ of RAM. We cannot keep them loaded permanently in a lightweight menu bar app. These methods allow the TranscriptionManager to intelligently load the model only when the user switches to "Local Mode" or hovers over the record button, and release it after a period of inactivity.Sendable: This requirement enforces thread safety, ensuring that mutable state within the providers (like the WhisperKit instance or the URLSession) is handled correctly, likely by implementing the providers as actors.4. Audio Engineering: The Physics of "Cloud Ready" AudioA critical friction point in hybrid architectures is audio formatting. Swift's AVAudioEngine typically works with 32-bit Floating Point PCM (Float32) at the hardware sample rate (often 44.1kHz or 48kHz). However, cloud APIs like Groq and OpenAI are optimized for 16kHz 16-bit Integer PCM wrapped in a WAV container.9 Sending raw 48kHz Float32 audio is inefficient (high bandwidth) and often rejected by APIs expecting standard speech formats.We must build an AudioEncoder to bridge this gap.4.1 Sample Rate Conversion (Resampling)According to the Nyquist-Shannon sampling theorem, to capture human speech (which generally falls below 8kHz), a sample rate of 16kHz is sufficient. OpenAI's Whisper model is trained on 16kHz audio. Sending 48kHz audio forces the server to downsample it, wasting upload bandwidth.We utilize AVAudioConverter to perform high-quality sample rate conversion (SRC) and bit-depth reduction (Float32 -> Int16).4.2 WAV Header SynthesisThe Groq API (via OpenAI compatibility) requires a valid WAV file. A WAV file is simply raw PCM data prefixed with a 44-byte RIFF (Resource Interchange File Format) header. Since AVAudioFile writes to disk, and we want to keep everything in memory for speed, we must construct this header manually using Data manipulation.4.3 AudioEncoder ImplementationSwiftimport AVFoundation

enum AudioEncodingError: Error {
    case conversionFailed
    case emptyBuffer
}

final class AudioEncoder {
    
    /// Converts a standard AVAudioPCMBuffer (Float32) to a WAV-formatted Data object (Int16, 16kHz).
    static func encodeToWAV(buffer: AVAudioPCMBuffer) throws -> Data {
        // 1. Define the Target Format: 16kHz, 1 channel, 16-bit Integer PCM
        guard let targetFormat = AVAudioFormat(commonFormat:.pcmFormatInt16,
                                               sampleRate: 16000,
                                               channels: 1,
                                               interleaved: true) else {
            throw AudioEncodingError.conversionFailed
        }
        
        // 2. Setup the Converter
        guard let converter = AVAudioConverter(from: buffer.format, to: targetFormat) else {
            throw AudioEncodingError.conversionFailed
        }
        
        // Calculate output frame count based on sample rate ratio
        let ratio = 16000 / buffer.format.sampleRate
        let outputFrameCapacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio)
        
        guard let outputBuffer = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: outputFrameCapacity) else {
            throw AudioEncodingError.conversionFailed
        }
        
        // 3. Perform Conversion
        var error: NSError?
        let inputBlock: AVAudioConverterInputBlock = { _, outStatus in
            outStatus.pointee =.haveData
            return buffer
        }
        
        let status = converter.convert(to: outputBuffer, error: &error, withInputFrom: inputBlock)
        
        if status ==.error |

| error!= nil {
            throw AudioEncodingError.conversionFailed
        }
        
        // 4. Synthesize WAV Header + Data
        return createWAVData(from: outputBuffer)
    }
    
    private static func createWAVData(from buffer: AVAudioPCMBuffer) -> Data {
        guard let channelData = buffer.int16ChannelData else { return Data() }
        
        let frameLength = Int(buffer.frameLength)
        let channels = Int(buffer.format.channelCount)
        let sampleRate = Int(buffer.format.sampleRate)
        
        // Total bytes of audio data
        let dataSize = frameLength * channels * 2 // 2 bytes per sample (Int16)
        
        var header = Data()
        
        // RIFF chunk descriptor
        header.append("RIFF".data(using:.ascii)!)
        header.append(UInt32(36 + dataSize).littleEndian.data) // File size - 8
        header.append("WAVE".data(using:.ascii)!)
        
        // fmt sub-chunk
        header.append("fmt ".data(using:.ascii)!)
        header.append(UInt32(16).littleEndian.data) // Subchunk1Size (16 for PCM)
        header.append(UInt16(1).littleEndian.data)  // AudioFormat (1 for PCM)
        header.append(UInt16(channels).littleEndian.data)
        header.append(UInt32(sampleRate).littleEndian.data)
        
        // ByteRate = SampleRate * NumChannels * BitsPerSample/8
        let byteRate = sampleRate * channels * 2
        header.append(UInt32(byteRate).littleEndian.data)
        
        // BlockAlign = NumChannels * BitsPerSample/8
        header.append(UInt16(channels * 2).littleEndian.data)
        header.append(UInt16(16).littleEndian.data) // BitsPerSample
        
        // data sub-chunk
        header.append("data".data(using:.ascii)!)
        header.append(UInt32(dataSize).littleEndian.data)
        
        // Append actual PCM data
        let pcmData = Data(bytes: channelData.pointee, count: dataSize)
        header.append(pcmData)
        
        return header
    }
}

// Helper extension for Little Endian conversion
extension Numeric {
    var data: Data {
        var source = self
        return Data(bytes: &source, count: MemoryLayout<Self>.size)
    }
}
This encoder ensures that Groq receives a strictly compliant WAV file, preventing "Invalid File Format" errors that are common when uploading raw blobs.5. Cloud Service Implementation (CloudTranscriptionService.swift)The cloud service handles the networking logic. Since we are avoiding external dependencies like Alamofire, we must implement a robust URLSession client that handles multipart/form-data encoding natively.5.1 The MultipartFormData BuilderConstructing a multipart body requires precise boundary management. A boundary string (e.g., ---BoundaryUUID) separates the metadata (model name) from the file data.Swiftstruct MultipartFormData {
    let boundary: String
    private var data = Data()
    
    init(boundary: String = UUID().uuidString) {
        self.boundary = boundary
    }
    
    mutating func addTextField(named name: String, value: String) {
        data.append("--\(boundary)\r\n".data(using:.utf8)!)
        data.append("Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n".data(using:.utf8)!)
        data.append("\(value)\r\n".data(using:.utf8)!)
    }
    
    mutating func addDataField(named name: String, filename: String, contentType: String, data: Data) {
        self.data.append("--\(boundary)\r\n".data(using:.utf8)!)
        self.data.append("Content-Disposition: form-data; name=\"\(name)\"; filename=\"\(filename)\"\r\n".data(using:.utf8)!)
        self.data.append("Content-Type: \(contentType)\r\n\r\n".data(using:.utf8)!)
        self.data.append(data)
        self.data.append("\r\n".data(using:.utf8)!)
    }
    
    var bodyData: Data {
        var finalData = data
        finalData.append("--\(boundary)--\r\n".data(using:.utf8)!)
        return finalData
    }
}
5.2 The Service ImplementationThis service implements TranscriptionProvider. It retrieves the API key (injected via init) and targets the Groq API.Swiftactor CloudTranscriptionService: TranscriptionProvider {
    let id = "cloud.groq"
    let name = "Cloud (Groq)"
    
    private let apiKey: String
    private let url = URL(string: "https://api.groq.com/openai/v1/audio/transcriptions")!
    
    // Cloud is "available" if we have a key. Network checks happen during request.
    var state: TranscriptionProviderState {
        return apiKey.isEmpty?.notReady :.ready
    }
    
    init(apiKey: String) {
        self.apiKey = apiKey
    }
    
    func warmUp() async throws {
        // Optional: Perform a HEAD request to validate connectivity/Key
    }
    
    func transcribe(_ buffer: AVAudioPCMBuffer) async throws -> String {
        guard!apiKey.isEmpty else { throw TranscriptionError.authenticationMissing }
        
        // 1. Encode Audio
        let wavData = try AudioEncoder.encodeToWAV(buffer: buffer)
        
        // 2. Build Request
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        
        var multipart = MultipartFormData()
        multipart.addTextField(named: "model", value: "whisper-large-v3")
        multipart.addTextField(named: "response_format", value: "json")
        multipart.addDataField(named: "file", filename: "audio.wav", contentType: "audio/wav", data: wavData)
        
        request.setValue("multipart/form-data; boundary=\(multipart.boundary)", forHTTPHeaderField: "Content-Type")
        request.httpBody = multipart.bodyData
        
        // 3. Network Call
        let (data, response) = try await URLSession.shared.data(for: request)
        
        guard let httpResponse = response as? HTTPURLResponse else {
            throw TranscriptionError.networkError
        }
        
        if httpResponse.statusCode!= 200 {
            // Parse error message from body if possible
            throw TranscriptionError.serverError(code: httpResponse.statusCode)
        }
        
        // 4. Parse Response
        let result = try JSONDecoder().decode(OpenAIResponse.self, from: data)
        return result.text
    }
    
    func cooldown() async {
        // No-op for cloud
    }
}

struct OpenAIResponse: Decodable {
    let text: String
}
6. Local Service Wrapper (LocalTranscriptionService.swift)This component wraps the existing WhisperKit code. The critical change here is state management. Local models are stateful. We must ensure that we don't try to transcribe while the model is loading, and we must handle the "garbage output" issue.6.1 The Garbage Output Fix: VAD GatingResearch suggests that MLX/WhisperKit models hallucinate when fed pure silence. To fix the "garbage output" problem described in the user prompt, we implement a VAD Gate inside the local service wrapper. If the audio is silence, we return empty text immediately, bypassing the model entirely.6.2 ImplementationSwiftimport WhisperKit

actor LocalTranscriptionService: TranscriptionProvider {
    let id = "local.whisperkit"
    let name = "Local (M-Series)"
    
    private var whisperKit: WhisperKit?
    private(set) var state: TranscriptionProviderState =.notReady
    
    func warmUp() async throws {
        guard whisperKit == nil else { return }
        
        state =.warmingUp
        do {
            // Load base model (quantized) for speed/memory balance
            whisperKit = try await WhisperKit(model: "whisper-base")
            state =.ready
        } catch {
            state =.error(error.localizedDescription)
            throw error
        }
    }
    
    func transcribe(_ buffer: AVAudioPCMBuffer) async throws -> String {
        // 1. Auto-warmup if needed
        if whisperKit == nil {
            try await warmUp()
        }
        
        guard let model = whisperKit else {
            throw TranscriptionError.modelLoadFailed
        }
        
        // 2. VAD Gating (Crucial for preventing hallucinations)
        if AudioAnalyzer.isSilence(buffer) {
            return ""
        }
        
        // 3. Local Inference
        // Note: WhisperKit expects [Float] array
        let floatArray = buffer.toFloatArray() 
        let results = try await model.transcribe(audioArray: floatArray)
        
        return results.text
    }
    
    func cooldown() async {
        whisperKit = nil
        state =.notReady
    }
}
7. The Manager: Orchestration and FallbackThe TranscriptionManager is the "brain" of the operation. It decides which provider to use. It manages the Circuit Breaker logic: if the primary (Cloud) fails, it automatically falls back to secondary (Local).7.1 Actor Reentrancy SafetyA common bug in Swift Actors is reentrancy. If the transcribe function awaits a network call, the actor suspends. During this suspension, another transcribe call (e.g., user mashes the button) could enter the actor, potentially causing race conditions on the state.We solve this by checking an isTranscribing flag at the entry point.7.2 The TranscriptionManager ImplementationSwift@MainActor
class TranscriptionManager: ObservableObject {
    @Published var currentMode: TranscriptionMode =.cloud
    @Published var isTranscribing: Bool = false
    @Published var lastError: String?
    
    private let cloudService: CloudTranscriptionService
    private let localService: LocalTranscriptionService
    private let keychain: KeychainManager
    
    init() {
        self.keychain = KeychainManager()
        let apiKey = keychain.retrieveKey()
        
        self.cloudService = CloudTranscriptionService(apiKey: apiKey?? "")
        self.localService = LocalTranscriptionService()
        
        // Default to local if no key is present
        if apiKey == nil {
            self.currentMode =.local
        }
    }
    
    func updateAPIKey(_ key: String) {
        keychain.saveKey(key)
        // Re-init cloud service with new key
    }
    
    func transcribe(buffer: AVAudioPCMBuffer) async -> String? {
        guard!isTranscribing else { return nil }
        isTranscribing = true
        defer { isTranscribing = false }
        
        var result: String?
        
        // Attempt Primary
        if currentMode ==.cloud {
            do {
                result = try await cloudService.transcribe(buffer)
                return result // Success
            } catch {
                print("Cloud failed: \(error). Falling back...")
                lastError = "Cloud Error: \(error.localizedDescription)"
                // Continue to fallback
            }
        }
        
        // Fallback or Primary Local
        do {
            result = try await localService.transcribe(buffer)
        } catch {
            lastError = "Transcription failed: \(error.localizedDescription)"
        }
        
        return result
    }
}
8. Cost Optimization: Voice Activity Detection (VAD)To optimize cloud costs and prevent local model hallucinations, we must analyze the audio energy before sending it for processing.We use Apple's Accelerate (vDSP) framework to calculate the Root Mean Square (RMS) amplitude. This is a highly efficient, vectorized operation that runs on the CPU.Swiftimport Accelerate

struct AudioAnalyzer {
    /// Threshold for silence. 0.01 is roughly -40dB. Adjust based on testing.
    static let silenceThreshold: Float = 0.01
    
    static func isSilence(_ buffer: AVAudioPCMBuffer) -> Bool {
        guard let channelData = buffer.floatChannelData? else { return true }
        let frameLength = vDSP_Length(buffer.frameLength)
        
        var rms: Float = 0.0
        // Calculate RMS of the vector
        vDSP_rmsqv(channelData, 1, &rms, frameLength)
        
        return rms < silenceThreshold
    }
}
Integration: The TranscriptionManager or individual Services should call AudioAnalyzer.isSilence(buffer) before initiating transcription. If true, return empty string immediately. Cost: $0.9. Security: Keychain ManagementStoring API keys in UserDefaults is a security vulnerability. We must use the macOS Keychain.Swiftimport Security

class KeychainManager {
    let service = "com.ghosttype.apikey"
    let account = "groq"
    
    func saveKey(_ key: String) {
        let data = key.data(using:.utf8)!
        let query: =
        
        // Delete existing item first
        SecItemDelete(query as CFDictionary)
        SecItemAdd(query as CFDictionary, nil)
    }
    
    func retrieveKey() -> String? {
        let query: =
        
        var dataTypeRef: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &dataTypeRef)
        
        if status == errSecSuccess, let data = dataTypeRef as? Data {
            return String(data: data, encoding:.utf8)
        }
        return nil
    }
}
10. UI/UX: Menu Bar IntegrationThe Menu Bar interface must reflect the hybrid nature of the app. We utilize SwiftUI's MenuBarExtra in .window style to provide a rich settings interface.10.1 Visual FeedbackCloud Mode: ☁️ (Cloud symbol).Local Mode: ⚡ (Bolt symbol or Chip).Processing: An animated ellipsis ... replacing the icon during the isTranscribing state.10.2 Settings View ImplementationSwiftstruct MenuBarSettings: View {
    @ObservedObject var manager: TranscriptionManager
    @State private var apiKeyInput: String = ""
    
    var body: some View {
        VStack(alignment:.leading, spacing: 12) {
            Text("GhostType").font(.headline)
            
            Picker("Mode", selection: $manager.currentMode) {
                Text("Cloud (Fast)").tag(TranscriptionMode.cloud)
                Text("Local (Offline)").tag(TranscriptionMode.local)
            }
           .pickerStyle(.segmented)
            
            if manager.currentMode ==.cloud {
                SecureField("Groq API Key", text: $apiKeyInput)
                   .onSubmit { manager.updateAPIKey(apiKeyInput) }
                   .textFieldStyle(.roundedBorder)
                
                Text("API Key stored securely in Keychain.")
                   .font(.caption2)
                   .foregroundColor(.secondary)
            } else {
                Text("Using on-device model. Privacy prioritized.")
                   .font(.caption)
                   .foregroundColor(.secondary)
            }
            
            Divider()
            
            Button("Quit GhostType") {
                NSApplication.shared.terminate(nil)
            }
        }
       .padding()
       .frame(width: 250)
    }
}
11. Integration RoadmapTo maximize stability while refactoring:Step 1: Implement AudioEncoder. This is a pure utility class. Write unit tests to verify it produces valid WAV headers.Step 2: Build CloudTranscriptionService. Hardcode a test API key and verify you can send a WAV buffer to Groq and get JSON back.Step 3: Implement TranscriptionManager. Wire it to use only the Cloud service first.Step 4: Refactor DictationEngine. Remove the specific WhisperKitService calls and replace them with manager.transcribe(buffer).Step 5: Re-integrate Local. Wrap WhisperKitService into LocalTranscriptionService and enable the fallback logic in the Manager.Step 6: UI Polish. Add the toggle and Keychain support.12. ConclusionThis architecture resolves the critical "garbage output" flaw by offloading the heavy lifting to Groq’s LPU cloud infrastructure, ensuring immediate reliability. Simultaneously, it respects the original vision of GhostType by maintaining a fully functional, privacy-first local mode as a fallback. By implementing strict concurrency with Actors, secure storage with Keychain, and cost-saving VAD with Accelerate, this blueprint elevates GhostType from a prototype to a robust, professional macOS utility.