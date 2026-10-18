import AlasCore
import Foundation

// Serves the host protocol for one data directory, without the app: the
// profile's directory (`ALAS_APP_SUPPORT_DIR`, else the everyday one), on
// the profile's local socket.

let usage = """
usage: alas-host

Serves the Alas host protocol for the data directory ALAS_APP_SUPPORT_DIR
(default: ~/Library/Application Support/Alas) on its local socket, and prints
the socket path. When the profile enables Remote, also serves it on loopback
and prints its address, with the web client of the installed Alas.app or of
ALAS_REMOTE_WEB_DIR. Stops on SIGINT or SIGTERM.
"""

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("alas-host: \(message)\n".utf8))
    exit(1)
}

if CommandLine.arguments.dropFirst().contains(where: { $0 == "--help" || $0 == "-h" }) {
    print(usage)
    exit(0)
}
if let unknown = CommandLine.arguments.dropFirst().first {
    fail("unknown argument \(unknown)\n\(usage)")
}

// Held until the process exits; the kernel releases it then.
let lock: DataDirectoryLock
do {
    lock = try DataDirectoryLock.acquire()
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
    // The web client ships inside the app; without it, devices that already
    // have a client still pair and connect.
    let webClient = [
        ProcessInfo.processInfo.environment["ALAS_REMOTE_WEB_DIR"].map { URL(fileURLWithPath: $0) },
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
    var servedPort: UInt16?
    server.onPortChange = { port in
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
var stopSignals: [DispatchSourceSignal] = []
for signalNumber in [SIGINT, SIGTERM] {
    signal(signalNumber, SIG_IGN)
    let source = DispatchSource.makeSignalSource(signal: signalNumber, queue: .main)
    source.setEventHandler {
        MainActor.assumeIsolated {
            guard !isStopping else { return }
            isStopping = true
            // No request, on an open connection either, starts work teardown would miss.
            protocolServer.close()
            socket.stop()
            tailscaleServe?.stop()
            remote?.stop()
            Task { @MainActor in
                await host.shutdown()
                withExtendedLifetime(lock) {}
                exit(0)
            }
        }
    }
    source.resume()
    stopSignals.append(source)
}

print(socket.path)
fflush(stdout)

dispatchMain()
