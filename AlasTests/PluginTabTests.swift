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
        var hasFrame = true
        let expected: PluginTabContent
    }

    @Test(arguments: [
        ContentCase(expected: .canvas),
        ContentCase(pluginsOn: false, expected: .unavailable),
        ContentCase(found: false, hostState: nil, expected: .unavailable),
        ContentCase(approved: false, hostState: nil, expected: .unavailable),
        ContentCase(enabled: false, hostState: nil, expected: .unavailable),
        ContentCase(hostState: .failed("trap"), expected: .stopped("trap")),
        ContentCase(hostState: .activating, hasFrame: false, expected: .loading),
        ContentCase(hasFrame: false, expected: .loading),
        ContentCase(hostState: nil, hasFrame: false, expected: .loading),
    ])
    func placeholderFollowsPluginAndHostState(_ c: ContentCase) {
        #expect(PluginTabContent.resolve(
            pluginsOn: c.pluginsOn, found: c.found, approved: c.approved, enabled: c.enabled,
            hostState: c.hostState, hasFrame: c.hasFrame) == c.expected)
    }

    @Test(arguments: [
        ("Fix login flow", nil as String?, "task/fix-login-flow"),
        ("  Añadir 🚀 soporte / para  X ", nil, "task/anadir-soporte-para-x"),
        ("..--..", nil, "task/task"),
        ("", nil, "task/task"),
        ("x", "feature/my-branch", "feature/my-branch"),
        ("x", "bad..name", "task/bad-name"),
        (String(repeating: "word ", count: 40), nil, "task/" + Array(repeating: "word", count: 40).joined(separator: "-").prefix(48).trimmingCharacters(in: CharacterSet(charactersIn: "-"))),
    ])
    func taskBranchNamesAreAlwaysValid(title: String, requested: String?, expected: String) {
        let name = PluginTaskBranch.name(title: title, requested: requested)
        #expect(name == expected)
        #expect(GitNameValidator.validateBranchName(name) == .valid)
    }
}
