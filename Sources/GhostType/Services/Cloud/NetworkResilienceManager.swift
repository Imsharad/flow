import Foundation

/// Defines the outcome of a network attempt logic.
enum RetryAction {
    case retry(delay: TimeInterval)
    case fail(Error)
}

/// A thread-safe utility for managing network resilience.
actor NetworkResilienceManager {
    static let shared = NetworkResilienceManager()
    
    // Configuration
    private let maxRetries = 3
    private let baseDelay: TimeInterval = 1.0
    private let maxDelay: TimeInterval = 10.0
    
    // Circuit Breaker State
    private var consecutiveFailures = 0
    private let failureThreshold = 5
    private var circuitOpenTime: Date?
    private let circuitCooldown: TimeInterval = 60.0
    
    private var isCircuitOpen: Bool {
        if let openTime = circuitOpenTime {
            if Date().timeIntervalSince(openTime) > circuitCooldown {
                // Cooldown passed, reset (Half-Open logic simplified here)
                return false
            }
            return true
        }
        return false
    }
    
    /// Determines what action to take after an error.
    func determineAction(for error: Error, attempt: Int) -> RetryAction {
        // 1. Check Circuit Breaker
        if isCircuitOpen {
            return .fail(NSError(domain: "GhostType", code: 503, userInfo: [NSLocalizedDescriptionKey: "Circuit Breaker Open"]))
        }
        
        // 2. Classify Error
        guard isRetryable(error) else {
            consecutiveFailures += 1
            checkCircuitTrip()
            return .fail(error)
        }
        
        // 3. Check Retry Limit
        if attempt >= maxRetries {
            consecutiveFailures += 1
            checkCircuitTrip()
            return .fail(error)
        }
        
        // 4. Calculate Backoff with Jitter
        // Delay = min(Cap, Base * 2^attempt)
        let exponentialDelay = min(maxDelay, baseDelay * pow(2.0, Double(attempt)))
        // Jitter = random between 0.8x and 1.2x of delay
        let jitter = Double.random(in: 0.8...1.2)
        let finalDelay = exponentialDelay * jitter
        
        return .retry(delay: finalDelay)
    }
    
    func recordSuccess() {
        consecutiveFailures = 0
        circuitOpenTime = nil
    }
    
    private func checkCircuitTrip() {
        if consecutiveFailures >= failureThreshold {
            circuitOpenTime = Date()
            print("⚠️ NetworkResilienceManager: Circuit Breaker Tripped. Pausing cloud requests.")
        }
    }
    
    private func isRetryable(_ error: Error) -> Bool {
        let nsError = error as NSError
        // Rate Limit (429) or Server Error (5xx) or Offline (-1009)
        if nsError.domain == NSURLErrorDomain {
            // Most URLSession errors are retryable (timeout, connection lost)
            return true
        }
        
        // Check for HTTPURLResponse status codes
        if let transcriptionError = error as? TranscriptionError {
            switch transcriptionError {
            case .serverError(let code):
                return code == 429 || (code >= 500 && code < 600)
            case .networkError:
                return true
            default:
                return false
            }
        }
        
        return false
    }
}
