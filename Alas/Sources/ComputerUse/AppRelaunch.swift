import AlasCore
import AppKit

/// Quits Alas and opens a fresh copy, for permissions macOS only applies at
/// launch (Screen Recording).
@MainActor
enum AppRelaunch {
    /// Set once the user goes to grant Screen Recording, for the rest of
    /// this process's life: macOS applies the grant only at launch.
    static var screenRecordingRequested = false

    static var appName: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String ?? "Alas"
    }

    /// The new copy opens only after this process exits, because a second
    /// copy would find the data directory locked and quit. An isolated
    /// profile's data directory is passed on; LaunchServices would drop it.
    /// If this process is still running after a minute (the user cancelled
    /// the quit), the relaunch is abandoned.
    static func relaunch() {
        var openArguments = ["-n"]
        if let profile = ProcessInfo.processInfo.environment[AlasProfile.environmentKey] {
            openArguments += ["--env", "\(AlasProfile.environmentKey)=\(profile)"]
        }
        openArguments.append(Bundle.main.bundlePath)

        let waiter = Process()
        waiter.executableURL = URL(fileURLWithPath: "/bin/sh")
        waiter.arguments = [
            "-c",
            """
            pid="$1"; shift; tries=0
            while kill -0 "$pid" 2>/dev/null; do
              tries=$((tries + 1)); [ "$tries" -gt 300 ] && exit 0
              sleep 0.2
            done
            exec /usr/bin/open "$@"
            """,
            "sh", String(ProcessInfo.processInfo.processIdentifier),
        ] + openArguments
        do {
            try waiter.run()
        } catch {
            NSSound.beep()
            return
        }
        NSApp.terminate(nil)
    }
}
