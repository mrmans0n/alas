import Foundation
import AlasRemoteKit

public typealias RemotePeerConnection = RemotePeerConnectionOf<HostClientMessage, HostServerMessage>

@MainActor
public protocol RemotePeerConnecting: AnyObject {
    var state: RemotePeerConnection.State { get }
    func connect()
    func disconnect()
    func send(_ message: RemoteClientMessage)
    /// What this link serves the peer back, when the peer's `hello` offers
    /// it; set before `connect()`.
    func acknowledge(_ capabilities: [String])
}

extension RemotePeerConnecting {
    public func acknowledge(_ capabilities: [String]) {}
}

extension RemotePeerConnection: RemotePeerConnecting {}
