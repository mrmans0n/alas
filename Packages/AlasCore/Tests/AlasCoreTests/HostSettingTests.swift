import Foundation
import AlasAgentKit
import AlasHostCore
import AlasModel
import Testing

struct HostSettingTests {
    @Test(arguments: [
        ("host.reachability", "lan", "lan"),
        ("host.port", "18765", "18765"),
        ("harness.acpAutoResumeAfterUsageLimit", "off", "false"),
        ("worktrees.baseBranch", "dev", "dev"),
    ])
    func setsAndReadsEachKey(key: String, input: String, printed: String) throws {
        var config = AppConfig.defaults
        let setting = try HostSettingCatalog.named(key, in: config)
        try setting.set(input, in: &config)
        #expect(setting.value(in: config) == printed)
    }

    @Test(arguments: [
        ("host.port", "70000"), ("host.port", "0"), ("harness.acpAutoRunByDefault", "maybe"),
        ("host.reachability", "wan"), ("agents.nope.enabled", "true"), ("theme", "dark"),
    ])
    func rejectsInvalidValues(key: String, value: String) {
        var config = AppConfig.defaults
        let original = config
        #expect(throws: HostSettingError.self) {
            try HostSettingCatalog.named(key, in: config).set(value, in: &config)
        }
        #expect(config == original)
    }

    @Test func listsOneEnabledSettingPerAgent() throws {
        var config = AppConfig.defaults
        config.agents.registry = [ACPRegistryInstalledAgent(
            registryID: "zed", displayName: "Zed", version: "1", command: "x", arguments: [], environment: [:], isEnabled: true
        )]
        let keys = Set(HostSettingCatalog.all(for: config).map(\.key))
        for agent in AgentBuiltins.catalog { #expect(keys.contains("agents.\(agent.id).enabled")) }
        #expect(keys.contains("agents.zed.enabled"))

        let builtin = AgentBuiltins.catalog[0].id
        try HostSettingCatalog.named("agents.\(builtin).enabled", in: config).set("off", in: &config)
        #expect(config.agents.builtinState[builtin]?.isEnabled == false)
        try HostSettingCatalog.named("agents.zed.enabled", in: config).set("no", in: &config)
        #expect(config.agents.registry[0].isEnabled == false)
    }

    // MARK: - Setup model

    /// Drives `model` with `keys`, returning the last effect.
    @discardableResult
    private func press(_ keys: [HostSetupKey], on model: inout HostSetupModel) -> HostSetupEffect? {
        var effect: HostSetupEffect?
        for key in keys { effect = model.handle(key) }
        return effect
    }

    /// Opens the main menu's `item`.
    @discardableResult
    private func open(_ item: HostSetupMenuItem, on model: inout HostSetupModel) -> HostSetupEffect? {
        let index = HostSetupMenuItem.allCases.firstIndex(of: item)!
        return press(Array(repeating: .down, count: index) + [.enter], on: &model)
    }

    @Test func togglingABoolMarksTheConfigDirty() {
        var model = HostSetupModel(config: .defaults, projects: [])
        let before = AppConfig.defaults.harness.acpAutoResumeAfterUsageLimit
        open(.behavior, on: &model)
        press([.down, .enter], on: &model)
        #expect(model.changedConfig.harness.acpAutoResumeAfterUsageLimit == !before)
        #expect(model.isDirty)
    }

    @Test func editingTextIsCancelledByEscape() {
        var model = HostSetupModel(config: .defaults, projects: [])
        let clear = Array(repeating: HostSetupKey.backspace, count: AppConfig.defaults.worktrees.baseBranch.count)
        let typeDev: [HostSetupKey] = [.down, .enter] + clear + "dev".map { .character($0) }
        open(.worktrees, on: &model)
        press(typeDev + [.escape], on: &model)
        #expect(model.changedConfig.worktrees.baseBranch == AppConfig.defaults.worktrees.baseBranch)
        #expect(!model.isDirty)

        press([.up] + typeDev + [.enter], on: &model)
        #expect(model.changedConfig.worktrees.baseBranch == "dev")
        #expect(model.isDirty)
    }

    @Test func choosingLANNeedsAnExplicitPick() {
        var upgraded = AppConfig.defaults
        upgraded.remote.enabled = true
        var model = HostSetupModel(config: upgraded, projects: [])
        open(.reachability, on: &model)
        #expect(model.changedConfig.hostReachability == .loopback)
        press([.down, .down, .up, .up, .tab, .escape], on: &model)
        #expect(model.changedConfig.hostReachability == .loopback)
        #expect(!model.isDirty)

        // Reopen the section, then pick on the reachability row: LAN is the last stop.
        press([.enter, .enter], on: &model)
        #expect(model.changedConfig.hostReachability == .tailscale)
        press([.enter], on: &model)
        #expect(model.changedConfig.hostReachability == .lan)
    }

    @Test func saveEffectOnlyWhenDirty() {
        var clean = HostSetupModel(config: .defaults, projects: [])
        #expect(open(.save, on: &clean) == .quit)

        var dirty = HostSetupModel(config: .defaults, projects: [])
        open(.behavior, on: &dirty)
        press([.enter, .escape], on: &dirty)
        #expect(press(Array(repeating: .down, count: HostSetupMenuItem.allCases.count) + [.enter], on: &dirty) == .save)
    }

    @Test func removingAProjectAsksFirst() throws {
        let project = try JSONDecoder().decode(ProjectSnapshot.self, from: Data("""
        {"id": "p1", "name": "repo", "path": "/tmp/repo", "kind": "git", "addedAt": 0}
        """.utf8))
        var model = HostSetupModel(config: .defaults, projects: [project])
        open(.projects, on: &model)
        #expect(press([.up, .enter], on: &model) == nil)
        #expect(press([.escape, .enter], on: &model) == nil)
        #expect(press([.enter], on: &model) == .removeProject("p1"))
    }

    @Test func marksAnEnabledAgentWhoseAdapterIsMissing() {
        let agent = AgentBuiltins.catalog[0].id
        var model = HostSetupModel(config: .defaults, projects: [], missingCommands: [agent: "missing-acp"])
        open(.agents, on: &model)
        #expect(model.view.rows[0].hasSuffix("true - `missing-acp` not found on PATH"))
        press([.enter], on: &model)
        #expect(!model.view.rows[0].contains("not found"))
    }

    /// Missing adapters are keyed by the id in the agent's setting key, so a
    /// registry agent's entry is found under its registry id.
    @Test func missingAdapterCommandsUseTheSettingID() {
        var config = AppConfig.defaults
        config.agents.registry = [ACPRegistryInstalledAgent(
            registryID: "acme", displayName: "Acme", version: "1", command: "acme-acp",
            arguments: [], environment: [:], isEnabled: true
        )]
        let missing = HostSetupModel.missingAdapterCommands(config) { $0 != "acme-acp" }
        #expect(missing == ["acme": "acme-acp"])
        #expect(HostSettingCatalog.all(for: config).contains { $0.key == "agents.acme.enabled" })
    }

    /// The rows a terminal of `height` lines shows: all of them when they
    /// fit, otherwise a window that keeps the selection on screen.
    @Test(arguments: [
        (5, 0, 10, 0 ..< 5),
        (50, 0, 10, 0 ..< 10),
        (50, 20, 10, 15 ..< 25),
        (50, 49, 10, 40 ..< 50),
        (50, 3, 0, 3 ..< 4),
    ] as [(Int, Int, Int, Range<Int>)])
    func aViewportKeepsTheSelectionVisible(count: Int, selected: Int, height: Int, expected: Range<Int>) {
        #expect(HostSetupViewport.visibleRows(count: count, selected: selected, height: height) == expected)
    }

    @Test(arguments: [
        ("enabled", 20, "enabled"),
        ("agents.registry-agent.enabled = true", 12, "agents.regi…"),
        ("abc", 1, "…"),
    ])
    func aRowIsCutToTheTerminalWidth(row: String, width: Int, expected: String) {
        #expect(HostSetupViewport.fit(row, width: width) == expected)
    }
}
