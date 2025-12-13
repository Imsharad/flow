import Foundation

/// Future XPC interfaces (PRD-required).
///
/// These are placeholders so the UI can target stable message shapes while the
/// actual XPC service target is implemented in an Xcode project.
///
/// NOTE: Implementing a real XPC service bundle is not supported by SwiftPM
/// alone; we'll move to an Xcode project for the service target.
@objc protocol DictationXPCClientProtocol {
    func didUpdatePartialText(_ text: String)
    func didFinalizeText(_ text: String)
    func didUpdateState(_ state: String)
}

@objc protocol DictationXPCServiceProtocol {
    /// Configure shared memory transport. In the PRD this is an IOSurface ID.
    func configureSharedAudioTransport(_ descriptor: Data, reply: @escaping (Bool) -> Void)

    func startDictation(reply: @escaping (Bool) -> Void)
    func stopDictation(reply: @escaping (Bool) -> Void)
}
