import Foundation

/// The entry point for the XPC Service (listener delegate).
/// This class will eventually be instantiated by the `main.swift` of the XPC Service target.
class DictationServiceDelegate: NSObject, NSXPCListenerDelegate {
    
    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection newConnection: NSXPCConnection) -> Bool {
        // In a real XPC service, we might verify the client's code signature here.
        
        // Export the service object that implements the protocol
        let serviceObject = DictationService()
        newConnection.exportedInterface = NSXPCInterface(with: DictationXPCServiceProtocol.self)
        newConnection.exportedObject = serviceObject
        
        // Set up the remote interface to talk back to the client (Main App)
        newConnection.remoteObjectInterface = NSXPCInterface(with: DictationXPCClientProtocol.self)
        
        // Handle invalidation (client died)
        newConnection.invalidationHandler = {
            // TODO: Stop any active recording/processing
            print("XPC Service: Connection invalidated")
        }
        
        newConnection.resume()
        return true
    }
}

/// The actual worker object that receives XPC messages.
class DictationService: NSObject, DictationXPCServiceProtocol {
    
    // Future: AudioRingBuffer (mapped from IOSurface)
    // Future: VADService
    // Future: Transcriber
    
    func configureSharedAudioTransport(_ descriptor: Data, reply: @escaping (Bool) -> Void) {
        print("XPC Service: Received IOSurface descriptor (\(descriptor.count) bytes)")
        
        // TODO: Reconstruct IOSurface from xpc_data (descriptor)
        // let surface = IOSurface(xpcData: descriptor)
        // let ringBuffer = AudioRingBuffer(surface: surface)
        
        reply(true)
    }
    
    func startDictation(reply: @escaping (Bool) -> Void) {
        print("XPC Service: Start command received")
        // TODO: Activate VAD and Consumer loop
        reply(true)
    }
    
    func stopDictation(reply: @escaping (Bool) -> Void) {
        print("XPC Service: Stop command received")
        // TODO: Stop loops
        reply(true)
    }
}
