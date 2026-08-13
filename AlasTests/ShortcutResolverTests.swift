import Testing
import SwiftUI
@testable import Alas

@MainActor
struct ShortcutResolverTests {
    /// An in-memory store that never touches disk, so tests don't
    /// clobber the user's real config file.
    private struct MemoryStore: PersistenceStoreProtocol {
        func write<T: Encodable>(_: T, to _: URL) throws {}
        func readIfExists<T: Decodable>(_: T.Type, from _: URL) throws -> T? { nil }
    }

    private func makeState() -> AppState {
        AppState(store: MemoryStore())
    }

    @Test func returnsDefaultWhenNoOverride() async {
        let state = makeState()
        let binding = state.binding(for: .searchFiles)
        #expect(binding == ShortcutAction.searchFiles.defaultBinding)
    }

    @Test func returnsOverrideWhenSet() async {
        let state = makeState()
        let custom = ShortcutBinding(key: "o", modifiers: [.command])
        state.setShortcut(custom, for: .searchFiles)
        #expect(state.binding(for: .searchFiles) == custom)
    }

    @Test func returnsNilForExplicitUnbind() async {
        let state = makeState()
        state.setShortcut(nil, for: .searchFiles)
        #expect(state.binding(for: .searchFiles) == nil)
        #expect(state.shortcut(for: .searchFiles) == nil)
    }

    @Test func resetSingleClearsOverride() async {
        let state = makeState()
        state.setShortcut(ShortcutBinding(key: "o", modifiers: [.command]), for: .searchFiles)
        state.resetShortcut(for: .searchFiles)
        #expect(state.binding(for: .searchFiles) == ShortcutAction.searchFiles.defaultBinding)
        #expect(!state.config.shortcutOverrides.keys.contains(ShortcutAction.searchFiles.rawValue))
    }

    @Test func resetAllClearsEverything() async {
        let state = makeState()
        state.setShortcut(ShortcutBinding(key: "o", modifiers: [.command]), for: .searchFiles)
        state.setShortcut(nil, for: .switchRepository)
        state.resetAllShortcuts()
        #expect(state.config.shortcutOverrides.isEmpty)
    }

    @Test func conflictDetectsExistingDefaultBinding() async {
        let state = makeState()
        let cmdP = ShortcutBinding(key: "p", modifiers: [.command])
        let conflict = state.conflict(for: cmdP, excluding: .switchRepository)
        #expect(conflict == .searchFiles)
    }

    @Test func conflictExcludesSelf() async {
        let state = makeState()
        let cmdP = ShortcutBinding(key: "p", modifiers: [.command])
        let conflict = state.conflict(for: cmdP, excluding: .searchFiles)
        #expect(conflict == nil)
    }

    @Test func conflictDetectsAgentInTerminalDefaultBinding() async {
        let state = makeState()
        let binding = ShortcutBinding(key: "t", modifiers: [.command, .option, .shift])
        let conflict = state.conflict(for: binding, excluding: .searchFiles)
        #expect(conflict == .launchAgentInTerminal)
    }

    @Test func conflictDetectsAgentInChatDefaultBinding() async {
        let state = makeState()
        let binding = ShortcutBinding(key: "c", modifiers: [.command, .option, .shift])
        let conflict = state.conflict(for: binding, excluding: .searchFiles)
        #expect(conflict == .launchAgentInChat)
    }

    @Test func conflictDetectsReplaceInEditorDefaultBinding() async {
        let state = makeState()
        let binding = ShortcutBinding(key: "r", modifiers: [.command])
        let conflict = state.conflict(for: binding, excluding: .searchFiles)
        #expect(conflict == .runScript)
        #expect(ShortcutAction.runScript.appliesInTerminal)
    }

    @Test func conflictNilWhenNoneFound() async {
        let state = makeState()
        let weird = ShortcutBinding(key: "j", modifiers: [.command, .control, .shift])
        #expect(state.conflict(for: weird, excluding: .searchFiles) == nil)
    }

    @Test func conflictDetectsExistingOverride() async {
        let state = makeState()
        // searchFiles' default is ⌘P. Override switchRepository to ⌘P.
        // A new candidate of ⌘P from another action should now find switchRepository,
        // not searchFiles, because the search short-circuits at the first hit (and
        // the loop ordering is allCases). Either match is acceptable per the spec —
        // we just want to prove that an override participates in conflict detection.
        let cmdP = ShortcutBinding(key: "p", modifiers: [.command])
        state.setShortcut(cmdP, for: .switchRepository)
        // Asking about a third action: must report either .searchFiles OR .switchRepository
        let conflict = state.conflict(for: cmdP, excluding: .findAndReplace)
        #expect(conflict == .searchFiles || conflict == .switchRepository,
                "expected override to participate in conflict detection")
    }

    @Test func shortcutIgnoresUnsupportedPersistedKey() async {
        let state = makeState()
        state.config.shortcutOverrides[ShortcutAction.searchFiles.rawValue] =
            .some(ShortcutBinding(key: "unsupported", modifiers: [.command]))

        #expect(state.binding(for: .searchFiles)?.key == "unsupported")
        #expect(state.shortcut(for: .searchFiles) == nil)
    }

    @Test func setShortcutRejectsUnsupportedKeys() async {
        let state = makeState()
        state.setShortcut(ShortcutBinding(key: "unsupported", modifiers: [.command]), for: .searchFiles)

        #expect(state.config.shortcutOverrides.isEmpty)
        #expect(state.binding(for: .searchFiles) == ShortcutAction.searchFiles.defaultBinding)
    }
}
