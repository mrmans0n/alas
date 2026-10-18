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

guard let socket = HostSocketServer(server: HostProtocolServer(host: host)) else {
    fail("cannot serve \(HostSocketServer.defaultPath()): another host serves it, or its directory is not this user's own")
}
print(socket.path)
fflush(stdout)

// Delivered on the main queue, so they run with the host's main actor.
var stopSignals: [DispatchSourceSignal] = []
for signalNumber in [SIGINT, SIGTERM] {
    signal(signalNumber, SIG_IGN)
    let source = DispatchSource.makeSignalSource(signal: signalNumber, queue: .main)
    source.setEventHandler {
        MainActor.assumeIsolated {
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

dispatchMain()
