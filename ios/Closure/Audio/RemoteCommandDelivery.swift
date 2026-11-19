import MediaPlayer

/// MediaPlayer does not promise that remote command handlers run on the main actor.
enum RemoteCommandDelivery {
    static func schedule(_ action: @escaping @MainActor @Sendable () -> Void) -> MPRemoteCommandHandlerStatus {
        Task { @MainActor in action() }
        return .success
    }
}
