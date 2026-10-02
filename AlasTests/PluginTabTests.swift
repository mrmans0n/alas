import CoreGraphics
import Foundation
import Testing
@testable import Alas

struct PluginTabTests {
    @Test(arguments: [
        (CGSize(width: 320, height: 180), CGSize(width: 1000, height: 600), 3),
        (CGSize(width: 320, height: 180), CGSize(width: 1000, height: 400), 2),
        (CGSize(width: 320, height: 180), CGSize(width: 200, height: 100), 1),
        (CGSize(width: 0, height: 0), CGSize(width: 200, height: 100), 1),
    ])
    func canvasScalesByTheLargestWholeFactorThatFits(frame: CGSize, view: CGSize, expected: Int) {
        #expect(PluginCanvasLayout.scale(frame: frame, in: view) == expected)
    }

    struct ContentCase: Sendable {
        var pluginsOn = true, found = true, approved = true, enabled = true
        var hostState: PluginHostState? = .active
        var hasContent = true
        let expected: PluginTabContent
    }

    @Test(arguments: [
        ContentCase(expected: .content),
        ContentCase(pluginsOn: false, expected: .unavailable),
        ContentCase(found: false, hostState: nil, expected: .unavailable),
        ContentCase(approved: false, hostState: nil, expected: .unavailable),
        ContentCase(enabled: false, hostState: nil, expected: .unavailable),
        ContentCase(hostState: .failed("trap"), expected: .stopped("trap")),
        ContentCase(hostState: .activating, hasContent: false, expected: .loading),
        ContentCase(hasContent: false, expected: .loading),
        ContentCase(hostState: nil, hasContent: false, expected: .loading),
    ])
    func placeholderFollowsPluginAndHostState(_ c: ContentCase) {
        #expect(PluginTabContent.resolve(
            pluginsOn: c.pluginsOn, found: c.found, approved: c.approved, enabled: c.enabled,
            hostState: c.hostState, hasContent: c.hasContent) == c.expected)
    }

    @Test(arguments: [
        ("", nil as String?, "", ""),               // first render
        ("", "", "typing…", "typing…"),             // same value re-rendered: keep typing
        ("draft", "", "typing…", "draft"),          // plugin changed the value: take it
        ("draft", "draft", "draft edited", "draft edited"),
    ])
    func textFieldsOnlyTakeTheValueWhenThePluginChangesIt(incoming: String, previous: String?, current: String, expected: String) {
        #expect(PluginTextFieldSync.apply(incoming: incoming, previousIncoming: previous, current: current) == expected)
    }

    @Test(arguments: [
        ("short", 64, "short"),
        ("abcdef", 4, "abcd"),
        ("aé", 2, "a"),        // é is 2 bytes: never split a scalar
        ("a🚀b", 4, "a"),      // 🚀 is 4 bytes
        ("a🚀b", 5, "a🚀"),
        ("", 0, ""),
    ])
    func submittedTextIsCappedOnAScalarBoundary(text: String, maxBytes: Int, expected: String) {
        #expect(PluginTextFieldSync.capped(text, maxBytes: maxBytes) == expected)
    }

    @Test(arguments: [
        ("Fix login flow", nil as String?, "task/fix-login-flow"),
        ("  Añadir 🚀 soporte / para  X ", nil, "task/anadir-soporte-para-x"),
        ("..--..", nil, "task/task"),
        ("", nil, "task/task"),
        ("x", "feature/my-branch", "feature/my-branch"),
        ("x", "bad..name", "task/bad-name"),
        ("x", "HEAD", "task/head"),
        ("x", "head", "task/head"),
        (String(repeating: "word ", count: 40), nil, "task/" + Array(repeating: "word", count: 40).joined(separator: "-").prefix(48).trimmingCharacters(in: CharacterSet(charactersIn: "-"))),
    ])
    func taskBranchNamesAreAlwaysValid(title: String, requested: String?, expected: String) {
        let name = PluginTaskBranch.name(title: title, requested: requested)
        #expect(name == expected)
        #expect(GitNameValidator.validateBranchName(name) == .valid)
    }

    /// A selected panel survives only while its plugin has a host in the project; otherwise the pane shows its tab.
    @Test func rightPanePanelsComeFromHostedPluginsAndASelectionFallsBack() throws {
        func plugin(_ id: String, panels: String) throws -> PluginManifest {
            try PluginManifest.parse(Data(#"{"id":"\#(id)","name":"P","version":"1","api":5,"entry":"p.js","contributes":{"panels":\#(panels)}}"#.utf8))
        }
        let a = try plugin("io.x.a", panels: #"[{"id":"issues","title":"Issues","icon":"checklist"},{"id":"b","title":"B"}]"#)
        let b = try plugin("io.x.b", panels: #"[{"id":"issues","title":"Other"}]"#)
        let items = PluginPanelItem.items([(a, true), (b, false)])
        #expect(items.map(\.ref) == [PluginPanelRef(pluginID: "io.x.a", panelID: "issues"), PluginPanelRef(pluginID: "io.x.a", panelID: "b")])
        #expect(items.map(\.icon) == ["checklist", PluginPanelContribution.defaultIcon])
        #expect(PluginPanelItem.selected(PluginPanelRef(pluginID: "io.x.a", panelID: "b"), in: items)?.title == "B")
        #expect(PluginPanelItem.selected(PluginPanelRef(pluginID: "io.x.b", panelID: "issues"), in: items) == nil)
        #expect(PluginPanelItem.selected(nil, in: items) == nil)
    }
}
