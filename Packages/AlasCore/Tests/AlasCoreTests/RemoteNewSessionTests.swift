import AlasRemoteKit
import Foundation
import Testing

struct RemoteNewSessionTests {
    @Test func projectNamingDistinguishesOlderHostsFromAnEmptyPrefix() throws {
        let oldProject = Data(#"{"id":"p","name":"alas"}"#.utf8)
        let currentProject = Data(#"{"id":"p","name":"alas","branchNaming":{"prefix":""}}"#.utf8)
        let decoder = JSONDecoder()
        #expect(try decoder.decode(RemoteProjectOption.self, from: oldProject).branchNaming == nil)
        let naming = try #require(decoder.decode(RemoteProjectOption.self, from: currentProject).branchNaming)
        #expect(naming.compose(name: "mobile-picker") == "mobile-picker")
    }

    @Test func projectTemplateTakesPrecedenceAndCanBeTurnedOff() {
        let naming = RemoteWorktreeBranchNaming(prefix: "feature/", template: "mobile/{name}")
        #expect(naming.compose(name: "Fix Picker") == "mobile/fix-picker")
        #expect(naming.compose(name: "Fix-Picker", enabled: false) == "Fix-Picker")
    }

    @Test func turningOffHostNamingSurvivesTheCreateRequestWireFormat() throws {
        typealias Message = RemoteClientMessageOf<OpaqueHostMessage, OpaqueHostMessage>
        let request = Message.createWorktreeSession(
            projectId: "p", base: "main", branch: "b", agentId: "a", useBranchNaming: false)
        let encoder = JSONEncoder()
        let decoder = JSONDecoder()
        let encoded = try encoder.encode(request)
        #expect(try decoder.decode(Message.self, from: encoded) == request)
        let legacy = Data(#"{"type":"createWorktreeSession","projectId":"p","base":"main","branch":"b","agentId":"a"}"#.utf8)
        #expect(try decoder.decode(Message.self, from: legacy) == .createWorktreeSession(
            projectId: "p", base: "main", branch: "b", agentId: "a"))
    }

    @Test(arguments: [
        ("feature/x", true), ("a.b", true),
        ("", false), ("a b", false), ("/a", false), ("a/", false), ("a//b", false),
        ("-a", false), ("a/-b", true), (".a", false), ("a/.b", false), ("a/./b", false),
        ("a..b", false), ("a.lock", false), ("a.lock/b", false), ("a.", false), ("a./b", true),
        ("a@{b", false), ("@", false),
        ("a~b", false), ("a^b", false), ("a:b", false), ("a\\b", false),
        ("a?b", false), ("a*b", false), ("a[b", false), ("a\tb", false),
        (String(repeating: "a", count: 250), true), (String(repeating: "a", count: 251), false),
    ] as [(String, Bool)])
    func branchNamesFollowTheWebClientsRules(name: String, valid: Bool) {
        #expect(RemoteBranchName.validationMessage(name) == (valid ? nil : "Enter a valid branch name."))
    }

    @Test func agentsDropTheOnesUnavailableInTheProject() {
        let all = [
            RemoteAgentOption(id: "claude", name: "Claude", isDefault: true),
            RemoteAgentOption(id: "local", name: "Local", isDefault: false, unavailableProjectIds: ["ssh"]),
        ]
        #expect(RemoteNewSession.agents(all, projectId: "ssh").map(\.id) == ["claude"])
        #expect(RemoteNewSession.agents(all, projectId: "p").map(\.id) == ["claude", "local"])
        #expect(RemoteNewSession.agents(all, projectId: nil).map(\.id) == ["claude", "local"])
    }

    private func worktreeOption(_ id: String, projectId: String?, projectName: String = "alas") -> RemoteWorktreeOption {
        .init(id: id, projectName: projectName, worktreeName: id, branch: id, path: "/peer/\(id)",
              metricsAvailable: false, comparisonRef: nil, commitCount: 0, changedFileCount: 0,
              addedLines: 0, deletedLines: 0, conflictCount: 0, projectId: projectId)
    }

    @Test(arguments: [
        ("main", "main"),
        ("trunk", "dev"),   // a preferred base the peer does not list falls back to its first branch
    ] as [(String, String)])
    func aNewPeerWorktreePreselectsThePeersPreferredBase(preferred: String, expected: String) {
        let branches = RemoteNewSession.Branches.loaded(names: ["dev", "main"], preferredBase: preferred)
        #expect(RemoteNewSession.preselectedBase(in: branches) == expected)
    }

    @Test(arguments: [
        (true, ["w1"]),          // matches on projectId
        (false, ["w1", "w2"]),   // older peer without projectIds: falls back to project name
    ] as [(Bool, [String])])
    func newSessionWorktreesBelongToTheClickedRepo(optionsCarryProjectIds: Bool, expected: [String]) {
        let options = [
            worktreeOption("w1", projectId: optionsCarryProjectIds ? "p" : nil),
            worktreeOption("w2", projectId: optionsCarryProjectIds ? "q" : nil),
            worktreeOption("w3", projectId: optionsCarryProjectIds ? "r" : nil, projectName: "other"),
        ]
        #expect(RemoteNewSession.worktrees(options, projectId: "p", repoName: "alas").map(\.id) == expected)
    }

    @Test func aMachineCheckoutsWorktreesBelongToTheirLocalProject() {
        var remote = worktreeOption("w2", projectId: "p-mini")
        remote.linkedProjectId = "p"
        let options = [worktreeOption("w1", projectId: "p"), remote, worktreeOption("w3", projectId: "q")]
        #expect(RemoteNewSession.worktrees(options, projectId: "p", repoName: "alas").map(\.id) == ["w1", "w2"])
    }

    @Test func newSessionPreselectsTheSelectedWorktreeThenTheDefaultAgent() {
        let options = [worktreeOption("w1", projectId: "p"), worktreeOption("w2", projectId: "p")]
        #expect(RemoteNewSession.preselectedWorktreeId(in: options, selectedWorktreeId: "w2") == "w2")
        #expect(RemoteNewSession.preselectedWorktreeId(in: options, selectedWorktreeId: "elsewhere") == "w1")
        let agents: [RemoteAgentOption] = [.init(id: "codex", name: "Codex", isDefault: false),
                                           .init(id: "claude", name: "Claude", isDefault: true)]
        #expect(RemoteNewSession.preselectedAgentId(in: agents) == "claude")
        #expect(RemoteNewSession.preselectedAgentId(in: Array(agents.prefix(1))) == "codex")
    }

    @Test(arguments: [
        (true, true, true, true, false),
        (true, false, true, false, false),
        (false, true, false, true, false),
        (false, false, false, false, true),  // nothing remembered: chips hidden, hint shown
    ] as [(Bool, Bool, Bool, Bool, Bool)])
    func newSessionShowsOnlyTheChipsThePeerRemembers(
        hasModels: Bool, hasEfforts: Bool, showsModel: Bool, showsEffort: Bool, showsHint: Bool
    ) throws {
        let agent = RemoteAgentOption(
            id: "claude", name: "Claude", isDefault: true,
            models: hasModels ? [RemoteModelOption(id: "opus", name: "Opus")] : nil,
            efforts: hasEfforts ? [RemoteEffortOption(id: "high", name: "High")] : nil)
        let visibility = try #require(RemoteNewSession.chipVisibility(for: agent))
        #expect(visibility.showsModel == showsModel)
        #expect(visibility.showsEffort == showsEffort)
        #expect(visibility.showsDefaultsHint == showsHint)
        #expect(RemoteNewSession.chipVisibility(for: nil) == nil)
    }
}
