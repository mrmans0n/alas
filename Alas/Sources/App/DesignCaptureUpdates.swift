#if DEBUG
import Foundation

/// Design-capture targets for the update sheets and the What's New card. They
/// show scripted releases: nothing is checked, downloaded, installed or
/// relaunched, and the What's New "seen" version is never written. The
/// progress sheet runs the real `SelfUpdater` over a harmless `/bin/sh`
/// script instead of `brew`, which exits when the app does. Debug builds only.
@MainActor
enum DesignCaptureUpdates {
    static let targets: Set<String> = [
        "update-available", "update-available-brew", "update-available-nightly",
        "update-progress-refreshing", "update-progress-installing", "update-progress-installed",
        "update-progress-pending", "update-progress-failed", "update-progress-start-failed",
        "update-progress-cancelled", "whats-new",
    ]

    /// Another Debug instance also receives the distributed capture notification; only the one
    /// capture.sh launched on a demo profile may show demo releases.
    static func open(_ target: String, state: AppState) {
        let env = ProcessInfo.processInfo.environment
        guard env["ALAS_DESIGN_CAPTURE"] == "1", env["ALAS_APP_SUPPORT_DIR"] != nil else { return }
        Task { @MainActor in
            let deadline = Date().addingTimeInterval(30)
            while state.projects.isEmpty {
                guard Date() < deadline else { return }
                try? await Task.sleep(for: .milliseconds(200))
            }
            switch target {
            case "update-available":
                state.updates.installDemo(release: stable, source: .direct)
                state.updates.presentAvailableUpdate()
            case "update-available-brew":
                state.updates.installDemo(release: stable, source: .homebrew)
                state.updates.presentAvailableUpdate()
            case "update-available-nightly":
                state.updates.installDemo(release: nightly, source: .direct)
                state.updates.presentAvailableUpdate()
            case "whats-new":
                state.whatsNew.presented = whatsNewEntry
            default:
                await showProgress(target, state: state)
            }
        }
    }

    // MARK: - Progress

    /// Presents the sheet while the updater is idle, then runs the script: the sheet opens its
    /// log when a run flips to failed, and that only happens while it is on screen.
    private static func showProgress(_ target: String, state: AppState) async {
        let installed = target == "update-progress-installed"
        state.updates.installDemo(release: stable, source: .homebrew, installed: installed)
        state.presentUpdateProgress = true
        try? await Task.sleep(for: .milliseconds(800))
        switch target {
        case "update-progress-refreshing":
            await state.selfUpdater.runForTesting(steps: [
                step(title: "Refreshing Homebrew", script: "echo '==> Updating Homebrew...'; \(untilAppExits)"),
            ])
        case "update-progress-installing":
            await state.selfUpdater.runForTesting(steps: [
                step(title: "Downloading and installing", script: installLog + untilAppExits),
            ])
        case "update-progress-installed", "update-progress-pending":
            await state.selfUpdater.runForTesting(steps: [
                step(title: "Downloading and installing", script: installLog + "echo '==> Moving App to /Applications/Alas.app'"),
            ])
        case "update-progress-failed":
            await state.selfUpdater.runForTesting(steps: [
                step(title: "Downloading and installing", script: """
                    echo '==> Upgrading 1 outdated package:'
                    echo 'mrmans0n/tap/alas 0.23.3 -> 0.24.0'
                    echo '==> Downloading https://github.com/mrmans0n/alas/releases/download/v0.24.0/Alas-0.24.0.dmg'
                    echo 'Error: Download failed on Cask alas with message: Failed to connect to github.com port 443'
                    exit 1
                    """),
            ])
        case "update-progress-start-failed":
            await state.selfUpdater.runForTesting(steps: [
                SelfUpdateCommand.Step(executable: "/opt/homebrew/bin/brew-not-installed", arguments: ["update"], title: "Refreshing Homebrew"),
            ])
        default:
            // A step killed by a signal reads as cancelled.
            await state.selfUpdater.runForTesting(steps: [
                step(title: "Downloading and installing", script: "echo '==> Downloading Alas-0.24.0.dmg'; kill -INT $$"),
            ])
        }
    }

    /// Keeps a step "running" until the app is gone, so no process outlives the capture.
    private static let untilAppExits = "p=$PPID; while kill -0 $p 2>/dev/null; do sleep 1; done"

    private static let installLog = """
        echo '==> Upgrading 1 outdated package:'
        echo 'mrmans0n/tap/alas 0.23.3 -> 0.24.0'
        echo '==> Downloading https://github.com/mrmans0n/alas/releases/download/v0.24.0/Alas-0.24.0.dmg'
        echo '==> Verifying SHA-256 checksum for Cask alas'
        echo '==> Installing Cask alas'

        """

    private static func step(title: String, script: String) -> SelfUpdateCommand.Step {
        SelfUpdateCommand.Step(executable: "/bin/sh", arguments: ["-c", script], title: title)
    }

    // MARK: - Demo releases

    private static let stable = ReleaseInfo.stable(StableReleaseInfo(
        version: SemanticVersion(major: 0, minor: 24, patch: 0),
        releaseNotes: """
        ## Highlights

        - **Worktree VMs**: start a macOS or Linux VM for any worktree and let agents run commands inside it.
        - **Attention inbox**: one place for the permission requests and finished runs waiting on you.
        - **Faster diffs**: large diffs scroll at the display's refresh rate.

        ## Improvements

        - The composer can paste an image straight from the clipboard.
        - Plugin screens follow the interface density setting.
        - `alas wt list` prints the branch of each worktree.

        ## Fixes

        - Fixed a crash when closing a terminal while its agent was still streaming.
        - Fixed the sidebar showing a clean worktree as dirty after a rebase.
        - Fixed `Open in Editor` ignoring the configured line number.

        Full changelog: https://github.com/mrmans0n/alas/compare/v0.23.3...v0.24.0
        """,
        htmlURL: URL(string: "https://github.com/mrmans0n/alas/releases/tag/v0.24.0")!,
        dmgURL: URL(string: "https://github.com/mrmans0n/alas/releases/download/v0.24.0/Alas-0.24.0.dmg")
    ))

    private static let nightly = ReleaseInfo.nightly(NightlyReleaseInfo(
        shortSHA: "9f3c2ab",
        fullSHA: "9f3c2ab41d7e0c58a6b2f1e9d3c4a5b6c7d8e9f0",
        releaseNotes: """
        ## Changes since the last nightly

        - feat(acp): offer to paste a clipboard image from the composer
        - feat(plugins): move the plugin screens onto DesignScale
        - fix(sidebar): refresh dirty state after a rebase
        - chore(deps): update rust crate tree-sitter-scala to v0.26.10
        """,
        htmlURL: URL(string: "https://github.com/mrmans0n/alas/releases/tag/nightly")!,
        dmgURL: URL(string: "https://github.com/mrmans0n/alas/releases/download/nightly/Alas-nightly.dmg")
    ))

    /// The headline picture is a file the app already bundles, so nothing is fetched.
    private static let whatsNewEntry = WhatsNewEntry(
        version: SemanticVersion(major: 0, minor: 24, patch: 0),
        headline: WhatsNewHeadline(
            title: "Worktree VMs",
            body: "Set up macOS or Linux VMs for any worktree, then let agents start them, run commands, and use the desktop while you can take over anytime.",
            media: "media/0.23.0-worktree-vms.png",
            action: .openPluginSettings,
            actionLabel: "Open plugin settings"
        ),
        also: [WhatsNewAlso(title: "Set up hosts over SSH"), WhatsNewAlso(title: "Fork from earlier turns")]
    )
}
#endif
