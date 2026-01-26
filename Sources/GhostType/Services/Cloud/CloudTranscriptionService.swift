import Foundation
import AVFoundation

actor CloudTranscriptionService: TranscriptionProvider {
    let id = "cloud.groq"
    let name = "Cloud (Groq)"
    
    private let apiKey: String
    private let url = URL(string: "https://api.groq.com/openai/v1/audio/transcriptions")!
    
    // Cloud is "available" if we have a key. Network checks happen during request.
    var state: TranscriptionProviderState {
        return apiKey.isEmpty ? .notReady : .ready
    }
    
    init(apiKey: String) {
        self.apiKey = apiKey
    }
    
    func warmUp() async throws {
        // Optional: Perform a HEAD request to validate connectivity/Key
    }
    
    func validateAPIKey() async throws -> Bool {
        guard !apiKey.isEmpty else { return false }
        
        // simple validation: create a tiny wav and try to transcribe it.
        // It's not "free" but it's the most reliable way to check since /models endpoint might differ.
        // actually, let's try a simple GET to proper models endpoint if possible?
        // Groq API: https://api.groq.com/openai/v1/models
        
        var request = URLRequest(url: URL(string: "https://api.groq.com/openai/v1/models")!)
        request.httpMethod = "GET"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        
        let (data, response) = try await URLSession.shared.data(for: request)
        
        if let httpResponse = response as? HTTPURLResponse {
            if httpResponse.statusCode == 200 {
                return true
            } else {
                print("❌ CloudService: Validation failed with status \(httpResponse.statusCode)")
                if let body = String(data: data, encoding: .utf8) {
                    print("❌ Body: \(body)")
                }
                return false
            }
        }
        return false
    }
    
    /// Transcription method handling the full pipeline:
    /// 1. Encode Audio (PCM -> WAV)
    /// 2. Construct Multipart Request
    /// 3. Execute with NetworkResilience (Retries/CircuitBreaker)
    func transcribe(_ buffer: AVAudioPCMBuffer, prompt: String?, promptTokens: [Int]?) async throws -> (String, [Int]?) {
        guard !apiKey.isEmpty else { throw TranscriptionError.authenticationMissing }
        
        // 1. Encode Audio
        let wavData: Data
        do {
            wavData = try WAVAudioEncoder.encodeToWAV(buffer: buffer)
        } catch {
            print("❌ CloudService: Encoding failed: \(error)")
            throw TranscriptionError.encodingFailed
        }
        
        // 2. Build Request
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        
        var multipart = MultipartFormData()
        multipart.addTextField(named: "model", value: "whisper-large-v3")
        multipart.addTextField(named: "response_format", value: "json")
        multipart.addTextField(named: "temperature", value: "0.0") 
        
        if let promptContext = prompt {
            multipart.addTextField(named: "prompt", value: promptContext)
        }
        
        multipart.addDataField(named: "file", filename: "audio.wav", contentType: "audio/wav", data: wavData)
        
        request.setValue("multipart/form-data; boundary=\(multipart.boundary)", forHTTPHeaderField: "Content-Type")
        request.httpBody = multipart.bodyData
        
        // 3. Network Call with Resilience using the Manager (to be injected/instantiated)
        // For now, we call directly, but Phase 2 Task 5 will add the manager.
        // We will anticipate the extension method `performRequestWithRetry`.
        
        let text = try await performRequest(request)
        return (text, nil)
    }
    
    private func performRequest(_ request: URLRequest) async throws -> String {
        let resilience = NetworkResilienceManager.shared
        var attempt = 0
        
        while true {
            let start = Date()
            do {
                let (data, response) = try await URLSession.shared.data(for: request)
                
                guard let httpResponse = response as? HTTPURLResponse else {
                    throw TranscriptionError.networkError(URLError(.badServerResponse))
                }
                
                if httpResponse.statusCode != 200 {
                    // Try to parse error
                    if let errorJson = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                        print("❌ CloudService: Server Error: \(errorJson)")
                    }
                    throw TranscriptionError.serverError(code: httpResponse.statusCode)
                }
                
                // Success path
                await resilience.recordSuccess()
                
                let duration = Date().timeIntervalSince(start)
                print("⚡️ CloudService: Latency = \(String(format: "%.3f", duration))s")
                
                // Parse Response
                do {
                    let result = try JSONDecoder().decode(OpenAIResponse.self, from: data)
                    return result.text
                } catch {
                    print("❌ CloudService: JSON Decode failed: \(error)")
                    throw TranscriptionError.invalidResponse
                }
                
            } catch {
                let action = await resilience.determineAction(for: error, attempt: attempt)
                switch action {
                case .fail(let finalError):
                    throw finalError
                case .retry(let delay):
                    print("⚠️ CloudService: Retrying in \(String(format: "%.2f", delay))s (Attempt \(attempt + 1))...")
                    try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                    attempt += 1
                }
            }
        }
    }
    
    func cooldown() async {
        // No-op for cloud
    }
}
