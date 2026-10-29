import AlasComputerUseKit
import AlasCore
import AppKit
import Darwin
import os

// Alas VM Guest: runs in a worktree VM's logged-in session (a LaunchAgent) and performs the
// host's computer-use calls and `vm_run` commands there.

// A write to a connection the host dropped must fail with EPIPE, not end the helper.
signal(SIGPIPE, SIG_IGN)

MainActor.assumeIsolated {
    ComputerUsePlatform.shared = ComputerUseSystemPermissions.make()
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)
    let listener = VMGuestListener(service: VMGuestService.makeLive())
    do {
        try listener.start()
    } catch {
        Logger(subsystem: "io.nlopez.vmguest", category: "main")
            .fault("couldn't listen on vsock: \(error.localizedDescription, privacy: .public)")
        // launchd's KeepAlive starts it again.
        exit(1)
    }
    app.run()
}
