import Testing
import Foundation
@testable import Alas

struct EditorTabStateMarkdownCodableTests {
    @Test func decodesLegacyStateWithoutMarkdownFields() throws {
        // A persisted EditorTabState from before this feature shipped:
        // no markdownViewMode, no markdownSplitFraction.
        let json = """
        {
          "id": "t1",
          "title": "README.md",
          "relativePath": "README.md"
        }
        """
        let state = try JSONDecoder().decode(EditorTabState.self, from: Data(json.utf8))
        #expect(state.id == "t1")
        #expect(state.markdownViewMode == nil)
        #expect(state.markdownSplitFraction == nil)
    }

    @Test func roundTripsWithEachMode() throws {
        for mode in MarkdownViewMode.allCases {
            var state = EditorTabState(id: "t", title: "f.md", relativePath: "f.md")
            state.markdownViewMode = mode
            state.markdownSplitFraction = 0.42
            let data = try JSONEncoder().encode(state)
            let decoded = try JSONDecoder().decode(EditorTabState.self, from: data)
            #expect(decoded.markdownViewMode == mode)
            #expect(decoded.markdownSplitFraction == 0.42)
        }
    }

    @Test func tabCodableRoundTripPreservesMarkdownFields() throws {
        var state = EditorTabState(id: "t", title: "x.md", relativePath: "x.md")
        state.markdownViewMode = .split
        state.markdownSplitFraction = 0.6
        let tab = Tab.editor(state)
        let data = try JSONEncoder().encode(tab)
        let decoded = try JSONDecoder().decode(Tab.self, from: data)
        if case .editor(let s) = decoded {
            #expect(s.markdownViewMode == .split)
            #expect(s.markdownSplitFraction == 0.6)
        } else {
            Issue.record("expected .editor case")
        }
    }
}
