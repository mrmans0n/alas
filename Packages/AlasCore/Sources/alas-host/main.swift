import AlasCore
@_spi(AppHost) import AlasHostCore
import Foundation

// First, before anything can spawn git: the host has no terminal to answer
// a prompt, and this static is read from any thread.
Process.neverPromptsForGit = true

// Serves the host protocol for one data directory, without the app: the
// profile's directory (`ALAS_APP_SUPPORT_DIR`, else the everyday one), on
// the profile's local socket.

let usage = """
usage: alas-host [--wait-for-lock]
       alas-host setup
       alas-host pair
       alas-host install-agent | uninstall-agent
       alas-host config list | get [<key>] | set <key> <value> [--restart]
       alas-host peers list | remove <id|name|serverId>
       alas-host project list | add <path> [--name <name>] | remove <id|path>
       alas-host registry search [<query>] | install <id> | uninstall <id>
       alas-host restart

Serves the Alas host protocol for the data directory ALAS_APP_SUPPORT_DIR
(default: ~/Library/Application Support/Alas) on its local socket, and prints
the socket path. When the profile enables Remote, also serves it on loopback
and prints its address, with the web client of the Alas.app it ships in, of
the one in /Applications, or of ALAS_REMOTE_WEB_DIR. Stops on SIGINT or SIGTERM.

With --wait-for-lock, waits while another process (the app) holds the data
directory instead of exiting, and serves once it lets go.

`alas-host setup` walks through the host's settings, projects and pairing in
a full-screen terminal UI that opens on the current values; rerun it to change
them later.

`alas-host pair` asks the running host for a Remote pairing code, which a
phone, browser or Mac redeems within two minutes, and prints it, then the
pairing link a Mac pastes into Add Peer.

`alas-host peers` lists the Macs paired with this host and removes one,
revoking its access, through the running host when one serves the profile.

`alas-host install-agent` installs and starts a launchd agent that runs this
executable with --wait-for-lock at login, and restarts it after a crash;
`uninstall-agent` stops and removes it. Each profile has its own agent.

`alas-host config` reads and changes the host's settings in the profile's
app.json; the running host applies a change once restarted. `alas-host project`
lists, adds and removes the profile's projects, through the running host when
one serves the profile. `alas-host registry` searches the ACP agent registry,
and installs and uninstalls its agents for the profile. `alas-host restart`
restarts the launch agent's host.
Changes are refused while the app has the profile open.
"""

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("alas-host: \(message)\n".utf8))
    exit(1)
}

