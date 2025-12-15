import Foundation

class DictationConnectionManager: NSObject, DictationXPCClientProtocol {
    private var connection: NSXPCConnection?
    
    // Callbacks to bridge to main app
    var onPartialText: ((String) -> Void)?
    var onFinalText: ((String) -> Void)?
    
    override init() {
        super.init()
        // We defer connection setup until requested, or start it immediately if preferred.
        // For now, we'll setup immediately but expect failures until the service exists.
        setupConnection()
    }
    
    func setupConnection() {
        // In a real app, this matches the Service Bundle ID
        // Note: This will fail until the XPC Service target is built and embedded in the App Bundle.
        connection = NSXPCConnection(serviceName: "com.ghosttype.DictationService")
        
        guard let connection = connection else {
            print("Failed to create NSXPCConnection")
            return
        }
        
        connection.remoteObjectInterface = NSXPCInterface(with: DictationXPCServiceProtocol.self)
        connection.exportedInterface = NSXPCInterface(with: DictationXPCClientProtocol.self)
        connection.exportedObject = self
        
        connection.interruptionHandler = {
            print("XPC Connection interrupted - Service crashed or terminated")
        }
        
        connection.invalidationHandler = {
            print("XPC Connection invalidated - Connection closed permanently")
            // TODO: Reconnect logic
        }
        
        connection.resume()
    }
    
    /// Sends the IOSurface ID (wrapped in Data) to the XPC Service
    func sendAudioBuffer(_ descriptor: Data) {
        let service = connection?.remoteObjectProxyWithErrorHandler { error in
            print("XPC Error (sendAudioBuffer): \(error)")
        } as? DictationXPCServiceProtocol
        
        service?.configureSharedAudioTransport(descriptor) { success in
            print("XPC Transport configured: \(success)")
        }
    }
    
    func startDictation() {
        let service = connection?.remoteObjectProxyWithErrorHandler { error in
            print("XPC Error (startDictation): \(error)")
        } as? DictationXPCServiceProtocol
        
        service?.startDictation { success in
            if !success { print("Failed to start XPC dictation") }
        }
    }
    
    func stopDictation() {
        let service = connection?.remoteObjectProxyWithErrorHandler { error in
            print("XPC Error (stopDictation): \(error)")
        } as? DictationXPCServiceProtocol
        
        service?.stopDictation { success in
            if !success { print("Failed to stop XPC dictation") }
        }
    }
    
    // MARK: - Client Protocol
    
    func didUpdatePartialText(_ text: String) {
        DispatchQueue.main.async {
            self.onPartialText?(text)
        }
    }
    
    func didFinalizeText(_ text: String) {
        DispatchQueue.main.async {
            self.onFinalText?(text)
        }
    }
    
    func didUpdateState(_ state: String) {
        print("XPC Service State: \(state)")
    }
}
