extension HomebrewInstallController {
    /// The "Install gg…" and "Upgrade gg…" flows in Settings › Changes and the Inbox.
    public static func gg() -> HomebrewInstallController {
        HomebrewInstallController(formula: "mrmans0n/tap/gg-stack", tool: "gg") {
            await GGAvailability.shared.probe(force: true)
            return GGAvailability.shared.isInstalled
        }
    }
}
