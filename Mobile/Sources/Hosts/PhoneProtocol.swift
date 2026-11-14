import AlasRemoteKit

/// The phone carries host-channel payloads without decoding them.
typealias PhoneClientMessage = RemoteClientMessageOf<OpaqueHostMessage, OpaqueHostMessage>
typealias PhoneServerMessage = RemoteServerMessageOf<OpaqueHostMessage, OpaqueHostMessage>
typealias PhoneConnection = RemotePeerConnectionOf<OpaqueHostMessage, OpaqueHostMessage>
