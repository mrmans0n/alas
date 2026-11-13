public enum RemoteWireLimits {
    /// Hard cap on a single WebSocket frame's payload, shared by both ends of the remote wire.
    public static let maxFrameBytes = 16_000_000
}
