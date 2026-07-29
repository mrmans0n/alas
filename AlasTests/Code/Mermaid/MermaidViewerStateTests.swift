import CoreGraphics
import Testing
@testable import Alas

@MainActor
struct MermaidViewerStateTests {
    @Test(arguments: [
        MermaidRenderFailure.empty,
        .sourceTooLarge(actualBytes: 262_145),
        .unsupported("gantt"),
        .parseFailed("unexpected token"),
        .layoutFailed("cycle"),
        .renderFailed("image"),
        .rasterTooLarge(width: 8_193, height: 1),
    ])
    func failureAutomaticallyExposesExactSource(
        _ failure: MermaidRenderFailure
    ) {
        let source = "graph TD;\n  A-->B\n"
        var state = MermaidSourceDisclosureState()

        #expect(state.visibleSource(source) == nil)

        state.apply(.failed(failure))

        #expect(state.visibleSource(source) == source)

        state.toggle()

        #expect(state.visibleSource(source) == nil)
    }

    @Test("zoom clamps and resets")
    func zoomState() {
        var state = MermaidZoomState()
        state.zoom(by: 100)
        state.translate(by: CGSize(width: 24, height: -12))

        #expect(state.scale == MermaidZoomState.maximumScale)
        #expect(state.translation == CGSize(width: 24, height: -12))

        state.resetToFit()

        #expect(state.scale == 1)
        #expect(state.translation == .zero)
    }

    @Test("zoom clamps at minimum")
    func minimumZoom() {
        var state = MermaidZoomState()

        state.zoom(by: 0.001)

        #expect(state.scale == MermaidZoomState.minimumScale)
    }

    @Test("latest render key wins when an obsolete render completes last")
    func latestRenderKeyWins() {
        let obsoleteKey = TestMermaid.key(source: "graph TD; obsolete")
        let latestKey = TestMermaid.key(source: "graph TD; latest")
        var state = MermaidRenderRequestState()
        state.begin(obsoleteKey)
        state.begin(latestKey)
        state.apply(.failed(.unsupported("latest result")), for: latestKey)
        state.apply(.failed(.unsupported("obsolete result")), for: obsoleteKey)

        #expect(state.currentKey == latestKey)
        if case .failed(let failure) = state.outcome {
            #expect(failure == .unsupported("latest result"))
        } else {
            Issue.record("Expected the latest render failure to remain visible")
        }
    }

    @Test("viewer actions declare explicit keyboard shortcuts")
    func viewerKeyboardShortcuts() {
        #expect(
            MermaidViewerAction.zoomIn.shortcut
                == ShortcutBinding(key: "=", modifiers: [.command])
        )
        #expect(
            MermaidViewerAction.zoomOut.shortcut
                == ShortcutBinding(key: "-", modifiers: [.command])
        )
        #expect(
            MermaidViewerAction.resetToFit.shortcut
                == ShortcutBinding(key: "9", modifiers: [.command])
        )
        #expect(
            MermaidViewerAction.actualSize.shortcut
                == ShortcutBinding(key: "0", modifiers: [.command])
        )
        #expect(
            MermaidViewerAction.toggleSource.shortcut
                == ShortcutBinding(
                    key: "u",
                    modifiers: [.option, .command]
                )
        )
        #expect(
            MermaidViewerAction.copySource.shortcut
                == ShortcutBinding(
                    key: "c",
                    modifiers: [.option, .command]
                )
        )
    }

    @Test("viewer actions share one state transition contract")
    func viewerActionWiring() {
        var state = MermaidViewerInteractionState()
        state.translate(by: CGSize(width: 24, height: -12))

        let zoomEffect = state.perform(.zoomIn)

        #expect(zoomEffect == nil)
        #expect(state.scale == 1.25)
        #expect(state.translation == CGSize(width: 24, height: -12))

        _ = state.perform(.actualSize)

        #expect(state.scale == 1)
        #expect(state.translation == CGSize(width: 24, height: -12))

        _ = state.perform(.resetToFit)

        #expect(state.scale == 1)
        #expect(state.translation == .zero)

        _ = state.perform(.toggleSource)

        #expect(state.showsSource)
        #expect(state.perform(.copySource) == .copySource)
    }

    @Test("zoom accessibility exposes a named adjustable percentage")
    func zoomAccessibilityMetadataAndAdjustment() {
        var state = MermaidViewerInteractionState()

        state.adjustZoom(.increment)

        #expect(state.zoomAccessibilityMetadata.label == "Mermaid diagram zoom")
        #expect(state.zoomAccessibilityMetadata.value == "125%")

        state.adjustZoom(.decrement)

        #expect(state.scale == 1)
        #expect(state.zoomAccessibilityMetadata.value == "100%")
    }
}
