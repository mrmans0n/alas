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
}
