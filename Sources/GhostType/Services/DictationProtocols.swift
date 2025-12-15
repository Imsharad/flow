import Foundation

/// Protocol for Voice Activity Detection service.
protocol VADServiceProtocol: AnyObject {
    var onSpeechStart: (() -> Void)? { get set }
    var onSpeechEnd: (() -> Void)? { get set }
    
    func process(buffer: [Float])
    func manualTriggerStart()
    func manualTriggerEnd()
}

/// Protocol for Speech-to-Text transcription service.
protocol TranscriberProtocol: AnyObject {
    var onPartialResult: ((String) -> Void)? { get set }
    var onFinalResult: ((String) -> Void)? { get set }
    
    func startStreaming() throws
    func stopStreaming()
    func transcribe(buffer: [Float]) -> String
}

/// Protocol for Grammar Correction service.
protocol TextCorrectorProtocol: AnyObject {
    func correct(text: String, context: String?) -> String
    func warmUp(completion: (() -> Void)?)
}
