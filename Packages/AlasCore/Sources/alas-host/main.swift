import AlasCore
import Foundation

// Serves the host protocol for one data directory, without the app: the
// profile's directory (`ALAS_APP_SUPPORT_DIR`, else the everyday one), on
// the profile's local socket.

let usage = """
usage: alas-host

Serves the Alas host protocol for the data directory ALAS_APP_SUPPORT_DIR
(default: ~/Library/Application Support/Alas) on its local socket, and prints
the socket path. Stops on SIGINT or SIGTERM.
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

// Installed before the path is printed, so a stop sent as soon as the host
// announces itself still ends its work. Delivered on the main queue, where
// the host's main actor runs.
var stopSignals: [DispatchSourceSignal] = []
// One shutdown: a second signal must not exit while the first still flushes.
var isStopping = false
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