if CommandLine.arguments.dropFirst().contains(where: { $0 == "--help" || $0 == "-h" }) {
    print(usage)
    exit(0)
}
if CommandLine.arguments.dropFirst().elementsEqual(["pair"]) {
    let response: HostResponse
    do {
        response = try HostSocketServer.request(.remotePairingCode)
    } catch {
        fail("no host serves \(HostSocketServer.defaultPath()): \(error.localizedDescription)")
    }
    switch response {
    case .remotePairingCode(let code, let expiresAt, let link):
        // The code stays the first line, for scripts; a Mac pastes the link.
        print(code)
        if let link { print(link) }
        var notice = "Valid until \(expiresAt.formatted(date: .omitted, time: .standard)).\n"
        let origins = link.flatMap(RemotePairingLink.parse)?.origins ?? []
        if !origins.isEmpty, origins.allSatisfy({ URL(string: $0).map(RunEndpointPolicy.isLoopback) ?? true }) {
            notice += HostCommands.readConfig().hostReachability == .tailscale
                ? "Reachable only from this Mac: tailscale serve is not running yet, or HTTPS is off on the tailnet.\n"
                : "Reachable only from this Mac or a tunnel; set host.reachability to lan or tailscale for other Macs.\n"
        }
        FileHandle.standardError.write(Data(notice.utf8))
        exit(0)
    case .failure(.failed(let message)):
        fail(message)
    case .failure(.invalidRequest):
        fail("the running host is older and does not mint Remote pairing codes")
    case .failure(let error):
        fail("\(error)")
    default:
        fail("the host does not mint Remote pairing codes")
    }
}
let arguments = Array(CommandLine.arguments.dropFirst())
HostCommands.runIfCommand(arguments)
if arguments == ["install-agent"] || arguments == ["uninstall-agent"] {
    // The path this was started as, links not resolved: Homebrew's link in
    // its `bin` outlives an upgrade, while what it points to (a versioned
    // Caskroom directory, for the alas-host cask) does not.
    let invoked = CommandLine.arguments[0]
    let started: String? = if invoked.contains("/") {
        invoked
    } else {
        (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":")
            .map { "\($0)/\(invoked)" }
            .first { FileManager.default.isExecutableFile(atPath: $0) }
    }
    guard let started else { fail("cannot locate this executable") }
    let executable = URL(fileURLWithPath: started).standardizedFileURL
    let agent = HostLaunchAgent(executable: executable)
    let domain = "gui/\(getuid())"
    // 3 (ESRCH) is an agent that is not loaded: there is nothing to stop.
    let stopped = launchctl("bootout", "\(domain)/\(agent.label)")
    guard stopped == 0 || stopped == ESRCH else {
        fail("launchctl could not stop \(agent.label) (status \(stopped))")
    }
    if arguments == ["uninstall-agent"] {
        do {
            if FileManager.default.fileExists(atPath: agent.plistURL.path) {
                try FileManager.default.removeItem(at: agent.plistURL)
            }
        } catch {
            fail("cannot remove \(agent.plistURL.path): \(error.localizedDescription)")
        }
        print("removed \(agent.plistURL.path)")
        exit(0)
    }
    do {
        // launchd creates the log file, not its directory: the profile's,
        // which a profile the app never opened does not have yet.
        try FileManager.default.createDirectory(at: agent.logURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: agent.plistURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try agent.plistData().write(to: agent.plistURL, options: .atomic)
    } catch {
        fail("cannot write \(agent.plistURL.path): \(error.localizedDescription)")
    }
    guard launchctl("bootstrap", domain, agent.plistURL.path) == 0 else {
        fail("launchctl could not start \(agent.label) from \(agent.plistURL.path)")
    }
    print("installed \(agent.plistURL.path)")
    exit(0)
}
let waitsForLock = arguments == ["--wait-for-lock"]
if !arguments.isEmpty, !waitsForLock {
    fail("unknown argument \(arguments[0])\n\(usage)")
}

// As the launch agent, an app upgrade replaces this executable under the
// running host: it stops, and launchd starts the new one at the same path.
// Opened before the lock is waited for, so an upgrade while the app holds
// the directory is still this file's.
let executablePath = Bundle.main.executableURL?.resolvingSymlinksInPath().path
let executableFD: Int32 = waitsForLock ? executablePath.map { open($0, O_EVTONLY) } ?? -1 : -1
/// Whether the executable at this process's path is no longer the file it started from.
func executableWasReplaced() -> Bool {
    guard executableFD >= 0, let executablePath else { return false }
    var started = stat()
    var current = stat()
    guard fstat(executableFD, &started) == 0 else { return false }
    guard stat(executablePath, &current) == 0 else { return true }
    return started.st_dev != current.st_dev || started.st_ino != current.st_ino
}

// Held until the process exits; the kernel releases it then.
let lock: DataDirectoryLock
do {
    do {
        lock = try DataDirectoryLock.acquire()
    } catch .held(let pid) where waitsForLock {
        FileHandle.standardError.write(Data("alas-host: waiting for \(pid.map { "process \($0)" } ?? "another process") to release \(Paths.appSupportRoot.path)\n".utf8))
        lock = try DataDirectoryLock.acquire(waiting: true)
    }
} catch {
    fail(error.localizedDescription)
}
if executableWasReplaced() {
    // Upgraded while waiting: nothing has started, so launchd starts the
    // new executable in this one's place.
    exit(0)
}

// The `alas` CLI, for agents' MCP server and shells, installed beside `ao`.
let cliBinDir: URL?
let cliBuild: String?
if let cli = HostShellLaunch.cliBinary(executable: Bundle.main.executableURL) {
    do {
        cliBinDir = try TerminalCLIInjection.installExecutables(sourceBinary: cli)
        cliBuild = TerminalCLIInjection.buildIdentity(ofBinaryAt: cli)
    } catch {
        cliBinDir = nil
        cliBuild = nil
        FileHandle.standardError.write(Data("alas-host: cannot install the alas CLI from \(cli.path): \(error.localizedDescription); agents get no alas tools here\n".utf8))
    }
} else {
    cliBinDir = nil
    cliBuild = nil
    FileHandle.standardError.write(Data("alas-host: alas CLI not found beside alas-host or in /Applications/Alas.app; agents get no alas tools here\n".utf8))
}

let host: AlasHost
do {
    host = try AlasHost.boot(cliBinDir: cliBinDir, cliBuild: cliBuild)
} catch {
    fail("cannot load \(Paths.appSupportRoot.path): \(error.localizedDescription)")
}
host.serveCLI()

let protocolServer = HostProtocolServer(host: host)
guard let socket = HostSocketServer(server: protocolServer) else {
    fail("cannot serve \(HostSocketServer.defaultPath()): another host serves it, or its directory is not this user's own")
}

// Shells opened for paired Macs, kept with Remote on or off: they guard
// worktree and project removal before any request arrives. They run in
// zmx, found as the web client is; peers are offered them only with Remote.
let zmx = ZmxClient(env: .resolve(binaryURL: HostShellLaunch.zmxBinary(executable: Bundle.main.executableURL)))
let shells = HostConsoles.install(on: host.coreContext, zmx: zmx, cliBinDir: cliBinDir)

// One shutdown: a second signal must not exit while the first still flushes.
var isStopping = false

// Remote, where the profile's host reachability says: loopback, reached from
// other devices through the `tailscale serve` proxy run here, as the app runs
// it, or a tunnel; or every interface when the LAN is chosen. Accepting
// incoming TCP needs no local network permission, only Bonjour does (TN3179).
// Other Macs pair as peers, as with the app: the host proves its identity key
// on `/pair` and on every later socket. It pairs back only to a Mac too old to
// pair without it: macOS silently denies a launch agent's connections to LAN
// addresses. It never connects out to peers' sessions, and has no federation
// or Bonjour.
var remote: RemoteServer?
/// Starts Remote once the open sessions are restored; nil when Remote is off.
var startRemote: (@MainActor () async -> Void)?
// Held here: `RemoteServer.presenter` is weak.
var openSessions: HeadlessSessionPresenter?
var tailscaleServe: RemoteTailscaleServeProcess?
let keepAwake = RemoteKeepAwakeController()
var config = (try? PersistenceStore().readIfExists(AppConfig.self, from: Paths.appConfigFile)) ?? .defaults
let pairing = RemotePairingService(store: FileDeviceStore())
// Reads the profile's key wherever the app left it, and writes only the
// owner-only file, so an app and a host taking turns keep one identity.
let secrets = RemoteHostSecretStore()
/// What the host tells a Mac it pairs with; set when Remote is on.
var localPeerIdentity: (@MainActor () -> RemotePeerManager.LocalIdentity)?
// Built with Remote off too, so `alas-host peers` still lists and forgets
// the Macs paired while it was on.
let peers = RemotePeerManager(
    store: FilePeerStore(secrets: secrets),
    pairing: pairing,
    localIdentity: { localPeerIdentity?() ?? .init(serverId: "", name: "", origins: []) }
)
peers.onRevokeDevice = { remote?.disconnectDevice($0) }
protocolServer.remotePeers = peers
if let listen = config.hostRemoteListen {
    if config.remote.ensureServerId() {
        // Only the new id is written: keys this build does not model stay.
        let serverId = config.remote.serverId
        do {
            try HostProfileWrite.update { $0.remote.serverId = serverId }
        } catch {
            fail("cannot save \(Paths.appConfigFile.path): \(error.localizedDescription)")
        }
    }
    let settings = config.remote
    let identityKey = RemoteIdentityKeyProvider(store: secrets)
    let interfaces = RemoteNetwork.interfaces()
    // Known once `tailscale serve` runs, so peers and diagnostics name it too.
    var tailnetHTTPSHost: String?
    func advertisedAddresses(port: UInt16?) -> [RemoteAdvertisedAddress] {
        settings.advertisedAddresses(
            port: port, interfaces: interfaces, tailnetHTTPSHost: tailnetHTTPSHost, loopbackOnly: listen.loopbackOnly
        )
    }
    // The web client ships inside the app, beside this executable's own
    // directory there (`Contents/Resources/alas-host/alas-host`), wherever the
    // app is installed and whatever link started it. Without one, devices
    // that already have a client still pair and connect.
    let webClient = [
        ProcessInfo.processInfo.environment["ALAS_REMOTE_WEB_DIR"].map { URL(fileURLWithPath: $0) },
        Bundle.main.executableURL.map {
            $0.resolvingSymlinksInPath().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("RemoteWeb")
        },
        URL(fileURLWithPath: "/Applications/Alas.app/Contents/Resources/RemoteWeb"),
    ].compactMap { $0 }.first { FileManager.default.fileExists(atPath: $0.appendingPathComponent("index.html").path) }
    if !zmx.isAvailable {
        FileHandle.standardError.write(Data("alas-host: zmx not found beside alas-host or in /Applications/Alas.app; peers can't open terminals here\n".utf8))
    }
    if webClient == nil {
        FileHandle.standardError.write(Data("alas-host: no web client found (set ALAS_REMOTE_WEB_DIR); serving pairing and the WebSocket only\n".utf8))
    }
    let server = RemoteServer(
        pairing: pairing,
        assets: RemoteWebAssets(root: webClient ?? URL(fileURLWithPath: "/dev/null")),
        host: host,
        accessPolicy: settings.accessPolicy(interfaces: interfaces, tailnetDNSName: nil),
        originPolicy: settings.originPolicy(interfaces: interfaces, tailnetDNSName: nil),
        diagnostics: { port in
            RemoteDiagnosticsSnapshot(
                appName: "Alas",
                port: port,
                addresses: advertisedAddresses(port: port),
                usesPlainHTTP: true,
                pairedDeviceCount: pairing.devices.count,
                serverId: settings.serverId,
                name: settings.resolvedDisplayName
            )
        },
        // Terminals only with zmx, so a Mac offers none it can't open.
        identity: {
            RemoteServerIdentity(
                serverId: settings.serverId, name: settings.resolvedDisplayName,
                consoleCapabilities: shells.isAvailable ? PeerConsoleCapability.headlessHost : [],
                hostCapabilities: host.servedCapabilities
            )
        },
        signer: identityKey
    )
    localPeerIdentity = {
        RemotePeerManager.LocalIdentity(
            serverId: settings.serverId,
            name: settings.resolvedDisplayName,
            // As the app advertises: loopback means nothing to another
            // Mac, and it refuses more origins than the cap.
            origins: Array(
                advertisedAddresses(port: server.port).filter { $0.kind != .localhost }.map(\.url)
                    .prefix(RemotePairingLink.maxOrigins)
            ),
            publicKey: identityKey.publicKey
        )
    }
    server.pairsBackWithPeers = false
    server.admitsInboundOnlyPeer = { peers.admitsInboundOnlyPeer($0) }
    server.onPeerPaired = { request in
        // Noted on the redeem's own call stack, before the pair-back's task,
        // so a Forget landing in between is not missed (as in the app).
        peers.notePeerPairingArrived(serverId: request.peerServerId, localDeviceId: request.localDeviceId)
        Task { @MainActor in await peers.handleInboundPeer(request) }
    }
    protocolServer.remotePairingLink = { code in
        guard let port = server.port else { return nil }
        let addresses = advertisedAddresses(port: port)
        let base = addresses.first { $0.kind != .localhost }?.url ?? "http://127.0.0.1:\(port)"
        return RemotePairingLink.build(base: base, code: code, addresses: addresses)
    }
    let presenter = HeadlessSessionPresenter(core: host.coreContext)
    presenter.peerConsoleHost = shells.makePeerConsoleHost()
    server.presenter = presenter
    openSessions = presenter
    // The port can change after the first: a listener that fails rebinds on
    // an OS-assigned one, and the address and the proxy follow it.
    var servedPort: UInt16?
    server.onPortChange = { port in
        // Held only while the server is bound and the Mac is on external power.
        keepAwake.update(enabled: settings.keepAwake, serverRunning: port != nil)
        // Codes only while `/pair` is there to redeem them.
        protocolServer.remotePairing = port == nil ? nil : pairing
        guard let port, port != servedPort else { return }
        servedPort = port
        print("remote http://127.0.0.1:\(port)")
        fflush(stdout)
        tailscaleServe?.stop()
        tailscaleServe = nil
        tailnetHTTPSHost = nil
        Task { @MainActor in
            // The proxy's requests name the tailnet host, which the policy
            // must allow; a status that cannot be read leaves loopback only.
            guard let status = try? await RemoteTailscale.status(), servedPort == port else { return }
            server.updateAccessPolicy(settings.accessPolicy(interfaces: interfaces, tailnetDNSName: status.dnsName))
            server.updateOriginPolicy(settings.originPolicy(interfaces: interfaces, tailnetDNSName: status.dnsName))
            guard listen.tailscaleServe, status.httpsEnabled, !isStopping,
                  let executable = RemoteTailscale.executable() else { return }
            do {
                tailscaleServe = try RemoteTailscaleServeProcess(executable: executable, port: port) { reason in
                    FileHandle.standardError.write(Data("alas-host: tailscale serve stopped: \(reason)\n".utf8))
                }
                tailnetHTTPSHost = status.dnsName
                print("remote https://\(status.dnsName)")
                fflush(stdout)
            } catch {
                FileHandle.standardError.write(Data("alas-host: cannot run tailscale serve: \(error.localizedDescription)\n".utf8))
            }
        }
    }
    remote = server
    startRemote = {
        // A client's socket reads the open sessions from its first message,
        // and `restore()` replaces them once it finishes: serve only after.
        await presenter.restore()
        guard !isStopping else { return }
        do {
            try server.start(port: listen.port, loopbackOnly: listen.loopbackOnly)
        } catch {
            fail("cannot serve Remote: \(error.localizedDescription)")
        }
    }
}

// Projects added before the host started, by the app or `project add`, have
// worktrees only once they are listed; the app lists them at launch too.
// The shepherds start after, since they leave records of unlisted worktrees.
// Remote follows: restoring the open sessions keeps those of listed
// worktrees only. Stored sessions load last, so they do not hold up Remote.
Task {
    // Before Remote lists them.
    await shells.restore()
    await host.loadProjectWorktrees()
    // Off Remote's path: probing gg can take a while, and Remote doesn't need it.
    Task { await host.startAutomation() }
    await startRemote?()
    await host.coreContext.loadStoredSessionManagers()
}

// Installed before the path is printed, so a stop sent as soon as the host
// announces itself still ends its work. Delivered on the main queue, where
// the host's main actor runs.
@MainActor
func stop() {
    guard !isStopping else { return }
    isStopping = true
    // No request, on an open connection either, starts work teardown would miss.
    protocolServer.close()
    socket.stop()
    tailscaleServe?.stop()
    openSessions?.peerConsoleHost?.shutdown()
    remote?.stop()
    keepAwake.update(enabled: false, serverRunning: false)
    Task { @MainActor in
        await host.shutdown()
        withExtendedLifetime(lock) {}
        exit(0)
    }
}
var stopSources: [any DispatchSourceProtocol] = []
for signalNumber in [SIGINT, SIGTERM] {
    signal(signalNumber, SIG_IGN)
    let source = DispatchSource.makeSignalSource(signal: signalNumber, queue: .main)
    source.setEventHandler { MainActor.assumeIsolated { stop() } }
    source.resume()
    stopSources.append(source)
}
if executableFD >= 0 {
    let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: executableFD, eventMask: [.delete, .rename, .revoke], queue: .main)
    source.setEventHandler { MainActor.assumeIsolated { stop() } }
    source.resume()
    stopSources.append(source)
    // Replaced between the check after the lock and now.
    if executableWasReplaced() { stop() }
}

print(socket.path)
fflush(stdout)

// The main run loop, not `dispatchMain()`: keep-awake follows power-source
// changes through a run loop source. It serves the main queue too; the port
// keeps it running with no other source attached.
RunLoop.main.add(Port(), forMode: .default)
RunLoop.main.run()
fail("the main run loop stopped")
