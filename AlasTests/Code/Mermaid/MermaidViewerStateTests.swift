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

    @Test("actual size restores the intrinsic diagram dimensions")
    func actualSizeUsesIntrinsicToFittedScale() {
        let actualSizeScale = MermaidDiagramLayout.actualSizeScale(
            intrinsic: CGSize(width: 1_200, height: 600),
            fitted: CGSize(width: 600, height: 300)
        )
        var state = MermaidViewerInteractionState()

        _ = state.perform(.actualSize, actualSizeScale: actualSizeScale)

        #expect(actualSizeScale == 2)
        #expect(state.scale == actualSizeScale)
        #expect(
            state.zoomAccessibilityMetadata(actualSizeScale: actualSizeScale)
                .value == "100%"
        )

        _ = state.perform(.resetToFit)

        #expect(state.scale == 1)
    }

    @Test("explicit viewer zoom preserves its intrinsic percentage after resize")
    func explicitZoomPreservesIntrinsicPercentageAfterResize() {
        var state = MermaidViewerInteractionState()
        _ = state.perform(.actualSize, actualSizeScale: 2)

        state.preserveIntrinsicZoom(from: 2, to: 1.5)

        #expect(state.scale == 1.5)
        #expect(state.zoomAccessibilityMetadata(actualSizeScale: 1.5).value == "100%")

        state.adjustZoom(.increment)
        state.preserveIntrinsicZoom(from: 1.5, to: 3)

        #expect(state.scale == 3.75)
        #expect(state.zoomAccessibilityMetadata(actualSizeScale: 3).value == "125%")
    }

    @Test("fit zoom follows resize without preserving intrinsic percentage")
    func fitZoomFollowsResize() {
        var state = MermaidViewerInteractionState()
        _ = state.perform(.actualSize, actualSizeScale: 2)
        _ = state.perform(.resetToFit)

        state.preserveIntrinsicZoom(from: 2, to: 1.5)

        #expect(state.scale == 1)
        #expect(state.zoomAccessibilityMetadata(actualSizeScale: 1.5).value == "67%")
    }

    @Test("render scale changes do not reset the viewer viewport")
    func renderScaleChangesDoNotResetViewport() {
        let original = TestMermaid.key(source: "graph TD; A-->B", scale: 1)
        let sameDiagramAtNewScale = TestMermaid.key(
            source: "graph TD; A-->B",
            scale: 2
        )
        let differentDiagram = TestMermaid.key(source: "graph TD; A-->C", scale: 2)
        var state = MermaidRenderRequestState()

        #expect(state.resetsViewport(for: original))

        state.begin(original)

        #expect(!state.resetsViewport(for: sameDiagramAtNewScale))
        #expect(state.resetsViewport(for: differentDiagram))
    }

    @Test("actual size remains monotonic through gesture and toolbar zoom")
    func actualSizeScaleAboveGestureMaximumIsPreserved() {
        var state = MermaidZoomState()
        state.setActualSize(12)

        #expect(state.scale(adding: 1.25) == 15)
        state.zoom(by: 1.25)
        #expect(state.scale == 15)
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

        #expect(state.zoomAccessibilityMetadata().label == "Mermaid diagram zoom")
        #expect(state.zoomAccessibilityMetadata().value == "125%")

        state.adjustZoom(.decrement)

        #expect(state.scale == 1)
        #expect(state.zoomAccessibilityMetadata().value == "100%")
    }
}
