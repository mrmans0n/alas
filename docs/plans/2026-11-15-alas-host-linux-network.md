# alas-host on Linux: the network seam (phase 4)

Part of `2026-11-15-alas-host-linux-design.md`.

## What uses Apple's Network framework in the host

| Code | Uses | On Linux |
|---|---|---|
| `RemoteServer`, `RemoteConnection` | `NWListener` on a port (or loopback only), `NWConnection` receive/send/cancel | needed |
| `PeerPortForwardHost` | `NWConnection` dialing a run's local port, with ready/failed states | needed (a Mac opens a host run's port) |
| `PeerPortForwarder` | `NWListener` on loopback, accepting local clients | needed only where a host forwards a peer's port; same seam, so free |
| `RemoteBonjourService`, `RemotePeerBrowser`, `RemoteDiscoveredInstanceResolver` | Bonjour advertise, browse, resolve | compiled out: pair by address |
| `RemoteNetwork` (`SystemConfiguration`) | interface addresses | `getifaddrs`, which macOS has too |
| `RemoteKeepAwakeController` (`IOKit`) | power assertions | no-op |

None of it reads a peer's address: the server parses HTTP and WebSocket
itself (`HTTPRequestParser`, `WebSocketFrame`) and checks the `Host`
header, so all it needs from the platform is a byte pipe.

## The seam

`AlasHostCore/Remote/Transport/`:

```swift
/// One TCP connection, its callbacks on the queue it was started on.
public protocol TCPStream: AnyObject, Sendable {
    var onState: (@Sendable (TCPStreamState) -> Void)? { get set }   // ready, failed(Error)
    func start(queue: DispatchQueue)
    func receive(maximumLength: Int, completion: @escaping @Sendable (Data?, _ isComplete: Bool, Error?) -> Void)
    func send(_ data: Data, completion: @escaping @Sendable (Error?) -> Void)
    func cancel()
}

public protocol TCPListener: AnyObject, Sendable {
    var onState: (@Sendable (TCPListenerState) -> Void)? { get set }  // ready(port), failed, cancelled
    var onConnection: (@Sendable (any TCPStream) -> Void)? { get set }
    func start(queue: DispatchQueue)
    func cancel()
}

public enum TCP {
    static func listener(port: UInt16, host: TCPHost) throws -> any TCPListener   // .any, .loopbackV4, .loopbackV6
    static func connect(host: String, port: UInt16) -> any TCPStream
}
```

- **macOS:** thin wrappers over `NWListener`/`NWConnection`, so behaviour
  there stays the same. Bonjour stays on the macOS listener, set through
  `RemoteServer.advertise` as today, behind `#if canImport(Network)`.
- **Linux:** nonblocking POSIX sockets (`SocketTCPStream`, `SocketTCPListener`),
  built on every platform so their tests run on macOS too. Accept and read run on a
  `DispatchSourceRead`; writes go out in order from a queue drained by a
  `DispatchSourceWrite`. `.any` binds `::` with `IPV6_V6ONLY` off, so IPv4
  and IPv6 clients both reach it. A send fails with an error when the peer
  is gone (SIGPIPE is ignored, see `NoSigPipe`).

The three users switch from `NW*` types to these; their logic doesn't change.

## Also in this phase

- `HostSocketServer` reads the peer's uid with `SO_PEERCRED` on Linux (no
  `getpeereid`).
- The `alas-host` binary's self-watch uses a folder `FileEventStream` on Linux;
  self-update for Linux is phase 5.
- `HostFileWatcher` (files paired Macs follow) watches the file's folder with
  inotify on Linux, where kqueue vnode sources don't exist.
- No capability changes: the host protocol's capabilities cover worktrees,
  sessions and reviews; the Mac-only features (plugins, VMs, devices,
  dictation) were never served over it.

## Tests

- The whole AlasCore suite runs on Linux in CI, both architectures, including
  the end-to-end tests that launch `alas-host`. Tests of macOS-only features
  compile out there.
- `SocketTCPTests` drives the socket transport through real loopback sockets:
  ordered sends, a peer that closed, a refused connect.
