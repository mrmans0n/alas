import AlasCore
import Foundation

// Serves the host protocol for one data directory, without the app: the
// profile's directory (`ALAS_APP_SUPPORT_DIR`, else the everyday one), on
// the profile's local socket.

let usage = """
usage: alas-host [--wait-for-lock]
       alas-host pair
       alas-host install-agent | uninstall-agent

Serves the Alas host protocol for the data directory ALAS_APP_SUPPORT_DIR
(default: ~/Library/Application Support/Alas) on its local socket, and prints
the socket path. When the profile enables Remote, also serves it on loopback
and prints its address, with the web client of the Alas.app it ships in, of
the one in /Applications, or of ALAS_REMOTE_WEB_DIR. Stops on SIGINT or SIGTERM.

With --wait-for-lock, waits while another process (the app) holds the data
directory instead of exiting, and serves once it lets go.

`alas-host pair` asks the running host for a Remote pairing code, which a
phone or browser redeems within two minutes, and prints it.

`alas-host install-agent` installs and starts a launchd agent that runs this
executable with --wait-for-lock at login, and restarts it after a crash;
`uninstall-agent` stops and removes it. Each profile has its own agent.
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
    case .remotePairingCode(let code, let expiresAt):
        print(code)
        FileHandle.standardError.write(Data("Valid until \(expiresAt.formatted(date: .omitted, time: .standard)).\n".utf8))
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
if arguments == ["install-agent"] || arguments == ["uninstall-agent"] {
    // The bundled executable, not the link that may have started this one,
    // so the agent keeps working wherever the link points.
    guard let executable = Bundle.main.executableURL?.resolvingSymlinksInPath() else {
        fail("cannot locate this executable")
    }
    let agent = HostLaunchAgent(executable: executable)
    let domain = "gui/\(getuid())"
    @discardableResult
    func launchctl(_ arguments: String...) -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return -1 }
        process.waitUntilExit()
        return process.terminationStatus
    }
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

// Held until the process exits; the kernel releases it then.
let lock: DataDirectoryLock
do {
    lock = try DataDirectoryLock.acquire(waiting: waitsForLock)
} catch {
    fail(error.localizedDescription)
}

let host: AlasHost
do {
    host = try AlasHost.boot()
} catch {
    fail("cannot load \(Paths.appSupportRoot.path): \(error.localizedDescription)")
}

let protocolServer = HostProtocolServer(host: host)
guard let socket = HostSocketServer(server: protocolServer) else {
    fail("cannot serve \(HostSocketServer.defaultPath()): another host serves it, or its directory is not this user's own")
}

// One shutdown: a second signal must not exit while the first still flushes.
var isStopping = false

// Remote, when the profile enables it: loopback only, since a bare executable
// has no local-network permission, reached from other devices through the
// `tailscale serve` proxy run here, as the app runs it, or a tunnel. No peer
// identity, federation or Bonjour: only another Mac asks for an identity
// proof, and a headless host pairs with codes.
var remote: RemoteServer?
var tailscaleServe: RemoteTailscaleServeProcess?
let keepAwake = RemoteKeepAwakeController()
var config = (try? PersistenceStore().readIfExists(AppConfig.self, from: Paths.appConfigFile)) ?? .defaults
if config.remote.enabled {
    if config.remote.ensureServerId() {
        do {
            try PersistenceStore().write(config, to: Paths.appConfigFile)
        } catch {
            fail("cannot save \(Paths.appConfigFile.path): \(error.localizedDescription)")
        }
    }
    let settings = config.remote
    let pairing = RemotePairingService(store: FileDeviceStore())
    let interfaces = RemoteNetwork.interfaces()
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
                addresses: settings.advertisedAddresses(port: port, interfaces: interfaces, tailnetHTTPSHost: nil),
                usesPlainHTTP: true,
                pairedDeviceCount: pairing.devices.count,
                serverId: settings.serverId,
                name: settings.resolvedDisplayName
            )
        },
        identity: { RemoteServerIdentity(serverId: settings.serverId, name: settings.resolvedDisplayName) }
    )
    // The port can change after the first: a listener that fails rebinds on
    // an OS-assigned one, and the address and the proxy follow it.
    server.admitsPeers = false
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
        Task { @MainActor in
            // The proxy's requests name the tailnet host, which the policy
            // must allow; a status that cannot be read leaves loopback only.
            guard let status = try? await RemoteTailscale.status(), servedPort == port else { return }
            server.updateAccessPolicy(settings.accessPolicy(interfaces: interfaces, tailnetDNSName: status.dnsName))
            server.updateOriginPolicy(settings.originPolicy(interfaces: interfaces, tailnetDNSName: status.dnsName))
            guard settings.tailscaleServe, status.httpsEnabled, !isStopping,
                  let executable = RemoteTailscale.executable() else { return }
            do {
                tailscaleServe = try RemoteTailscaleServeProcess(executable: executable, port: port) { reason in
                    FileHandle.standardError.write(Data("alas-host: tailscale serve stopped: \(reason)\n".utf8))
                }
                print("remote https://\(status.dnsName)")
                fflush(stdout)
            } catch {
                FileHandle.standardError.write(Data("alas-host: cannot run tailscale serve: \(error.localizedDescription)\n".utf8))
            }
        }
    }
    do {
        try server.start(port: settings.preferredPort, loopbackOnly: true)
    } catch {
        fail("cannot serve Remote: \(error.localizedDescription)")
    }
    remote = server
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
// As the launch agent, an app upgrade replaces this executable under the
// running host: it stops, and launchd starts the new one at the same path.
if waitsForLock, let executable = Bundle.main.executableURL?.resolvingSymlinksInPath() {
    let fd = open(executable.path, O_EVTONLY)
    if fd >= 0 {
        let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: [.delete, .rename, .revoke], queue: .main)
        source.setEventHandler { MainActor.assumeIsolated { stop() } }
        source.setCancelHandler { close(fd) }
        source.resume()
        stopSources.append(source)
    }
}

print(socket.path)
fflush(stdout)

// The main run loop, not `dispatchMain()`: keep-awake follows power-source
// changes through a run loop source. It serves the main queue too; the port
// keeps it running with no other source attached.
RunLoop.main.add(Port(), forMode: .default)
RunLoop.main.run()
fail("the main run loop stopped")
