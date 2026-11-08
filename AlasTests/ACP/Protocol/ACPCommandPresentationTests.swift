import Foundation
import Testing
@testable import Alas

@Suite("ACP command presentation")
struct ACPCommandPresentationTests {
    private static let planAction = """
    {"version":1,"action":{"kind":"setConfigOption","configId":"collaboration_mode","value":"plan","resetValue":"default","presentation":"state"}}
    """

    @Test("decodes the client-neutral record of an available command", arguments: [
        (#"{"version":1,"kind":"skill","skillPath":"/repo/.agents/skills/build/SKILL.md"}"#,
         ACPCommandPresentation(isSkill: true, skillPath: "/repo/.agents/skills/build/SKILL.md")),
        (#"{"version":1,"kind":"skill"}"#, ACPCommandPresentation(isSkill: true)),
        (#"{"version":1,"kind":"skill","skillPath":"skills/build/SKILL.md"}"#, ACPCommandPresentation(isSkill: true)),
        (planAction, ACPCommandPresentation(action: .setConfigOption(
            configId: "collaboration_mode", value: "plan", resetValue: "default"))),
        (#"{"version":1,"action":{"kind":"setConfigOption","configId":"mode","value":"plan"}}"#,
         ACPCommandPresentation(action: .setConfigOption(configId: "mode", value: "plan", resetValue: nil))),
        (#"{"version":1,"action":{"kind":"prefixPrompt","presentation":"state"}}"#,
         ACPCommandPresentation(action: .prefixPrompt)),
        (#"{"version":1,"action":{"kind":"setConfigOption","value":"plan"}}"#, nil),
        (#"{"version":1,"action":{"kind":"setConfigOption","configId":"mode","value":true}}"#, nil),
        (#"{"version":1,"action":{"kind":"runShell","command":"rm -rf /"}}"#, nil),
        (#"{"version":2,"kind":"skill","skillPath":"/SKILL.md"}"#, nil),
        (#"{"kind":"skill","skillPath":"/SKILL.md"}"#, nil),
        (#""skill""#, nil),
    ] as [(String, ACPCommandPresentation?)])
    func decodesRecord(record: String, expected: ACPCommandPresentation?) throws {
        let json = """
        {"sessionUpdate":"available_commands_update","availableCommands":[
          {"name":"build","description":"Build","_meta":{"commandPresentation":\(record)}}
        ]}
        """
        guard case .availableCommandsUpdate(let commands) = try JSONDecoder().decode(
            ACPSessionUpdate.self, from: Data(json.utf8)) else {
            Issue.record("expected availableCommandsUpdate")
            return
        }
        #expect(commands.map(\.command) == ["/build"])
        #expect(commands.first?.presentation == expected)
    }

    @Test("a command list stored before the record existed still decodes")
    func storedListWithoutRecord() throws {
        let stored = #"[{"command":"/review","description":"Review","hint":"<pr>"}]"#
        let commands = try JSONDecoder().decode([ACPPromptSuggestion].self, from: Data(stored.utf8))
        #expect(commands == [ACPPromptSuggestion(command: "/review", description: "Review", hint: "<pr>")])
    }

    private static func mode(current: String, values: [String] = ["default", "plan"], type: String = "select") -> [ACPConfigOption] {
        [ACPConfigOption(
            id: "collaboration_mode", name: "Mode", type: type, currentValue: current,
            options: values.map { ACPConfigOptionItem(id: $0, name: $0) })]
    }

    @Test("resolves a config action against the live config", arguments: [
        ("default", ["default", "plan"], "default" as String?, ACPCommandActionResolution.apply(configId: "collaboration_mode", value: "plan"), false as Bool?),
        ("plan", ["default", "plan"], "default", .apply(configId: "collaboration_mode", value: "default"), true),
        ("plan", ["default", "plan"], nil, .noop, true),
        ("plan", ["plan"], "default", .noop, true),
        ("default", ["default"], "default", .unsupported, nil),
    ] as [(String, [String], String?, ACPCommandActionResolution, Bool?)])
    func resolvesAction(current: String, values: [String], resetValue: String?, expected: ACPCommandActionResolution, isOn: Bool?) {
        let action = ACPCommandAction.setConfigOption(configId: "collaboration_mode", value: "plan", resetValue: resetValue)
        let options = Self.mode(current: current, values: values)
        #expect(action.resolve(in: options) == expected)
        #expect(action.isOn(in: options) == isOn)
    }

    @Test("an action without a usable live option stays the ordinary command")
    func unsupportedActions() {
        let plan = ACPCommandAction.setConfigOption(configId: "collaboration_mode", value: "plan", resetValue: "default")
        #expect(plan.resolve(in: []) == .unsupported)
        #expect(plan.resolve(in: Self.mode(current: "default", type: "boolean")) == .unsupported)
        #expect(ACPCommandAction.prefixPrompt.resolve(in: Self.mode(current: "default")) == .unsupported)
    }

    @Test("routes a skill file to its host and worktree", arguments: [
        ("/repo/.agents/skills/build/SKILL.md", "/repo", ACPSkillFileRoute.worktreeFile(relativePath: ".agents/skills/build/SKILL.md")),
        ("/Users/me/.codex/skills/build/SKILL.md", "/repo", .external(path: "/Users/me/.codex/skills/build/SKILL.md")),
        ("/repository/SKILL.md", "/repo", .external(path: "/repository/SKILL.md")),
        ("/home/me/repo/.claude/skills/x/SKILL.md", "/.alas-remote/box/home/me/repo",
         .worktreeFile(relativePath: ".claude/skills/x/SKILL.md")),
        ("/home/me/.codex/skills/x/SKILL.md", "/.alas-remote/box/home/me/repo",
         .external(path: "/.alas-remote/box/home/me/.codex/skills/x/SKILL.md")),
    ] as [(String, String, ACPSkillFileRoute)])
    func routesSkillFile(skillPath: String, worktreeRoot: String, expected: ACPSkillFileRoute) {
        #expect(ACPSkillFileRoute.route(skillPath: skillPath, worktreeRoot: worktreeRoot) == expected)
    }
}
