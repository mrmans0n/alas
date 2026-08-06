import AppKit
import Observation
import SwiftUI
import Testing
@testable import Alas

@Suite(.serialized)
@MainActor
struct DiffReviewSurfaceTests {
    init() {
        AppKitDiffScrollerFlag.setOverride(false)
    }

    private func theme() -> Theme { try! ThemeStore().current }

    @Test func appKitScrollerSwitchMatchesRuntimeFlag() {
        #expect(DiffReviewSurface.usesAppKitScroller(flagEnabled: true))
        #expect(!DiffReviewSurface.usesAppKitScroller(flagEnabled: false))
    }

    @Test func appKitReviewWindowConnectsViewportAndReviewNavigationCommands() async throws {
        let files = [
            summary(path: "Sources/First.swift"),
            summary(path: "Sources/Second.swift"),
            summary(path: "Sources/Third.swift"),
            summary(path: "Sources/Fourth.swift"),
            summary(path: "Sources/Fifth.swift"),
        ]
        let session = loadedSession(summaries: files)
        let model = AppKitReviewSurfaceWindowModel(session: session)
        let feedback = DiffReviewInlineFeedback(
            id: "feedback",
            providerName: "GitHub",
            author: "reviewer",
            bodyPreview: "Feedback",
            status: .actionable,
            providerURL: nil,
            anchor: DiffReviewInlineFeedbackAnchor(path: files[3].path, line: 1, side: .new),
            evidenceItemID: "feedback"
        )
        let draft = draftComment(
            id: "draft",
            fileID: files[4].id,
            path: files[4].path,
            startLine: 1
        )
        model.inlineFeedbackByFileID = [files[3].id: [feedback]]
        model.draftCommentsByFileID = [files[4].id: [draft]]

        try await withAppKitReviewScroller {
            let controller = host(
                AppKitReviewSurfaceWindowHarness(model: model).environment(\.theme, theme()),
                width: 1_000,
                height: 160
            )
            let window = attachWindow(controller, width: 1_000, height: 160)
            defer { ReviewDraftComposerFocusRetainer.retain(window, controller) }
            await drainSwiftUI(controller.view)
            let scroller = try #require(appKitReviewScroller(in: controller.view))

            scroller.contentView.scroll(to: NSPoint(x: 0, y: 250))
            scroller.reflectScrolledClipView(scroller.contentView)
            await drainSwiftUI(controller.view)
            #expect(model.selected == files[2].id)

            model.inlineFeedbackCommand = .init(feedbackID: "feedback", fileID: files[3].id, generation: 1)
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.2))
            await drainSwiftUI(controller.view)
            #expect(model.selected == files[3].id)

            model.inlineFeedbackCommand = nil
            model.draftCommentCommand = .init(commentID: "draft", fileID: files[4].id, generation: 1)
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.2))
            await drainSwiftUI(controller.view)
            #expect(model.selected == files[4].id)
        }
    }

    @Test func appKitReviewWindowRetainsSurfaceUpdatesAcrossPreferencesSessionReplacementAndToggle() async throws {
        let initial = loadedSession(summaries: [
            summary(path: "Sources/Initial.swift"),
            summary(path: "Sources/InitialTwo.swift"),
        ])
        let replacement = loadedSession(summaries: [
            summary(path: "Sources/Replacement.swift"),
            summary(path: "Sources/ReplacementTwo.swift"),
        ])
        let model = AppKitReviewSurfaceWindowModel(session: initial)

        try await withAppKitReviewScroller {
            let controller = host(
                AppKitReviewSurfaceWindowHarness(model: model).environment(\.theme, theme()),
                width: 1_000,
                height: 260
            )
            let window = attachWindow(controller, width: 1_000, height: 260)
            defer { ReviewDraftComposerFocusRetainer.retain(window, controller) }
            await drainSwiftUI(controller.view)
            let originalScroller = try #require(appKitReviewScroller(in: controller.view))

            model.layout = .split
            model.wrap = true
            model.whitespace = true
            await drainSwiftUI(controller.view)
            #expect(appKitReviewScroller(in: controller.view) === originalScroller)

            model.session = replacement
            await drainSwiftUI(controller.view)
            #expect(model.selected == replacement.files[0].id)
            #expect(subview(
                withAccessibilityIdentifier: "diff-review-rail-row-\(replacement.files[0].id.rawValue)",
                in: controller.view
            ) != nil)

            AppKitDiffScrollerFlag.setOverride(false)
            await drainSwiftUI(controller.view)
            #expect(appKitReviewScroller(in: controller.view) == nil)

            AppKitDiffScrollerFlag.setOverride(true)
            await drainSwiftUI(controller.view)
            let rebuiltScroller = try #require(appKitReviewScroller(in: controller.view))
            #expect(ObjectIdentifier(rebuiltScroller) != ObjectIdentifier(originalScroller))
            #expect(rebuiltScroller.scrollY == 0)
        }
    }

    @Test func appKitReviewWindowHandlesRailSameFileFallbackAndSuppressedNavigationUpdates() async throws {
        let files = [
            summary(path: "Sources/First.swift"),
            summary(path: "Sources/Second.swift"),
            summary(path: "Sources/Third.swift"),
            summary(path: "Sources/Fourth.swift"),
            summary(path: "Sources/Fifth.swift"),
        ]
        let session = loadedSession(summaries: files)
        let model = AppKitReviewSurfaceWindowModel(session: session)
        let sameFileFeedback = DiffReviewInlineFeedback(
            id: "same-file-feedback",
            providerName: "GitHub",
            author: "reviewer",
            bodyPreview: "Stay on this file.",
            status: .actionable,
            providerURL: nil,
            anchor: DiffReviewInlineFeedbackAnchor(path: files[2].path, line: nil, side: .unknown),
            evidenceItemID: "same-file-feedback"
        )
        let farDraft = draftComment(
            id: "far-draft",
            fileID: files[4].id,
            path: files[4].path,
            startLine: 1
        )
        model.inlineFeedbackByFileID = [files[2].id: [sameFileFeedback]]
        model.draftCommentsByFileID = [files[4].id: [farDraft]]

        try await withAppKitReviewScroller {
            let controller = host(
                AppKitReviewSurfaceWindowHarness(model: model).environment(\.theme, theme()),
                width: 1_000,
                height: 150
            )
            let window = attachWindow(controller, width: 1_000, height: 150)
            defer { ReviewDraftComposerFocusRetainer.retain(window, controller) }
            await drainSwiftUI(controller.view)
            let scroller = try #require(appKitReviewScroller(in: controller.view))

            model.inlineFeedbackCommand = .init(feedbackID: "same-file-feedback", fileID: files[2].id, generation: 1)
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.25))
            await drainSwiftUI(controller.view)
            #expect(model.selected == files[2].id)

            model.inlineFeedbackCommand = .init(feedbackID: "same-file-feedback", fileID: files[2].id, generation: 2)
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.20))
            await drainSwiftUI(controller.view)
            #expect(model.selected == files[2].id)

            model.inlineFeedbackCommand = .init(feedbackID: "missing-feedback", fileID: files[2].id, generation: 3)
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.20))
            await drainSwiftUI(controller.view)
            #expect(model.selected == files[2].id)

            model.inlineFeedbackCommand = nil
            model.draftCommentCommand = .init(commentID: "far-draft", fileID: files[4].id, generation: 1)
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))
            scroller.contentView.scroll(to: NSPoint(x: 0, y: 0))
            scroller.reflectScrolledClipView(scroller.contentView)
            await drainSwiftUI(controller.view)
            #expect(model.selected == files[4].id)
        }
    }

    @Test func appKitReviewWindowExpandsContextAndCompensatesInsertionsAboveViewport() async throws {
        let firstSummary = summary(path: "Sources/Context.swift")
        let secondSummary = summary(path: "Sources/Below.swift")
        let collapsedFirst = fileSection(
            summary: firstSummary,
            displayModel: collapsedContextDisplayModel(filePath: firstSummary.path, hiddenRowCount: 8)
        )
        let second = fileSection(
            summary: secondSummary,
            displayModel: largeSingleGroupDisplayModel(rowCount: 40, filePath: secondSummary.path)
        )
        let model = AppKitReviewSurfaceWindowModel(session: loadedSession(files: [collapsedFirst, second]))

        try await withAppKitReviewScroller {
            let controller = host(
                AppKitReviewSurfaceWindowHarness(model: model).environment(\.theme, theme()),
                width: 1_000,
                height: 220
            )
            let window = attachWindow(controller, width: 1_000, height: 220)
            defer { ReviewDraftComposerFocusRetainer.retain(window, controller) }
            await drainSwiftUI(controller.view)
            let scroller = try #require(appKitReviewScroller(in: controller.view))

            #expect(pressAccessibilityElement(
                withAccessibilityIdentifier: "diff-review-rail-row-\(secondSummary.id.rawValue)",
                in: controller.view
            ))
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.25))
            await drainSwiftUI(controller.view)
            let beforeInsertionY = scroller.scrollY

            let expandedFirst = fileSection(
                summary: firstSummary,
                displayModel: expandedContextDisplayModel(filePath: firstSummary.path, hiddenRowCount: 16)
            )
            model.session = loadedSession(files: [expandedFirst, second])
            await drainSwiftUI(controller.view)

            #expect(model.selected == secondSummary.id)
            #expect(scroller.scrollY >= beforeInsertionY)
        }
    }

    @Test func appKitReviewWindowCompensatesCommentInsertionAboveViewport() async throws {
        let firstSummary = summary(path: "Sources/CommentAbove.swift")
        let secondSummary = summary(path: "Sources/CommentBelow.swift")
        let first = fileSection(
            summary: firstSummary,
            displayModel: largeSingleGroupDisplayModel(rowCount: 30, filePath: firstSummary.path)
        )
        let second = fileSection(
            summary: secondSummary,
            displayModel: largeSingleGroupDisplayModel(rowCount: 30, filePath: secondSummary.path)
        )
        let model = AppKitReviewSurfaceWindowModel(session: loadedSession(files: [first, second]))

        try await withAppKitReviewScroller {
            let controller = host(
                AppKitReviewSurfaceWindowHarness(model: model).environment(\.theme, theme()),
                width: 1_000,
                height: 260
            )
            let window = attachWindow(controller, width: 1_000, height: 260)
            defer { ReviewDraftComposerFocusRetainer.retain(window, controller) }
            await drainSwiftUI(controller.view)
            let scroller = try #require(appKitReviewScroller(in: controller.view))

            #expect(pressAccessibilityElement(
                withAccessibilityIdentifier: "diff-review-rail-row-\(secondSummary.id.rawValue)",
                in: controller.view
            ))
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.30))
            await drainSwiftUI(controller.view)
            let beforeInsertionY = scroller.scrollY
            #expect(model.selected == secondSummary.id)

            model.draftCommentsByFileID = [
                first.id: [draftComment(id: "above-draft", fileID: first.id, path: first.summary.path, startLine: 1)],
            ]
            await drainSwiftUI(controller.view)

            #expect(model.selected == secondSummary.id)
            #expect(scroller.scrollY >= beforeInsertionY)
        }
    }

    @Test func appKitReviewWindowExpandsContextThroughRenderedControl() async throws {
        let summary = summary(path: "Sources/ContextControl.swift")
        let file = fileSection(
            summary: summary,
            displayModel: collapsedContextDisplayModel(filePath: summary.path, hiddenRowCount: 8)
        )
        let model = AppKitReviewSurfaceWindowModel(session: loadedSession(files: [file]))

        try await withAppKitReviewScroller {
            let controller = host(
                AppKitReviewSurfaceWindowHarness(model: model).environment(\.theme, theme()),
                width: 1_000,
                height: 420
            )
            let window = attachWindow(controller, width: 1_000, height: 420)
            defer { ReviewDraftComposerFocusRetainer.retain(window, controller) }
            await drainSwiftUI(controller.view)
            let scroller = try #require(appKitReviewScroller(in: controller.view))
            let collapsedHeight = scroller.documentView?.frame.height ?? 0

            #expect(pressButton(withToolTip: "Expand context", in: controller.view))
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.20))
            await drainSwiftUI(controller.view)

            #expect((scroller.documentView?.frame.height ?? 0) > collapsedHeight)
        }
    }

    @Test func appKitReviewWindowPinsFocusedComposerWhileScrolling() async throws {
        let file = fileSection(
            summary: summary(path: "Sources/Composer.swift"),
            displayModel: largeSingleGroupDisplayModel(rowCount: 80, filePath: "Sources/Composer.swift")
        )
        let model = AppKitReviewSurfaceWindowModel(session: loadedSession(files: [file]))

        try await withAppKitReviewScroller {
            let controller = host(
                AppKitReviewSurfaceWindowHarness(model: model).environment(\.theme, theme()),
                width: 1_000,
                height: 260
            )
            let window = attachWindow(controller, width: 1_000, height: 260)
            defer { ReviewDraftComposerFocusRetainer.retain(window, controller) }
            await drainSwiftUI(controller.view)

            try selectReviewLine(selectionIndex: 0, in: controller.view)
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.20))
            await drainSwiftUI(controller.view)
            let composer = try #require(draftComposerTextView(in: controller.view))
            #expect(window.firstResponder === composer)

            let scroller = try #require(appKitReviewScroller(in: controller.view))
            scroller.setScrollY(900, animated: false)
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.10))
            await drainSwiftUI(controller.view)
            #expect(draftComposerTextView(in: controller.view) != nil)
            #expect(window.firstResponder === composer)
        }
    }

    @Test func appKitReviewWindowRoutesImageRetryAndStagedMutationActions() async throws {
        let imageLoader = AppKitImageRetryRecorder()
        let actions = AppKitReviewActionRecorder()
        let imageSummary = summary(path: "Assets/logo.png", status: .modified)
        let stagedSummary = summary(
            path: "Sources/Staged.swift",
            namespace: "staged",
            groupID: "staged",
            groupTitle: "Staged"
        )
        let imageFile = fileSection(
            summary: imageSummary,
            displayModel: nil,
            imageProvider: DiffReviewImageProvider(
                id: DiffReviewImageProviderID(
                    source: .commit,
                    repository: "/repo",
                    beforeRevision: "abc123^",
                    afterRevision: "abc123",
                    beforePath: imageSummary.path,
                    afterPath: imageSummary.path
                ),
                load: { await imageLoader.load() }
            )
        )
        let stagedFile = fileSection(
            summary: stagedSummary,
            displayModel: displayModel(),
            stagedMutationActions: DiffReviewStagedMutationActions(
                unstageFile: { actions.unstagedFiles += 1 },
                unstageHunk: { _ in actions.unstagedHunks += 1 },
                isHunkUnstageEnabled: { _ in true }
            )
        )
        let model = AppKitReviewSurfaceWindowModel(session: loadedSession(files: [imageFile, stagedFile]))

        try await withAppKitReviewScroller {
            let controller = host(
                AppKitReviewSurfaceWindowHarness(model: model).environment(\.theme, theme()),
                width: 1_000,
                height: 900
            )
            let window = attachWindow(controller, width: 1_000, height: 900)
            defer { ReviewDraftComposerFocusRetainer.retain(window, controller) }
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.20))
            await drainSwiftUI(controller.view)

            #expect(imageLoader.loadCount == 1)
            #expect(pressAccessibilityElement(
                withAccessibilityIdentifier: "diff-review-image-retry-\(imageSummary.id.rawValue)",
                in: controller.view
            ))
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.20))
            await drainSwiftUI(controller.view)
            #expect(imageLoader.loadCount == 2)

            let scroller = try #require(appKitReviewScroller(in: controller.view))
            scroller.setScrollY(420, animated: false)
            await drainSwiftUI(controller.view)
            #expect(pressAccessibilityElement(
                withAccessibilityIdentifier: "diff-review-unstage-file-\(stagedSummary.id.rawValue)",
                in: controller.view
            ))
            #expect(actions.unstagedFiles == 1)
        }
    }

    @Test func appKitReviewWindowRoutesStagedHunkMutationAction() async throws {
        let actions = AppKitReviewActionRecorder()
        let stagedSummary = summary(
            path: "Sources/StagedHunk.swift",
            namespace: "staged",
            groupID: "staged",
            groupTitle: "Staged"
        )
        let stagedFile = fileSection(
            summary: stagedSummary,
            displayModel: displayModel(),
            stagedMutationActions: DiffReviewStagedMutationActions(
                unstageHunk: { _ in actions.unstagedHunks += 1 },
                isHunkUnstageEnabled: { _ in true }
            )
        )
        let model = AppKitReviewSurfaceWindowModel(session: loadedSession(files: [stagedFile]))

        try await withAppKitReviewScroller {
            let controller = host(
                AppKitReviewSurfaceWindowHarness(model: model).environment(\.theme, theme()),
                width: 1_000,
                height: 420
            )
            let window = attachWindow(controller, width: 1_000, height: 420)
            defer { ReviewDraftComposerFocusRetainer.retain(window, controller) }
            await drainSwiftUI(controller.view)

            #expect(pressButton(withToolTip: "Drop from commit", in: controller.view))
            #expect(actions.unstagedHunks == 1)
        }
    }

    @Test func draftComposerRefocusesForEachNewFocusRequestGeneration() async throws {
        let model = ReviewDraftComposerFocusModel()
        let controller = NSHostingController(
            rootView: ReviewDraftComposerFocusHarness(theme: theme(), model: model)
        )
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 480, height: 240),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.contentViewController = controller
        controller.view.frame = window.contentView?.bounds ?? NSRect(x: 0, y: 0, width: 480, height: 240)
        controller.view.layoutSubtreeIfNeeded()
        defer { ReviewDraftComposerFocusRetainer.retain(window, controller) }

        await drainSwiftUI(controller.view)

        let textView = try #require(allSubviews(of: controller.view).compactMap { $0 as? NSTextView }.first)
        #expect(window.firstResponder === textView)

        let sibling = try #require(
            subview(withAccessibilityIdentifier: "draft-composer-focus-sibling", in: controller.view)
        )
        #expect(window.makeFirstResponder(sibling))
        #expect(window.firstResponder !== textView)

        model.focusRequestGeneration += 1
        await drainSwiftUI(controller.view)

        #expect(window.firstResponder === textView)
    }

    @Test func railRendersUngroupedCommitSessionWithFileRowsAndNoSourceHeader() {
        let files = [
            summary(path: "Sources/App/AlphaView.swift", additions: 4, deletions: 1),
            summary(path: "Tests/BetaTests.swift", status: .added, additions: 12, deletions: 0),
        ]
        let session = DiffReviewSessionModel(files: files, groupsEnabled: false)
        var selected = files[0].id
        var collapsed = false

        let view = DiffReviewRail(
            session: session,
            selectedFileID: Binding(get: { selected }, set: { selected = $0 }),
            collapsed: Binding(get: { collapsed }, set: { collapsed = $0 }),
            onSelectFile: { selected = $0 }
        )
        .environment(\.theme, theme())

        let controller = host(view, width: 280, height: 500)

        #expect(subview(withAccessibilityIdentifier: "diff-review-rail-row-\(files[0].id.rawValue)", in: controller.view) != nil)
        #expect(subview(withAccessibilityIdentifier: "diff-review-rail-row-\(files[1].id.rawValue)", in: controller.view) != nil)
        #expect(subview(withAccessibilityIdentifier: "diff-review-rail-source-commit", in: controller.view) == nil)
        #expect(accessibilityLabel(in: controller.view, containing: "AlphaView.swift") != nil)
        #expect(accessibilityLabel(in: controller.view, containing: "BetaTests.swift") != nil)
    }

    @Test func railRendersGroupedSessionsWithSourceHeaders() {
        let files = [
            summary(path: "Sources/App/AlphaView.swift", namespace: "unstaged", groupID: "unstaged", groupTitle: "Unstaged"),
            summary(path: "Sources/App/BetaView.swift", namespace: "staged", groupID: "staged", groupTitle: "Staged", status: .added),
        ]
        let session = DiffReviewSessionModel(files: files, groupsEnabled: true)
        var selected = files[0].id
        var collapsed = false

        let view = DiffReviewRail(
            session: session,
            selectedFileID: Binding(get: { selected }, set: { selected = $0 }),
            collapsed: Binding(get: { collapsed }, set: { collapsed = $0 }),
            onSelectFile: { selected = $0 }
        )
        .environment(\.theme, theme())

        let controller = host(view, width: 280, height: 500)

        #expect(subview(withAccessibilityIdentifier: "diff-review-rail-source-unstaged", in: controller.view) != nil)
        #expect(subview(withAccessibilityIdentifier: "diff-review-rail-source-staged", in: controller.view) != nil)
        #expect(subview(withAccessibilityIdentifier: "diff-review-rail-row-\(files[0].id.rawValue)", in: controller.view) != nil)
        #expect(subview(withAccessibilityIdentifier: "diff-review-rail-row-\(files[1].id.rawValue)", in: controller.view) != nil)
    }

    @Test func collapsedRailKeepsSelectableMarkers() {
        let files = [
            summary(path: "Sources/App/AlphaView.swift", additions: 4, deletions: 1),
            summary(path: "Tests/BetaTests.swift", status: .added, additions: 12, deletions: 0),
        ]
        let session = DiffReviewSessionModel(files: files, groupsEnabled: false)
        var selected = files[1].id
        var collapsed = true

        let view = DiffReviewRail(
            session: session,
            selectedFileID: Binding(get: { selected }, set: { selected = $0 }),
            collapsed: Binding(get: { collapsed }, set: { collapsed = $0 }),
            onSelectFile: { selected = $0 }
        )
        .environment(\.theme, theme())

        let controller = host(view, width: 60, height: 500)

        #expect(subview(withAccessibilityIdentifier: "diff-review-rail-marker-\(files[0].id.rawValue)", in: controller.view) != nil)
        #expect(subview(withAccessibilityIdentifier: "diff-review-rail-marker-\(files[1].id.rawValue)", in: controller.view) != nil)
        #expect(subview(withAccessibilityIdentifier: "diff-review-rail-marker-selected-\(files[1].id.rawValue)", in: controller.view) != nil)
    }

    @Test func railSelectedFileRowsUseSidebarSelectionTreatment() {
        #expect(DiffReviewRailSelectedRowStyle.backgroundToken == "bg-4")
        #expect(DiffReviewRailSelectedRowStyle.fileDepthIndent == 6)
        #expect(DiffReviewRailSelectedRowStyle.accentRailWidth == 3)
        #expect(DiffReviewRailSelectedRowStyle.accentRailHeight == 14)
        #expect(DiffReviewRailSelectedRowStyle.accentRailXOffset == 2)
        #expect(DiffReviewRailSelectedRowStyle.cornerRadius == 6)
        #expect(DiffReviewRailSelectedRowStyle.contentLeadingPadding == 6)
    }

    @Test func fileSectionHidesReviewAffordanceWhenDraftCommentCreationIsDisabled() {
        let file = DiffReviewFileSectionModel(
            summary: summary(
                path: "Sources/App/AlphaView.swift",
                namespace: "commit",
                groupID: "commit",
                groupTitle: "Commit",
                additions: 1,
                deletions: 1
            ),
            parsedDiff: parsedDiff(),
            displayModel: displayModel(),
            placeholderMessage: nil,
            openFile: nil,
            contextProvider: nil
        )
        var layout = DiffLayoutMode.split
        var wrap = false
        var whitespace = false

        let view = DiffReviewFileSection(
            file: file,
            layoutMode: Binding(get: { layout }, set: { layout = $0 }),
            wrapLines: Binding(get: { wrap }, set: { wrap = $0 }),
            showWhitespace: Binding(get: { whitespace }, set: { whitespace = $0 }),
            codeFontFamily: "",
            codeFontSize: 13,
            showsSourceBadge: false,
            allowsDraftCommentCreation: false
        )
        .environment(\.theme, theme())

        let controller = host(view, width: 900, height: 500)
        let rulers = allSubviews(of: controller.view).compactMap { $0 as? DiffPaneLineNumberRulerView }
        #expect(!rulers.isEmpty)
        for ruler in rulers {
            #expect(!ruler.allowsReviewLineSelection)
        }
    }

    @Test func fileSectionRendersLazyImageLoadingAndFailureStates() async {
        let gate = ImagePairLoadGate()
        let file = DiffReviewFileSectionModel(
            summary: summary(path: "Assets/logo.png", status: .modified),
            parsedDiff: nil,
            displayModel: nil,
            placeholderMessage: nil,
            openFile: nil,
            contextProvider: nil,
            imageProvider: DiffReviewImageProvider(
                id: DiffReviewImageProviderID(
                    source: .commit,
                    repository: "/repo",
                    beforeRevision: "abc123^",
                    afterRevision: "abc123",
                    beforePath: "Assets/logo.png",
                    afterPath: "Assets/logo.png"
                ),
                load: { await gate.wait() }
            )
        )
        var layout = DiffLayoutMode.split
        var wrap = false
        var whitespace = false
        let view = DiffReviewFileSection(
            file: file,
            layoutMode: Binding(get: { layout }, set: { layout = $0 }),
            wrapLines: Binding(get: { wrap }, set: { wrap = $0 }),
            showWhitespace: Binding(get: { whitespace }, set: { whitespace = $0 }),
            codeFontFamily: "",
            codeFontSize: 13,
            showsSourceBadge: false,
            allowsDraftCommentCreation: false
        )
        .environment(\.theme, theme())

        let controller = host(view, width: 900, height: 520)
        await drainSwiftUI(controller.view)

        #expect(subview(withAccessibilityIdentifier: "diff-review-image-loading-\(file.id.rawValue)", in: controller.view) != nil)

        gate.resume(returning: ImageDiffPair(
            before: .failed(.init(message: "Could not decode before image")),
            after: .missing,
            oldPath: nil,
            kind: .deleted
        ))
        await drainSwiftUI(controller.view)

        #expect(subviews(withAccessibilityIdentifier: "diff-review-image-header-\(file.id.rawValue)", in: controller.view).count == 1)
        #expect(subview(withAccessibilityIdentifier: "diff-review-image-loading-\(file.id.rawValue)", in: controller.view) == nil)
        #expect(subview(withAccessibilityIdentifier: "diff-review-image-failure-\(file.id.rawValue)", in: controller.view) != nil)
        #expect(subview(withAccessibilityIdentifier: "diff-review-image-retry-\(file.id.rawValue)", in: controller.view) != nil)
    }

    @Test func legacyFileSectionImageProviderLoadsOnce() async {
        let imageLoader = AppKitImageRetryRecorder()
        let file = DiffReviewFileSectionModel(
            summary: summary(path: "Assets/legacy.png", status: .modified),
            parsedDiff: nil,
            displayModel: nil,
            placeholderMessage: nil,
            openFile: nil,
            contextProvider: nil,
            imageProvider: DiffReviewImageProvider(
                id: DiffReviewImageProviderID(
                    source: .commit,
                    repository: "/repo",
                    beforeRevision: "abc123^",
                    afterRevision: "abc123",
                    beforePath: "Assets/legacy.png",
                    afterPath: "Assets/legacy.png"
                ),
                load: { await imageLoader.load() }
            )
        )
        var layout = DiffLayoutMode.split
        var wrap = false
        var whitespace = false
        let view = DiffReviewFileSection(
            file: file,
            layoutMode: Binding(get: { layout }, set: { layout = $0 }),
            wrapLines: Binding(get: { wrap }, set: { wrap = $0 }),
            showWhitespace: Binding(get: { whitespace }, set: { whitespace = $0 }),
            codeFontFamily: "",
            codeFontSize: 13,
            showsSourceBadge: false,
            allowsDraftCommentCreation: false
        )
        .environment(\.theme, theme())

        let controller = host(view, width: 900, height: 520)
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.20))
        await drainSwiftUI(controller.view)

        #expect(imageLoader.loadCount == 1)
    }

    @Test func imageFileSectionRendersProviderThreadsAndAnnotations() async {
        let file = DiffReviewFileSectionModel(
            summary: summary(path: "Assets/logo.png", status: .modified),
            parsedDiff: nil,
            displayModel: nil,
            placeholderMessage: nil,
            openFile: nil,
            contextProvider: nil,
            imageProvider: DiffReviewImageProvider(
                id: DiffReviewImageProviderID(
                    source: .commit,
                    repository: "/repo",
                    beforeRevision: "base",
                    afterRevision: "head",
                    beforePath: "Assets/logo.png",
                    afterPath: "Assets/logo.png"
                ),
                load: {
                    let image = NSImage(size: NSSize(width: 1, height: 1))
                    return ImageDiffPair(
                        before: .image(image, frameCount: 1),
                        after: .image(image, frameCount: 1),
                        oldPath: nil,
                        kind: .modified
                    )
                }
            )
        )
        let thread = DiffInlineCommentThread(
            id: "provider-thread",
            filePath: file.summary.path,
            newLine: 1,
            isResolved: false,
            isOutdated: false,
            comments: [
                DiffInlineComment(
                    id: "provider-comment",
                    author: "reviewer",
                    body: "Keep this image feedback visible.",
                    viewerCanUpdate: true,
                    viewerCanDelete: true
                ),
            ]
        )
        let annotation = DiffInlineAnnotation(
            id: "provider-annotation",
            checkName: "Asset check",
            newLine: 1,
            level: .warning,
            message: "Image dimensions changed.",
            rawDetails: nil
        )
        var layout = DiffLayoutMode.split
        var wrap = false
        var whitespace = false

        let view = DiffReviewFileSection(
            file: file,
            layoutMode: Binding(get: { layout }, set: { layout = $0 }),
            wrapLines: Binding(get: { wrap }, set: { wrap = $0 }),
            showWhitespace: Binding(get: { whitespace }, set: { whitespace = $0 }),
            codeFontFamily: "",
            codeFontSize: 13,
            showsSourceBadge: false,
            threads: [thread],
            annotations: [annotation],
            canReply: true,
            canResolve: true,
            canAddToReview: true
        )
        .environment(\.theme, theme())

        let controller = host(view, width: 900, height: 720)
        await drainSwiftUI(controller.view)

        #expect(subview(
            withAccessibilityIdentifier: "diff-review-image-thread-\(thread.id)",
            in: controller.view
        ) != nil)
        #expect(subview(
            withAccessibilityIdentifier: "diff-review-image-annotation-\(annotation.id)",
            in: controller.view
        ) != nil)
    }

    @Test func imageProviderFeedbackPresentationRoutesEveryAction() {
        let file = DiffReviewFileSectionModel(
            summary: summary(path: "Assets/logo.png", status: .modified),
            parsedDiff: nil,
            displayModel: nil,
            placeholderMessage: nil,
            openFile: nil,
            contextProvider: nil,
            imageProvider: nil
        )
        let comment = DiffInlineComment(
            id: "provider-comment",
            author: "reviewer",
            body: "Keep this image feedback visible.",
            viewerCanUpdate: true,
            viewerCanDelete: true
        )
        let thread = DiffInlineCommentThread(
            id: "provider-thread",
            filePath: file.summary.path,
            newLine: 1,
            isResolved: false,
            isOutdated: false,
            comments: [comment]
        )
        var routedActions: [String] = []
        var layout = DiffLayoutMode.split
        var wrap = false
        var whitespace = false

        let section = DiffReviewFileSection(
            file: file,
            layoutMode: Binding(get: { layout }, set: { layout = $0 }),
            wrapLines: Binding(get: { wrap }, set: { wrap = $0 }),
            showWhitespace: Binding(get: { whitespace }, set: { whitespace = $0 }),
            codeFontFamily: "",
            codeFontSize: 13,
            showsSourceBadge: false,
            onReply: { routedActions.append("reply:\($0.id):\($1)") },
            onResolve: { routedActions.append("resolve:\($0.id)") },
            onUnresolve: { routedActions.append("unresolve:\($0.id)") },
            onEdit: { routedActions.append("edit:\($0.id):\($1.id):\($2)") },
            onDelete: { routedActions.append("delete:\($0.id):\($1.id)") },
            canReply: true,
            canResolve: true,
            onStageReply: { routedActions.append("stage:\($0.id):\($1)") },
            canAddToReview: true
        )
        let presentation = section.imageProviderThreadPresentation(for: thread)

        presentation.onReply("sent")
        presentation.onStageReply("draft")
        presentation.onResolve()
        presentation.onUnresolve()
        presentation.onEdit(comment, "edited")
        presentation.onDelete(comment)

        #expect(presentation.canReply)
        #expect(presentation.canResolve)
        #expect(presentation.canAddToReview)
        #expect(routedActions == [
            "reply:provider-thread:sent",
            "stage:provider-thread:draft",
            "resolve:provider-thread",
            "unresolve:provider-thread",
            "edit:provider-thread:provider-comment:edited",
            "delete:provider-thread:provider-comment",
        ])
    }

    @Test func imageProviderFeedbackIncludesFileLevelThreads() {
        let filePath = "Assets/logo.png"
        let thread = ReviewThread(
            id: "file-level-thread",
            path: filePath,
            line: nil,
            startLine: nil,
            originalLine: nil,
            diffHunk: nil,
            isResolved: false,
            isOutdated: false,
            isFileLevel: true,
            comments: [
                ReviewComment(
                    id: "comment",
                    author: "reviewer",
                    body: "This applies to the whole image.",
                    url: nil,
                    createdAt: nil,
                    viewerCanUpdate: true,
                    viewerCanDelete: true,
                    isPending: false
                ),
            ],
            viewerCanResolve: true,
            viewerCanReply: true,
            url: nil
        )

        let resolved = DiffReviewProviderFeedbackResolver.threads(
            [thread],
            for: filePath,
            includeFileLevel: true
        )

        #expect(resolved.map(\.id) == [thread.id])
        #expect(resolved.first?.comments.map(\.id) == ["comment"])
        #expect(DiffReviewProviderFeedbackResolver.threads(
            [thread],
            for: filePath,
            includeFileLevel: false
        ).isEmpty)
    }

    @Test func fileSectionClearsImageControlsWhenProviderIsRemoved() async {
        let imageFile = DiffReviewFileSectionModel(
            summary: summary(path: "Assets/logo.png", status: .modified),
            parsedDiff: nil,
            displayModel: nil,
            placeholderMessage: nil,
            openFile: nil,
            contextProvider: nil,
            imageProvider: DiffReviewImageProvider(
                id: DiffReviewImageProviderID(
                    source: .commit,
                    repository: "/repo",
                    beforeRevision: "abc123^",
                    afterRevision: "abc123",
                    beforePath: "Assets/logo.png",
                    afterPath: "Assets/logo.png"
                ),
                load: {
                    ImageDiffPair(
                        before: .failed(.init(message: "Could not decode before image")),
                        after: .missing,
                        oldPath: nil,
                        kind: .deleted
                    )
                }
            )
        )
        let model = ImageProviderRemovalModel(file: imageFile)
        let view = ImageProviderRemovalHarness(theme: theme(), model: model)
        let controller = host(view, width: 900, height: 520)
        await drainSwiftUI(controller.view)

        #expect(subview(withAccessibilityIdentifier: "diff-review-image-header-\(imageFile.id.rawValue)", in: controller.view) != nil)

        model.file = DiffReviewFileSectionModel(
            summary: imageFile.summary,
            parsedDiff: nil,
            displayModel: nil,
            placeholderMessage: nil,
            openFile: nil,
            contextProvider: nil
        )
        await drainSwiftUI(controller.view)

        #expect(subview(withAccessibilityIdentifier: "diff-review-image-header-\(imageFile.id.rawValue)", in: controller.view) == nil)
    }

    @Test func fileSectionRefocusesDraftComposerAfterSelectingDifferentGutterRows() async throws {
        let file = DiffReviewFileSectionModel(
            summary: summary(path: "Sources/App/AlphaView.swift"),
            parsedDiff: parsedDiff(),
            displayModel: displayModel(),
            placeholderMessage: nil,
            openFile: nil,
            contextProvider: nil
        )
        var layout = DiffLayoutMode.stacked
        var wrap = false
        var whitespace = false
        let view = DiffReviewFileSection(
            file: file,
            layoutMode: Binding(get: { layout }, set: { layout = $0 }),
            wrapLines: Binding(get: { wrap }, set: { wrap = $0 }),
            showWhitespace: Binding(get: { whitespace }, set: { whitespace = $0 }),
            codeFontFamily: "",
            codeFontSize: 13,
            showsSourceBadge: false
        )
        .environment(\.theme, theme())

        let controller = NSHostingController(rootView: view)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 520),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.contentViewController = controller
        controller.view.frame = window.contentView?.bounds ?? NSRect(x: 0, y: 0, width: 900, height: 520)
        controller.view.layoutSubtreeIfNeeded()
        defer { ReviewDraftComposerFocusRetainer.retain(window, controller) }

        await drainSwiftUI(controller.view)
        try selectReviewLine(selectionIndex: 0, in: controller.view)
        await drainSwiftUI(controller.view)

        let firstComposer = try #require(draftComposerTextView(in: controller.view))
        #expect(window.firstResponder === firstComposer)

        let sink = FocusSinkView(frame: NSRect(x: 0, y: 0, width: 1, height: 1))
        controller.view.addSubview(sink)
        #expect(window.makeFirstResponder(sink))
        #expect(window.firstResponder !== firstComposer)

        try selectReviewLine(selectionIndex: 1, in: controller.view)
        await drainSwiftUI(controller.view)

        let relocatedComposer = try #require(draftComposerTextView(in: controller.view))
        #expect(window.firstResponder === relocatedComposer)
    }

    @Test func stackedFileSectionBoundsHunkMaterializationToScrollViewport() throws {
        let baseModel = largeDisplayModel(groupCount: 80, filePath: "Sources/App/LargeView.swift")
        let groups = baseModel.groups
        let file = DiffReviewFileSectionModel(
            summary: summary(
                path: "Sources/App/LargeView.swift",
                additions: groups.count,
                deletions: groups.count
            ),
            parsedDiff: parsedDiff(),
            displayModel: DiffDisplayModel(filePath: baseModel.filePath, groups: groups),
            placeholderMessage: nil,
            openFile: nil,
            contextProvider: nil
        )
        var layout = DiffLayoutMode.stacked
        var wrap = false
        var whitespace = false
        let section = DiffReviewFileSection(
            file: file,
            layoutMode: Binding(get: { layout }, set: { layout = $0 }),
            wrapLines: Binding(get: { wrap }, set: { wrap = $0 }),
            showWhitespace: Binding(get: { whitespace }, set: { whitespace = $0 }),
            codeFontFamily: "",
            codeFontSize: 13,
            showsSourceBadge: false
        )
        .environment(\.theme, theme())

        let controller = NSHostingController(rootView: ScrollView(.vertical) { section })
        controller.view.frame = NSRect(x: 0, y: 0, width: 900, height: 500)
        for _ in 0..<5 {
            controller.view.layoutSubtreeIfNeeded()
        }

        let materializedSegments = allSubviews(of: controller.view)
            .compactMap { $0 as? DiffPaneTextDocumentContainerView }
        let initialIdentities = Set(materializedSegments.map(ObjectIdentifier.init))
        #expect(!materializedSegments.isEmpty)
        #expect(materializedSegments.count < groups.count)

        for _ in 0..<10 {
            controller.view.needsLayout = true
            controller.view.layoutSubtreeIfNeeded()
        }

        let settledIdentities = Set(allSubviews(of: controller.view)
            .compactMap { $0 as? DiffPaneTextDocumentContainerView }
            .map(ObjectIdentifier.init))
        #expect(settledIdentities == initialIdentities)
    }

    @Test func accessoryHunkBoundsSegmentMaterializationToScrollViewport() {
        let path = "A.swift"
        let rowCount = 200
        let displayModel = largeSingleGroupDisplayModel(rowCount: rowCount, filePath: path)
        let file = DiffReviewFileSectionModel(
            summary: summary(path: path, additions: rowCount),
            parsedDiff: parsedDiff(),
            displayModel: displayModel,
            placeholderMessage: nil,
            openFile: nil,
            contextProvider: nil
        )
        let comments = (1...rowCount).map { line in
            draftComment(
                id: "draft-\(line)",
                fileID: file.id,
                path: path,
                startLine: line
            )
        }
        var layout = DiffLayoutMode.stacked
        var wrap = false
        var whitespace = false
        let section = DiffReviewFileSection(
            file: file,
            draftComments: comments,
            draftCommentScrollTargetID: comments.last?.id,
            layoutMode: Binding(get: { layout }, set: { layout = $0 }),
            wrapLines: Binding(get: { wrap }, set: { wrap = $0 }),
            showWhitespace: Binding(get: { whitespace }, set: { whitespace = $0 }),
            codeFontFamily: "",
            codeFontSize: 13,
            showsSourceBadge: false
        )
        .environment(\.theme, theme())

        let controller = NSHostingController(rootView: ScrollView(.vertical) { section })
        controller.view.frame = NSRect(x: 0, y: 0, width: 900, height: 500)
        for _ in 0..<5 {
            controller.view.layoutSubtreeIfNeeded()
        }
        RunLoop.current.run(until: Date().addingTimeInterval(0.6))
        controller.view.layoutSubtreeIfNeeded()

        let materializedSegments = allSubviews(of: controller.view)
            .compactMap { $0 as? DiffPaneTextDocumentContainerView }
        #expect(subview(
            withAccessibilityIdentifier: "diff-review-draft-comment-draft-\(rowCount)",
            in: controller.view
        ) != nil)
        #expect(!materializedSegments.isEmpty)
        #expect(materializedSegments.count < rowCount / 2)
    }

    @Test func inlineFeedbackScrollRealizesTargetHunkWithoutEagerlyRenderingAllHunks() {
        let path = "Sources/App/LargeView.swift"
        let displayModel = largeDisplayModel(groupCount: 80, filePath: path)
        let file = DiffReviewFileSectionModel(
            summary: summary(path: path, additions: 80),
            parsedDiff: parsedDiff(),
            displayModel: displayModel,
            placeholderMessage: nil,
            openFile: nil,
            contextProvider: nil
        )
        let feedback = DiffReviewInlineFeedback(
            id: "deep-feedback",
            providerName: "GitHub",
            author: "reviewer",
            bodyPreview: "Please update the final hunk.",
            status: .actionable,
            providerURL: nil,
            anchor: DiffReviewInlineFeedbackAnchor(path: path, line: 80, side: .new),
            evidenceItemID: "deep-feedback"
        )
        let staleDraft = draftComment(
            id: "stale-draft",
            fileID: file.id,
            path: path,
            startLine: 1
        )
        let session = DiffReviewLoadedSession(
            files: [file],
            summary: DiffReviewSessionModel(files: [file.summary], groupsEnabled: false)
        )
        var selectedFileID: DiffReviewFileID? = file.id
        var railCollapsed = true
        var layout = DiffLayoutMode.stacked
        var wrap = false
        var whitespace = false
        let view = DiffReviewSurface(
            session: session,
            selectedFileID: Binding(get: { selectedFileID }, set: { selectedFileID = $0 }),
            railCollapsed: Binding(get: { railCollapsed }, set: { railCollapsed = $0 }),
            layoutMode: Binding(get: { layout }, set: { layout = $0 }),
            wrapLines: Binding(get: { wrap }, set: { wrap = $0 }),
            showWhitespace: Binding(get: { whitespace }, set: { whitespace = $0 }),
            codeFontFamily: "",
            codeFontSize: 13,
            inlineFeedbackByFileID: [file.id: [feedback]],
            inlineFeedbackScrollCommand: DiffReviewInlineFeedbackScrollCommand(
                feedbackID: feedback.id,
                fileID: file.id,
                generation: 1
            ),
            draftCommentsByFileID: [file.id: [staleDraft]],
            focusedDraftCommentID: staleDraft.id
        )
        .environment(\.theme, theme())

        let controller = host(view, width: 1_200, height: 500)
        RunLoop.current.run(until: Date().addingTimeInterval(0.6))
        controller.view.layoutSubtreeIfNeeded()

        #expect(subview(withAccessibilityIdentifier: "diff-review-inline-feedback-deep-feedback", in: controller.view) != nil)
        let materializedSegments = allSubviews(of: controller.view)
            .compactMap { $0 as? DiffPaneTextDocumentContainerView }
        #expect(materializedSegments.count < displayModel.groups.count / 2)
    }

    @Test func requiredGroupResolverFindsInlineFeedbackAndDraftCommentHunks() {
        let path = "Sources/App/LargeView.swift"
        let displayModel = largeDisplayModel(groupCount: 80, filePath: path)
        let fileID = DiffReviewFileID(namespace: "commit", path: path)
        let feedback = DiffReviewInlineFeedback(
            id: "deep-feedback",
            providerName: "GitHub",
            author: "reviewer",
            bodyPreview: "Please update the final hunk.",
            status: .actionable,
            providerURL: nil,
            anchor: DiffReviewInlineFeedbackAnchor(path: path, line: 80, side: .new),
            evidenceItemID: "deep-feedback"
        )
        let comment = draftComment(
            id: "deep-draft",
            fileID: fileID,
            path: path,
            startLine: 1
        )

        let renderContext = DiffReviewRenderContextBuilder.build(
            fileID: fileID,
            displayModel: displayModel,
            contextSnapshot: nil,
            contextProviderAvailable: false,
            contextExpansion: DiffContextExpansionState(),
            inlineFeedback: [feedback],
            draftComments: [comment],
            pendingDraftAnchor: nil,
            canCreateDraftComment: false,
            threads: [],
            annotations: []
        )

        #expect(DiffReviewRequiredGroupResolver.groupIDs(
            in: renderContext.groups,
            inlineFeedbackIDs: [feedback.id],
            draftCommentIDs: []
        ) == ["group-79"])
        #expect(DiffReviewRequiredGroupResolver.groupIDs(
            in: renderContext.groups,
            inlineFeedbackIDs: [feedback.id],
            draftCommentIDs: [comment.id]
        ) == ["group-0", "group-79"])
    }

    @Test func fileSectionEmbedsDiffPaneWithoutToolbarAndShowsOpenFile() {
        let file = DiffReviewFileSectionModel(
            summary: summary(
                path: "Sources/App/AlphaView.swift",
                namespace: "unstaged",
                groupID: "unstaged",
                groupTitle: "Unstaged",
                additions: 1,
                deletions: 1
            ),
            parsedDiff: parsedDiff(),
            displayModel: displayModel(),
            placeholderMessage: nil,
            openFile: {},
            contextProvider: nil
        )
        var layout = DiffLayoutMode.split
        var wrap = false
        var whitespace = false

        let view = DiffReviewFileSection(
            file: file,
            layoutMode: Binding(get: { layout }, set: { layout = $0 }),
            wrapLines: Binding(get: { wrap }, set: { wrap = $0 }),
            showWhitespace: Binding(get: { whitespace }, set: { whitespace = $0 }),
            codeFontFamily: "",
            codeFontSize: 13,
            showsSourceBadge: true
        )
        .environment(\.theme, theme())

        let controller = host(view, width: 900, height: 500)

        #expect(subview(withAccessibilityIdentifier: "diff-review-file-section-\(file.id.rawValue)", in: controller.view) != nil)
        #expect(allSubviews(of: controller.view).contains { $0 is DiffPaneTextScrollView })
        #expect(subview(withAccessibilityIdentifier: "diff-pane-toolbar", in: controller.view) == nil)
        #expect(DiffReviewFileSectionActions.openFileButtonTitle(for: file) == "Open File")
        #expect(accessibilityLabel(in: controller.view, containing: "UNSTAGED") != nil)
    }

    @Test func fileSectionAcceptsLSPContextWithoutChangingLayout() {
        let file = DiffReviewFileSectionModel(
            summary: summary(path: "Sources/App/AlphaView.swift"),
            parsedDiff: parsedDiff(),
            displayModel: displayModel(),
            placeholderMessage: nil,
            openFile: nil,
            contextProvider: nil
        )
        var layout = DiffLayoutMode.split
        var wrap = false
        var whitespace = false
        let manager = WorkspaceLSPManager(registry: LanguageServerRegistry(userDefined: []))
        let context = DiffPaneLSPContext(
            worktreeId: "worktree-1",
            worktreeRoot: URL(fileURLWithPath: "/tmp/worktree"),
            relativePath: "Sources/App/AlphaView.swift",
            language: "swift",
            lsp: manager,
            openTarget: { _, _, _ in }
        )

        let view = DiffReviewFileSection(
            file: file,
            layoutMode: Binding(get: { layout }, set: { layout = $0 }),
            wrapLines: Binding(get: { wrap }, set: { wrap = $0 }),
            showWhitespace: Binding(get: { whitespace }, set: { whitespace = $0 }),
            codeFontFamily: "SF Mono",
            codeFontSize: 13,
            showsSourceBadge: false,
            lspContext: context
        )
        .environment(\.theme, theme())

        let controller = host(view, width: 900, height: 500)
        let textViews = allSubviews(of: controller.view).compactMap { $0 as? DiffPaneCodeTextView }

        #expect(allSubviews(of: controller.view).contains { $0 is DiffPaneTextScrollView })
        #expect(textViews.contains { $0.hasLSPContextForTesting && $0.allowedLSPSideForTesting == .new })
        #expect(subview(withAccessibilityIdentifier: "diff-pane-toolbar", in: controller.view) == nil)
    }

    @Test func fileSectionRendersFileLevelInlineFeedbackBelowHeader() {
        let file = DiffReviewFileSectionModel(
            summary: summary(path: "Sources/App.swift"),
            parsedDiff: parsedDiff(),
            displayModel: displayModel(),
            placeholderMessage: nil,
            openFile: nil,
            contextProvider: nil
        )
        let feedback = [
            DiffReviewInlineFeedback(
                id: "thread-file",
                providerName: "GitHub",
                author: "reviewer",
                bodyPreview: "Please review this file.",
                status: .actionable,
                providerURL: URL(string: "https://github.com/thread-file")!,
                anchor: DiffReviewInlineFeedbackAnchor(path: "Sources/App.swift", line: nil, side: .unknown),
                evidenceItemID: "thread-file"
            ),
        ]
        var layout = DiffLayoutMode.split
        var wrap = false
        var whitespace = false

        let view = DiffReviewFileSection(
            file: file,
            inlineFeedback: feedback,
            layoutMode: Binding(get: { layout }, set: { layout = $0 }),
            wrapLines: Binding(get: { wrap }, set: { wrap = $0 }),
            showWhitespace: Binding(get: { whitespace }, set: { whitespace = $0 }),
            codeFontFamily: "",
            codeFontSize: 13,
            showsSourceBadge: false
        )
        .environment(\.theme, theme())

        let controller = host(view, width: 900, height: 500)

        #expect(subview(withAccessibilityIdentifier: "diff-review-inline-feedback-thread-file", in: controller.view) != nil)
        #expect(accessibilityLabel(in: controller.view, containing: "GitHub") != nil)
        #expect(accessibilityLabel(in: controller.view, containing: "reviewer") != nil)
        #expect(accessibilityLabel(in: controller.view, containing: "Please review this file.") != nil)
    }

    @Test func fileSectionHighlightsFocusedInlineFeedbackAndShowsAvailableActions() {
        let file = DiffReviewFileSectionModel(
            summary: summary(path: "Sources/App.swift"),
            parsedDiff: parsedDiff(),
            displayModel: displayModel(),
            placeholderMessage: nil,
            openFile: nil,
            contextProvider: nil
        )
        let feedback = DiffReviewInlineFeedback(
            id: "thread-1",
            providerName: "GitHub",
            author: "reviewer",
            bodyPreview: "Please update this.",
            status: .actionable,
            providerURL: URL(string: "https://github.com/thread")!,
            anchor: DiffReviewInlineFeedbackAnchor(path: file.summary.path, line: 2, side: .new),
            evidenceItemID: "thread-1"
        )
        var layout = DiffLayoutMode.split
        var wrap = false
        var whitespace = false
        let actions = DiffReviewInlineFeedbackActions(
            availability: { _, _ in
                DiffReviewInlineFeedbackActionAvailability(
                    canOpenProvider: true,
                    canCopyContext: true,
                    canSendToAgent: false
                )
            },
            openProvider: { _, _ in },
            copyContext: { _, _ in },
            sendToAgent: { _, _ in }
        )

        let view = DiffReviewFileSection(
            file: file,
            inlineFeedback: [feedback],
            focusedFeedbackID: "thread-1",
            layoutMode: Binding(get: { layout }, set: { layout = $0 }),
            wrapLines: Binding(get: { wrap }, set: { wrap = $0 }),
            showWhitespace: Binding(get: { whitespace }, set: { whitespace = $0 }),
            codeFontFamily: "",
            codeFontSize: 13,
            showsSourceBadge: false,
            inlineFeedbackActions: actions,
            onSelectInlineFeedback: { _ in }
        )
        .environment(\.theme, theme())

        let controller = host(view, width: 900, height: 500)

        #expect(subview(withAccessibilityIdentifier: "diff-review-inline-feedback-thread-1", in: controller.view) != nil)
        #expect(subview(withAccessibilityIdentifier: "diff-review-inline-feedback-focused-thread-1", in: controller.view) != nil)
        #expect(subview(withAccessibilityIdentifier: "diff-review-inline-feedback-action-open-thread-1", in: controller.view) != nil)
        #expect(subview(withAccessibilityIdentifier: "diff-review-inline-feedback-action-copy-thread-1", in: controller.view) != nil)
        #expect(subview(withAccessibilityIdentifier: "diff-review-inline-feedback-action-send-thread-1", in: controller.view) == nil)
        #expect(subviews(withAccessibilityIdentifier: "diff-review-inline-feedback-open-thread-1", in: controller.view).count <= 1)
        #expect(subviews(withAccessibilityIdentifier: "diff-review-inline-feedback-copy-thread-1", in: controller.view).count <= 1)
    }

    @Test func providerFeedbackCardShowsReplyResolveAndUnresolveActions() {
        let file = DiffReviewFileSectionModel(
            summary: summary(path: "Sources/App.swift"),
            parsedDiff: parsedDiff(),
            displayModel: displayModel(),
            placeholderMessage: nil,
            openFile: nil,
            contextProvider: nil
        )
        let feedback = DiffReviewInlineFeedback(
            id: "thread-1",
            providerName: "GitHub",
            author: "reviewer",
            bodyPreview: "Please fix this.",
            status: .actionable,
            providerURL: nil,
            anchor: DiffReviewInlineFeedbackAnchor(path: file.summary.path, line: 2, side: .new),
            evidenceItemID: "thread-1"
        )
        var layout = DiffLayoutMode.split
        var wrap = false
        var whitespace = false
        var resolvedID: String?
        var unresolvedID: String?
        var replied: (id: String, body: String)?
        let actions = DiffReviewInlineFeedbackActions(
            availability: { item, _ in
                DiffReviewInlineFeedbackActionAvailability(
                    canOpenProvider: false,
                    canCopyContext: false,
                    canSendToAgent: false,
                    canReplyProvider: true,
                    canResolveProvider: item.status != .resolved,
                    canUnresolveProvider: item.status == .resolved
                )
            },
            replyProvider: { item, _, body in
                replied = (item.id, body)
            },
            resolveProvider: { item, _ in
                resolvedID = item.id
            },
            unresolveProvider: { item, _ in
                unresolvedID = item.id
            }
        )

        let view = DiffReviewFileSection(
            file: file,
            inlineFeedback: [
                feedback,
                DiffReviewInlineFeedback(
                    id: "thread-2",
                    providerName: "GitHub",
                    author: "reviewer",
                    bodyPreview: "Resolved thread.",
                    status: .resolved,
                    providerURL: nil,
                    anchor: DiffReviewInlineFeedbackAnchor(path: file.summary.path, line: nil, side: .unknown),
                    evidenceItemID: "thread-2"
                ),
            ],
            layoutMode: Binding(get: { layout }, set: { layout = $0 }),
            wrapLines: Binding(get: { wrap }, set: { wrap = $0 }),
            showWhitespace: Binding(get: { whitespace }, set: { whitespace = $0 }),
            codeFontFamily: "",
            codeFontSize: 13,
            showsSourceBadge: false,
            inlineFeedbackActions: actions
        )
        .environment(\.theme, theme())

        let controller = host(view, width: 900, height: 520)

        #expect(subview(withAccessibilityIdentifier: "diff-review-inline-feedback-action-reply-thread-1", in: controller.view) != nil)
        #expect(subview(withAccessibilityIdentifier: "diff-review-inline-feedback-action-resolve-thread-1", in: controller.view) != nil)
        #expect(subview(withAccessibilityIdentifier: "diff-review-inline-feedback-action-unresolve-thread-2", in: controller.view) != nil)
        #expect(pressAccessibilityElement(withAccessibilityIdentifier: "diff-review-inline-feedback-action-resolve-thread-1", in: controller.view))
        #expect(resolvedID == "thread-1")
        #expect(pressAccessibilityElement(withAccessibilityIdentifier: "diff-review-inline-feedback-action-unresolve-thread-2", in: controller.view))
        #expect(unresolvedID == "thread-2")

        var replyEditor = DiffReviewInlineFeedbackReplyEditorState()
        replyEditor.start()
        #expect(replyEditor.isReplying)
        replyEditor.body = "  Done  "
        #expect(replyEditor.save(feedback) { item, body in
            actions.replyProvider(item, file.summary, body)
        })
        #expect(!replyEditor.isReplying)
        #expect(replied?.id == "thread-1")
        #expect(replied?.body == "Done")
    }

    @Test func focusedInlineFeedbackPastDisplayCapRemainsVisibleWithMoreRow() {
        let file = DiffReviewFileSectionModel(
            summary: summary(path: "Sources/App.swift"),
            parsedDiff: parsedDiff(),
            displayModel: displayModel(),
            placeholderMessage: nil,
            openFile: nil,
            contextProvider: nil
        )
        let feedback = inlineFeedbackItems(count: 5, path: file.summary.path, lineAnchored: false)
        var layout = DiffLayoutMode.split
        var wrap = false
        var whitespace = false

        let view = DiffReviewFileSection(
            file: file,
            inlineFeedback: feedback,
            focusedFeedbackID: "thread-5",
            layoutMode: Binding(get: { layout }, set: { layout = $0 }),
            wrapLines: Binding(get: { wrap }, set: { wrap = $0 }),
            showWhitespace: Binding(get: { whitespace }, set: { whitespace = $0 }),
            codeFontFamily: "",
            codeFontSize: 13,
            showsSourceBadge: false
        )
        .environment(\.theme, theme())

        let controller = host(view, width: 900, height: 600)

        #expect(subview(withAccessibilityIdentifier: "diff-review-inline-feedback-thread-1", in: controller.view) != nil)
        #expect(subview(withAccessibilityIdentifier: "diff-review-inline-feedback-thread-2", in: controller.view) != nil)
        #expect(subview(withAccessibilityIdentifier: "diff-review-inline-feedback-thread-3", in: controller.view) != nil)
        #expect(subview(withAccessibilityIdentifier: "diff-review-inline-feedback-thread-4", in: controller.view) == nil)
        #expect(subview(withAccessibilityIdentifier: "diff-review-inline-feedback-thread-5", in: controller.view) != nil)
        #expect(subview(withAccessibilityIdentifier: "diff-review-inline-feedback-focused-thread-5", in: controller.view) != nil)
        #expect(accessibilityLabel(in: controller.view, containing: "+1 more feedback") != nil)
    }

    @Test func inlineFeedbackScrollTargetPastDisplayCapRemainsVisible() {
        let file = DiffReviewFileSectionModel(
            summary: summary(path: "Sources/App.swift"),
            parsedDiff: parsedDiff(),
            displayModel: displayModel(),
            placeholderMessage: nil,
            openFile: nil,
            contextProvider: nil
        )
        let feedback = inlineFeedbackItems(count: 5, path: file.summary.path, lineAnchored: false)
        var layout = DiffLayoutMode.split
        var wrap = false
        var whitespace = false

        let view = DiffReviewFileSection(
            file: file,
            inlineFeedback: feedback,
            inlineFeedbackScrollTargetID: "thread-5",
            layoutMode: Binding(get: { layout }, set: { layout = $0 }),
            wrapLines: Binding(get: { wrap }, set: { wrap = $0 }),
            showWhitespace: Binding(get: { whitespace }, set: { whitespace = $0 }),
            codeFontFamily: "",
            codeFontSize: 13,
            showsSourceBadge: false
        )
        .environment(\.theme, theme())

        let controller = host(view, width: 900, height: 600)

        #expect(subview(withAccessibilityIdentifier: "diff-review-inline-feedback-thread-5", in: controller.view) != nil)
    }

    @Test func inlineFeedbackCardInteractionRoutesSelectionAndActionsIndependently() {
        let feedback = DiffReviewInlineFeedback(
            id: "thread-1",
            providerName: "GitHub",
            author: "reviewer",
            bodyPreview: "Please update this.",
            status: .actionable,
            providerURL: URL(string: "https://github.com/thread")!,
            anchor: DiffReviewInlineFeedbackAnchor(path: "Sources/App.swift", line: 2, side: .new),
            evidenceItemID: "thread-1"
        )
        var selectedFeedbackID: String?
        var openedFeedbackID: String?
        var copiedFeedbackID: String?
        var sentFeedbackID: String?

        DiffReviewInlineFeedbackCardInteraction.open(feedback) {
            openedFeedbackID = $0.id
        }
        DiffReviewInlineFeedbackCardInteraction.copy(feedback) {
            copiedFeedbackID = $0.id
        }
        DiffReviewInlineFeedbackCardInteraction.send(feedback) {
            sentFeedbackID = $0.id
        }

        #expect(selectedFeedbackID == nil)
        #expect(openedFeedbackID == "thread-1")
        #expect(copiedFeedbackID == "thread-1")
        #expect(sentFeedbackID == "thread-1")

        DiffReviewInlineFeedbackCardInteraction.select(feedback) {
            selectedFeedbackID = $0.id
        }

        #expect(selectedFeedbackID == "thread-1")
    }

    @Test func renderWindowKeepsInlineFeedbackScrollTargetFileRendered() {
        let fileScrollTarget = DiffReviewFileID(namespace: "commit", path: "Selected.swift")
        let inlineTarget = DiffReviewFileID(namespace: "commit", path: "InlineTarget.swift")
        let command = DiffReviewInlineFeedbackScrollCommand(
            feedbackID: "thread-inline",
            fileID: inlineTarget,
            generation: 1
        )

        #expect(
            DiffReviewSurfaceSelectionSync.renderedTargetFileID(
                fileScrollTarget: fileScrollTarget,
                inlineFeedbackScrollCommand: nil
            ) == fileScrollTarget
        )
        #expect(
            DiffReviewSurfaceSelectionSync.renderedTargetFileID(
                fileScrollTarget: nil,
                inlineFeedbackScrollCommand: command
            ) == inlineTarget
        )
    }

    @Test func fileSectionCapsInlineFeedbackCardsWithMoreRow() {
        let file = DiffReviewFileSectionModel(
            summary: summary(path: "Sources/App.swift"),
            parsedDiff: parsedDiff(),
            displayModel: displayModel(),
            placeholderMessage: nil,
            openFile: nil,
            contextProvider: nil
        )
        let feedback = inlineFeedbackItems(count: 5, path: file.summary.path, lineAnchored: false)
        var layout = DiffLayoutMode.split
        var wrap = false
        var whitespace = false

        let view = DiffReviewFileSection(
            file: file,
            inlineFeedback: feedback,
            layoutMode: Binding(get: { layout }, set: { layout = $0 }),
            wrapLines: Binding(get: { wrap }, set: { wrap = $0 }),
            showWhitespace: Binding(get: { whitespace }, set: { whitespace = $0 }),
            codeFontFamily: "",
            codeFontSize: 13,
            showsSourceBadge: false
        )
        .environment(\.theme, theme())

        let controller = host(view, width: 900, height: 500)

        #expect(subview(withAccessibilityIdentifier: "diff-review-inline-feedback-thread-1", in: controller.view) != nil)
        #expect(subview(withAccessibilityIdentifier: "diff-review-inline-feedback-thread-2", in: controller.view) != nil)
        #expect(subview(withAccessibilityIdentifier: "diff-review-inline-feedback-thread-3", in: controller.view) != nil)
        #expect(subview(withAccessibilityIdentifier: "diff-review-inline-feedback-thread-4", in: controller.view) == nil)
        #expect(subview(withAccessibilityIdentifier: "diff-review-inline-feedback-thread-5", in: controller.view) == nil)
        #expect(subview(withAccessibilityIdentifier: "diff-review-inline-feedback-more", in: controller.view) != nil)
        #expect(accessibilityLabel(in: controller.view, containing: "+2 more feedback") != nil)
    }

    @Test func inlineFeedbackPlacementGroupsLineAnchoredItemsByMatchingHunk() throws {
        let model = displayModel()
        let firstGroup = try #require(model.groups.first)
        let feedback = [
            DiffReviewInlineFeedback(
                id: "thread-new-line",
                providerName: "GitHub",
                author: "reviewer",
                bodyPreview: "Review this new line.",
                status: .actionable,
                providerURL: nil,
                anchor: DiffReviewInlineFeedbackAnchor(path: "Sources/App.swift", line: 2, side: .new),
                evidenceItemID: "thread-new-line"
            ),
            DiffReviewInlineFeedback(
                id: "thread-file",
                providerName: "GitHub",
                author: "reviewer",
                bodyPreview: "Review the whole file.",
                status: .actionable,
                providerURL: nil,
                anchor: DiffReviewInlineFeedbackAnchor(path: "Sources/App.swift", line: nil, side: .unknown),
                evidenceItemID: "thread-file"
            ),
            DiffReviewInlineFeedback(
                id: "thread-unmatched",
                providerName: "GitHub",
                author: "reviewer",
                bodyPreview: "Review a line outside the diff.",
                status: .actionable,
                providerURL: nil,
                anchor: DiffReviewInlineFeedbackAnchor(path: "Sources/App.swift", line: 42, side: .new),
                evidenceItemID: "thread-unmatched"
            ),
        ]

        let placement = DiffReviewInlineFeedbackPlacement.position(feedback, in: model.groups)

        #expect(placement.byGroupID[firstGroup.id]?.map(\.id) == ["thread-new-line"])
        #expect(placement.fileLevel.map(\.id) == ["thread-file", "thread-unmatched"])
    }

    @Test func renderContextBuilderMatchesExistingPlacementHelpers() throws {
        let model = displayModel()
        let firstGroup = try #require(model.groups.first)
        let fileID = DiffReviewFileID(namespace: "commit", path: model.filePath)
        let lineFeedback = DiffReviewInlineFeedback(
            id: "thread-new-line",
            providerName: "GitHub",
            author: "reviewer",
            bodyPreview: "Review this new line.",
            status: .actionable,
            providerURL: nil,
            anchor: DiffReviewInlineFeedbackAnchor(path: model.filePath, line: 2, side: .new),
            evidenceItemID: "thread-new-line"
        )
        let fileFeedback = DiffReviewInlineFeedback(
            id: "thread-file",
            providerName: "GitHub",
            author: "reviewer",
            bodyPreview: "Review the whole file.",
            status: .actionable,
            providerURL: nil,
            anchor: DiffReviewInlineFeedbackAnchor(path: model.filePath, line: nil, side: .unknown),
            evidenceItemID: "thread-file"
        )
        let draft = draftComment(id: "draft-line", fileID: fileID, path: model.filePath, side: .new, startLine: 2)
        let thread = DiffInlineCommentThread(
            id: "provider-thread",
            filePath: model.filePath,
            newLine: 2,
            isResolved: false,
            isOutdated: false,
            comments: [
                DiffInlineComment(id: "provider-comment", author: "reviewer", body: "Provider comment"),
            ]
        )
        let annotation = DiffInlineAnnotation(
            id: "annotation-new-line",
            checkName: "SwiftLint",
            newLine: 2,
            level: .warning,
            message: "Prefer explicit access control.",
            rawDetails: "Access control details."
        )

        let context = DiffReviewRenderContextBuilder.build(
            fileID: fileID,
            displayModel: model,
            contextSnapshot: nil,
            contextProviderAvailable: false,
            contextExpansion: DiffContextExpansionState(),
            inlineFeedback: [lineFeedback, fileFeedback],
            draftComments: [draft],
            pendingDraftAnchor: nil,
            canCreateDraftComment: true,
            threads: [thread],
            annotations: [annotation]
        )
        let inlinePlacement = DiffReviewInlineFeedbackPlacement.position([lineFeedback, fileFeedback], in: model.groups)
        let draftPlacement = ReviewDraftCommentPlacement.position([draft], in: model.groups)
        let segments = ReviewDraftCommentRowSegmentation.segments(
            for: firstGroup,
            placement: draftPlacement,
            pendingAnchor: nil,
            canCreateDraftComment: true
        )
        let expectedBlocks = DiffInlineCommentLayout.blocks(
            visibleRows: try #require(segments.items.first).rows,
            threads: [thread],
            annotations: [annotation]
        )

        #expect(context.groups.map(\.displayGroup) == model.groups)
        #expect(context.fileLevelInlineFeedback == inlinePlacement.fileLevel)
        #expect(context.inlineFeedbackByGroupID == inlinePlacement.byGroupID)
        #expect(context.fileLevelDraftComments == draftPlacement.fileLevel)
        #expect(context.draftPlacement == draftPlacement)
        #expect(context.group(id: firstGroup.id)?.segments.map(\.id) == segments.items.map(\.id))
        #expect(context.group(id: firstGroup.id)?.segments.flatMap(\.draftComments) == [draft])
        #expect(context.group(id: firstGroup.id)?.segments.first?.blocks == expectedBlocks)
        #expect(context.groupData[firstGroup.id] == context.group(id: firstGroup.id))
    }

    @Test func renderContextCacheReusesSameKeyWithoutRebuilding() {
        let model = displayModel()
        let fileID = DiffReviewFileID(namespace: "commit", path: model.filePath)
        let key = DiffReviewRenderContextKey(
            fileID: fileID,
            displayModel: model,
            contextSnapshot: nil,
            contextProviderAvailable: false,
            contextExpansion: DiffContextExpansionState(),
            inlineFeedback: [],
            draftComments: [],
            pendingDraftAnchor: nil,
            canCreateDraftComment: true,
            threads: [],
            annotations: []
        )
        let cache = DiffReviewRenderContextCache(limit: 2)
        var buildCount = 0

        _ = cache.context(key: key) {
            buildCount += 1
            return DiffReviewRenderContextBuilder.build(
                fileID: fileID,
                displayModel: model,
                contextSnapshot: nil,
                contextProviderAvailable: false,
                contextExpansion: DiffContextExpansionState(),
                inlineFeedback: [],
                draftComments: [],
                pendingDraftAnchor: nil,
                canCreateDraftComment: true,
                threads: [],
                annotations: []
            )
        }
        _ = cache.context(key: key) {
            buildCount += 1
            return DiffReviewRenderContextBuilder.build(
                fileID: fileID,
                displayModel: model,
                contextSnapshot: nil,
                contextProviderAvailable: false,
                contextExpansion: DiffContextExpansionState(),
                inlineFeedback: [],
                draftComments: [],
                pendingDraftAnchor: nil,
                canCreateDraftComment: true,
                threads: [],
                annotations: []
            )
        }

        #expect(buildCount == 1)
        #expect(cache.missCountForTests == 1)
    }

    @Test func renderContextKeyChangesForPlacementInputsButNotPresentationInputs() {
        let model = displayModel()
        let fileID = DiffReviewFileID(namespace: "commit", path: model.filePath)
        let baseKey = DiffReviewRenderContextKey(
            fileID: fileID,
            displayModel: model,
            contextSnapshot: nil,
            contextProviderAvailable: false,
            contextExpansion: DiffContextExpansionState(),
            inlineFeedback: [],
            draftComments: [],
            pendingDraftAnchor: nil,
            canCreateDraftComment: true,
            threads: [],
            annotations: []
        )
        let equalKey = DiffReviewRenderContextKey(
            fileID: fileID,
            displayModel: model,
            contextSnapshot: nil,
            contextProviderAvailable: false,
            contextExpansion: DiffContextExpansionState(),
            inlineFeedback: [],
            draftComments: [],
            pendingDraftAnchor: nil,
            canCreateDraftComment: true,
            threads: [],
            annotations: []
        )
        let draftKey = DiffReviewRenderContextKey(
            fileID: fileID,
            displayModel: model,
            contextSnapshot: nil,
            contextProviderAvailable: false,
            contextExpansion: DiffContextExpansionState(),
            inlineFeedback: [],
            draftComments: [
                draftComment(id: "draft-line", fileID: fileID, path: model.filePath, side: .new, startLine: 2),
            ],
            pendingDraftAnchor: nil,
            canCreateDraftComment: true,
            threads: [],
            annotations: []
        )
        let pendingKey = DiffReviewRenderContextKey(
            fileID: fileID,
            displayModel: model,
            contextSnapshot: nil,
            contextProviderAvailable: false,
            contextExpansion: DiffContextExpansionState(),
            inlineFeedback: [],
            draftComments: [],
            pendingDraftAnchor: DiffReviewLineAnchor(
                path: model.filePath,
                side: .new,
                line: 2,
                rowIndex: 1,
                selectedText: "let b = 3"
            ),
            canCreateDraftComment: true,
            threads: [],
            annotations: []
        )
        let feedback = DiffReviewInlineFeedback(
            id: "feedback",
            providerName: "GitHub",
            author: "reviewer",
            bodyPreview: "Review this.",
            status: .actionable,
            providerURL: nil,
            anchor: DiffReviewInlineFeedbackAnchor(path: model.filePath, line: 2, side: .new),
            evidenceItemID: "feedback"
        )
        let feedbackKey = DiffReviewRenderContextKey(
            fileID: fileID,
            displayModel: model,
            contextSnapshot: nil,
            contextProviderAvailable: false,
            contextExpansion: DiffContextExpansionState(),
            inlineFeedback: [feedback],
            draftComments: [],
            pendingDraftAnchor: nil,
            canCreateDraftComment: true,
            threads: [],
            annotations: []
        )
        let feedbackURLKey = DiffReviewRenderContextKey(
            fileID: fileID,
            displayModel: model,
            contextSnapshot: nil,
            contextProviderAvailable: false,
            contextExpansion: DiffContextExpansionState(),
            inlineFeedback: [
                DiffReviewInlineFeedback(
                    id: feedback.id,
                    providerName: feedback.providerName,
                    author: feedback.author,
                    bodyPreview: feedback.bodyPreview,
                    status: feedback.status,
                    providerURL: URL(string: "https://example.com/review"),
                    anchor: feedback.anchor,
                    evidenceItemID: feedback.evidenceItemID
                ),
            ],
            draftComments: [],
            pendingDraftAnchor: nil,
            canCreateDraftComment: true,
            threads: [],
            annotations: []
        )
        var draftWithDifferentSelection = draftComment(
            id: "draft-line",
            fileID: fileID,
            path: model.filePath,
            side: .new,
            startLine: 2
        )
        draftWithDifferentSelection.selectedText = "let changed = 4"
        let draftSelectionKey = DiffReviewRenderContextKey(
            fileID: fileID,
            displayModel: model,
            contextSnapshot: nil,
            contextProviderAvailable: false,
            contextExpansion: DiffContextExpansionState(),
            inlineFeedback: [],
            draftComments: [draftWithDifferentSelection],
            pendingDraftAnchor: nil,
            canCreateDraftComment: true,
            threads: [],
            annotations: []
        )
        var draftWithDifferentCreationDate = draftWithDifferentSelection
        draftWithDifferentCreationDate.selectedText = "let b = 3"
        draftWithDifferentCreationDate.createdAt = Date(timeIntervalSince1970: 3)
        let draftCreatedAtKey = DiffReviewRenderContextKey(
            fileID: fileID,
            displayModel: model,
            contextSnapshot: nil,
            contextProviderAvailable: false,
            contextExpansion: DiffContextExpansionState(),
            inlineFeedback: [],
            draftComments: [draftWithDifferentCreationDate],
            pendingDraftAnchor: nil,
            canCreateDraftComment: true,
            threads: [],
            annotations: []
        )
        let singleLineThread = DiffInlineCommentThread(
            id: "thread",
            filePath: model.filePath,
            newLine: 2,
            startLine: nil,
            isResolved: false,
            isOutdated: false,
            comments: []
        )
        let multiLineThread = DiffInlineCommentThread(
            id: singleLineThread.id,
            filePath: singleLineThread.filePath,
            newLine: singleLineThread.newLine,
            startLine: 1,
            isResolved: singleLineThread.isResolved,
            isOutdated: singleLineThread.isOutdated,
            comments: singleLineThread.comments,
            viewerCanReply: singleLineThread.viewerCanReply,
            viewerCanResolve: singleLineThread.viewerCanResolve,
            viewerCanUnresolve: singleLineThread.viewerCanUnresolve
        )
        let singleLineThreadKey = DiffReviewRenderContextKey(
            fileID: fileID,
            displayModel: model,
            contextSnapshot: nil,
            contextProviderAvailable: false,
            contextExpansion: DiffContextExpansionState(),
            inlineFeedback: [],
            draftComments: [],
            pendingDraftAnchor: nil,
            canCreateDraftComment: true,
            threads: [singleLineThread],
            annotations: []
        )
        let multiLineThreadKey = DiffReviewRenderContextKey(
            fileID: fileID,
            displayModel: model,
            contextSnapshot: nil,
            contextProviderAvailable: false,
            contextExpansion: DiffContextExpansionState(),
            inlineFeedback: [],
            draftComments: [],
            pendingDraftAnchor: nil,
            canCreateDraftComment: true,
            threads: [multiLineThread],
            annotations: []
        )

        #expect(baseKey == equalKey)
        #expect(baseKey != draftKey)
        #expect(baseKey != pendingKey)
        #expect(feedbackKey != feedbackURLKey)
        #expect(draftKey != draftSelectionKey)
        #expect(draftKey != draftCreatedAtKey)
        #expect(singleLineThreadKey != multiLineThreadKey)
    }

    @Test func renderContextKeyChangesWhenExpandedContextTextChangesWithSameLineCount() {
        let model = displayModel()
        let fileID = DiffReviewFileID(namespace: "commit", path: model.filePath)
        var expansion = DiffContextExpansionState()
        expansion.expand(
            DiffContextExpansionKey(groupID: model.groups[0].id, boundary: .below),
            available: 1,
            mode: .chunk(size: 1)
        )
        let firstSnapshot = DiffReviewFileContextSnapshot(
            old: .available(["let a = 1", "let b = 2", "let c = 3"]),
            new: .available(["let a = 1", "let b = 3", "let c = 3"])
        )
        let secondSnapshot = DiffReviewFileContextSnapshot(
            old: .available(["let a = 1", "let b = 2", "let renamed = 3"]),
            new: .available(["let a = 1", "let b = 3", "let renamed = 3"])
        )

        let firstKey = DiffReviewRenderContextKey(
            fileID: fileID,
            displayModel: model,
            contextSnapshot: firstSnapshot,
            contextProviderAvailable: true,
            contextExpansion: expansion,
            inlineFeedback: [],
            draftComments: [],
            pendingDraftAnchor: nil,
            canCreateDraftComment: true,
            threads: [],
            annotations: []
        )
        let secondKey = DiffReviewRenderContextKey(
            fileID: fileID,
            displayModel: model,
            contextSnapshot: secondSnapshot,
            contextProviderAvailable: true,
            contextExpansion: expansion,
            inlineFeedback: [],
            draftComments: [],
            pendingDraftAnchor: nil,
            canCreateDraftComment: true,
            threads: [],
            annotations: []
        )

        #expect(firstKey != secondKey)
    }

    @Test func localDraftCommentsPositionAtExactMatchingRows() throws {
        let model = displayModel()
        let comment = draftComment(id: "draft-line", path: "A.swift", side: .new, startLine: 2)

        let placement = ReviewDraftCommentPlacement.position([comment], in: model.groups)

        #expect(
            placement.byRowAnchor[ReviewDraftCommentPlacement.RowKey(side: .new, line: 2)]?.map(\.id) == ["draft-line"]
        )
        #expect(placement.fileLevel.isEmpty)
    }

    @Test func unmatchedLocalDraftCommentsFallBackToFileLevel() {
        let model = displayModel()
        let comment = draftComment(id: "draft-unmatched", path: "A.swift", side: .new, startLine: 99)

        let placement = ReviewDraftCommentPlacement.position([comment], in: model.groups)

        #expect(placement.byRowAnchor.isEmpty)
        #expect(placement.fileLevel.map(\.id) == ["draft-unmatched"])
    }

    @Test func localDraftCommentsSegmentSameHunkByExactRow() throws {
        let model = displayModel()
        let group = try #require(model.groups.first)
        let firstLine = draftComment(id: "draft-first", path: "A.swift", side: .new, startLine: 1)
        let secondLine = draftComment(id: "draft-second", path: "A.swift", side: .new, startLine: 2)
        let placement = ReviewDraftCommentPlacement.position([secondLine, firstLine], in: model.groups)

        let segments = ReviewDraftCommentRowSegmentation.segments(
            for: group,
            placement: placement,
            pendingAnchor: nil
        )

        #expect(segments.items.count == 2)
        #expect(segments.items[0].rows.map(\.id) == [group.rows[0].id])
        #expect(segments.items[0].draftComments.map(\.id) == ["draft-first"])
        #expect(segments.items[1].rows.map(\.id) == [group.rows[1].id])
        #expect(segments.items[1].draftComments.map(\.id) == ["draft-second"])
    }

    @Test func pendingMultilineDraftComposerUsesRangeEndRow() throws {
        let model = displayModel()
        let group = try #require(model.groups.first)
        let pendingAnchor = DiffReviewLineAnchor(
            path: "A.swift",
            side: .new,
            line: 1,
            endLine: 2,
            rowIndex: 0,
            selectedText: "line 1\nline 2"
        )

        let segments = ReviewDraftCommentRowSegmentation.segments(
            for: group,
            placement: ReviewDraftCommentPlacement.position([], in: model.groups),
            pendingAnchor: pendingAnchor
        )

        #expect(segments.items.count == 1)
        #expect(segments.items[0].showsComposer)
        #expect(segments.items[0].rows.map(\.id) == [group.rows[0].id, group.rows[1].id])
    }

    @Test func pendingMixedSideDraftComposerUsesSingleNewSideInsertionRow() throws {
        let contextRow = DiffDisplayRow(
            id: "context-row",
            kind: .context,
            old: diffLine(id: "old-1", side: .old, oldLine: 1, text: "let a = 1"),
            new: diffLine(id: "new-1", side: .new, newLine: 1, text: "let a = 1"),
            collapsedLineCount: 0
        )
        let deletedRow = DiffDisplayRow(
            id: "deleted-row",
            kind: .delete,
            old: diffLine(id: "old-2", side: .old, oldLine: 2, text: "let b = 2"),
            new: nil,
            collapsedLineCount: 0
        )
        let addedRow = DiffDisplayRow(
            id: "added-row",
            kind: .add,
            old: nil,
            new: diffLine(id: "new-2", side: .new, newLine: 2, text: "let b = 3"),
            collapsedLineCount: 0
        )
        let group = DiffDisplayGroup(
            id: "group",
            header: "@@ -1,2 +1,2 @@",
            sourceHunk: parsedDiff().hunks[0],
            rows: [contextRow, deletedRow, addedRow]
        )
        let pendingAnchor = DiffReviewLineAnchor(
            path: "A.swift",
            side: .unknown,
            line: 2,
            endLine: 2,
            rowIndex: 1,
            endRowIndex: 2,
            selectedLines: [
                DiffReviewLineAnchor.SelectedLine(side: .old, line: 2, isChange: true),
                DiffReviewLineAnchor.SelectedLine(side: .new, line: 2, isChange: true),
            ],
            selectedText: "let b = 2\nlet b = 3"
        )

        let segments = ReviewDraftCommentRowSegmentation.segments(
            for: group,
            placement: ReviewDraftCommentPlacement.position([], in: [group]),
            pendingAnchor: pendingAnchor
        )

        #expect(segments.items.count == 1)
        #expect(segments.items[0].showsComposer)
        #expect(segments.items[0].rows.map { $0.id } == ["context-row", "deleted-row", "added-row"])
    }

    @Test func pendingReplacementDraftComposerDoesNotUseFollowingDisplayRow() throws {
        let replacementRow = DiffDisplayRow(
            id: "replacement-row",
            kind: .replacement,
            old: diffLine(id: "old-1", side: .old, oldLine: 1, text: "let value = 1", kind: .delete),
            new: diffLine(id: "new-1", side: .new, newLine: 1, text: "let value = 2", kind: .add),
            collapsedLineCount: 0
        )
        let followingRow = DiffDisplayRow(
            id: "following-row",
            kind: .context,
            old: diffLine(id: "old-2", side: .old, oldLine: 2, text: "return value"),
            new: diffLine(id: "new-2", side: .new, newLine: 2, text: "return value"),
            collapsedLineCount: 0
        )
        let group = DiffDisplayGroup(
            id: "group",
            header: "@@ -1,2 +1,2 @@",
            sourceHunk: parsedDiff().hunks[0],
            rows: [replacementRow, followingRow]
        )
        let pendingAnchor = DiffReviewLineAnchor(
            path: "A.swift",
            side: .unknown,
            line: 1,
            endLine: 1,
            rowIndex: 0,
            endRowIndex: 1,
            selectedLines: [
                DiffReviewLineAnchor.SelectedLine(side: .old, line: 1, isChange: true),
                DiffReviewLineAnchor.SelectedLine(side: .new, line: 1, isChange: true),
            ],
            selectedText: "let value = 1\nlet value = 2"
        )

        let canonicalAnchor = ReviewDraftCommentRowSegmentation.canonicalPendingAnchor(pendingAnchor, in: [group])
        let segments = ReviewDraftCommentRowSegmentation.segments(
            for: group,
            placement: ReviewDraftCommentPlacement.position([], in: [group]),
            pendingAnchor: pendingAnchor
        )

        #expect(canonicalAnchor.side == .new)
        #expect(canonicalAnchor.line == 1)
        #expect(canonicalAnchor.endLine == nil)
        #expect(segments.items.count == 2)
        #expect(segments.items[0].showsComposer)
        #expect(segments.items[0].rows.map { $0.id } == ["replacement-row"])
    }

    @Test func pendingContextAndDeletionDraftComposerUsesDeletedLine() throws {
        let contextRow = DiffDisplayRow(
            id: "context-row",
            kind: .context,
            old: diffLine(id: "old-10", side: .old, oldLine: 10, text: "let value = 1"),
            new: diffLine(id: "new-10", side: .new, newLine: 10, text: "let value = 1"),
            collapsedLineCount: 0
        )
        let deletedRow = DiffDisplayRow(
            id: "deleted-row",
            kind: .delete,
            old: diffLine(id: "old-11", side: .old, oldLine: 11, text: "print(value)", kind: .delete),
            new: nil,
            collapsedLineCount: 0
        )
        let group = DiffDisplayGroup(
            id: "group",
            header: "@@ -10,2 +10,1 @@",
            sourceHunk: parsedDiff().hunks[0],
            rows: [contextRow, deletedRow]
        )
        let pendingAnchor = DiffReviewLineAnchor(
            path: "A.swift",
            side: .unknown,
            line: 10,
            endLine: 11,
            rowIndex: 0,
            endRowIndex: 1,
            selectedLines: [
                DiffReviewLineAnchor.SelectedLine(side: .unknown, line: 10, isChange: false),
                DiffReviewLineAnchor.SelectedLine(side: .old, line: 11, isChange: true),
            ],
            selectedText: "let value = 1\nprint(value)"
        )

        let canonicalAnchor = ReviewDraftCommentRowSegmentation.canonicalPendingAnchor(pendingAnchor, in: [group])
        let segments = ReviewDraftCommentRowSegmentation.segments(
            for: group,
            placement: ReviewDraftCommentPlacement.position([], in: [group]),
            pendingAnchor: pendingAnchor
        )

        #expect(canonicalAnchor.side == .old)
        #expect(canonicalAnchor.line == 11)
        #expect(canonicalAnchor.endLine == nil)
        #expect(segments.items.count == 1)
        #expect(segments.items[0].showsComposer)
        #expect(segments.items[0].rows.map { $0.id } == ["context-row", "deleted-row"])
    }

    @Test func pendingContextOnlyDraftComposerUsesUnknownInsertionRow() throws {
        let contextRow = DiffDisplayRow(
            id: "context-row",
            kind: .context,
            old: diffLine(id: "old-10", side: .old, oldLine: 10, text: "let value = 1"),
            new: diffLine(id: "new-10", side: .new, newLine: 10, text: "let value = 1"),
            collapsedLineCount: 0
        )
        let group = DiffDisplayGroup(
            id: "group",
            header: "@@ -10,1 +10,1 @@",
            sourceHunk: parsedDiff().hunks[0],
            rows: [contextRow]
        )
        let pendingAnchor = DiffReviewLineAnchor(
            path: "A.swift",
            side: .unknown,
            line: 10,
            endLine: nil,
            rowIndex: 0,
            selectedLines: [
                DiffReviewLineAnchor.SelectedLine(side: .unknown, line: 10, isChange: false),
            ],
            selectedText: "let value = 1"
        )

        let canonicalAnchor = ReviewDraftCommentRowSegmentation.canonicalPendingAnchor(pendingAnchor, in: [group])
        let segments = ReviewDraftCommentRowSegmentation.segments(
            for: group,
            placement: ReviewDraftCommentPlacement.position([], in: [group]),
            pendingAnchor: pendingAnchor
        )

        #expect(canonicalAnchor.side == .unknown)
        #expect(canonicalAnchor.line == 10)
        #expect(segments.items.count == 1)
        #expect(segments.items[0].showsComposer)
        #expect(segments.items[0].rows.map { $0.id } == ["context-row"])
    }

    @Test func localDraftCommentsOnCollapsedRowsAttachToCollapsedParent() throws {
        let hiddenLine = diffLine(
            id: "hidden-new",
            side: .new,
            newLine: 12,
            text: "let hidden = true"
        )
        let collapsedParent = DiffDisplayRow(
            id: "collapsed-parent",
            kind: .collapsed,
            old: nil,
            new: nil,
            collapsedLineCount: 1,
            collapsedRows: [
                DiffDisplayRow(
                    id: "hidden-row",
                    kind: .context,
                    old: nil,
                    new: hiddenLine,
                    collapsedLineCount: 0
                ),
            ]
        )
        let group = DiffDisplayGroup(
            id: "group",
            header: "@@ -10,3 +10,3 @@",
            sourceHunk: parsedDiff().hunks[0],
            rows: [collapsedParent]
        )
        let comment = draftComment(id: "draft-collapsed", path: "A.swift", side: .new, startLine: 12)

        let placement = ReviewDraftCommentPlacement.position([comment], in: [group])
        let segments = ReviewDraftCommentRowSegmentation.segments(
            for: group,
            placement: placement,
            pendingAnchor: nil
        )

        #expect(placement.fileLevel.isEmpty)
        #expect(placement.byRowAnchor[ReviewDraftCommentPlacement.RowKey(side: .new, line: 12)]?.map(\.id) == ["draft-collapsed"])
        #expect(segments.items.count == 1)
        #expect(segments.items[0].rows.map(\.id) == ["collapsed-parent"])
        #expect(segments.items[0].draftComments.map(\.id) == ["draft-collapsed"])
    }

    @Test func draftPlacementIndexesCollapsedChildRows() {
        let line = diffLine(id: "old-hidden", side: .old, oldLine: 7, text: "let old = true")
        let row = DiffDisplayRow(
            id: "collapsed-parent",
            kind: .collapsed,
            old: nil,
            new: nil,
            collapsedLineCount: 1,
            collapsedRows: [
                DiffDisplayRow(
                    id: "old-hidden-row",
                    kind: .context,
                    old: line,
                    new: nil,
                    collapsedLineCount: 0
                ),
            ]
        )

        #expect(ReviewDraftCommentPlacement.visibleRowKeys(in: row).isEmpty)
        #expect(ReviewDraftCommentPlacement.allRowKeys(in: row) == [
            ReviewDraftCommentPlacement.RowKey(side: .old, line: 7),
            ReviewDraftCommentPlacement.RowKey(side: .unknown, line: 7),
        ])
    }

    @Test func localDraftCommentsWithUnknownSideMatchContextRows() throws {
        let model = displayModel()
        let comment = draftComment(id: "draft-unknown", path: "A.swift", side: .unknown, startLine: 1)

        let placement = ReviewDraftCommentPlacement.position([comment], in: model.groups)
        let segments = ReviewDraftCommentRowSegmentation.segments(
            for: try #require(model.groups.first),
            placement: placement,
            pendingAnchor: nil
        )

        #expect(placement.fileLevel.isEmpty)
        #expect(
            placement.byRowAnchor[ReviewDraftCommentPlacement.RowKey(side: .unknown, line: 1)]?.map(\.id)
                == ["draft-unknown"]
        )
        #expect(segments.items.first?.draftComments.map(\.id) == ["draft-unknown"])
    }

    @Test func localDraftCommentsWithUnknownSideDoNotDuplicateAcrossShiftedContextRows() {
        let firstRow = DiffDisplayRow(
            id: "row-1",
            kind: .context,
            old: diffLine(id: "old-1", side: .old, oldLine: 1, text: "one", rowIndex: 0),
            new: diffLine(id: "new-2", side: .new, newLine: 2, text: "two", rowIndex: 0),
            collapsedLineCount: 0
        )
        let secondRow = DiffDisplayRow(
            id: "row-2",
            kind: .context,
            old: diffLine(id: "old-2", side: .old, oldLine: 2, text: "two", rowIndex: 1),
            new: diffLine(id: "new-3", side: .new, newLine: 3, text: "three", rowIndex: 1),
            collapsedLineCount: 0
        )
        let group = DiffDisplayGroup(
            id: "group",
            header: "@@ -1,2 +2,2 @@",
            sourceHunk: parsedDiff().hunks[0],
            rows: [firstRow, secondRow]
        )
        let comment = draftComment(id: "draft-shifted", path: "A.swift", side: .unknown, startLine: 2)

        let placement = ReviewDraftCommentPlacement.position([comment], in: [group])
        let segments = ReviewDraftCommentRowSegmentation.segments(
            for: group,
            placement: placement,
            pendingAnchor: nil
        )

        #expect(segments.items.flatMap(\.draftComments).map(\.id) == ["draft-shifted"])
    }

    @Test func pendingUnknownDraftComposerDoesNotDuplicateAcrossShiftedContextRows() {
        let firstRow = DiffDisplayRow(
            id: "row-1",
            kind: .context,
            old: diffLine(id: "old-1", side: .old, oldLine: 1, text: "one", rowIndex: 0),
            new: diffLine(id: "new-2", side: .new, newLine: 2, text: "two", rowIndex: 0),
            collapsedLineCount: 0
        )
        let secondRow = DiffDisplayRow(
            id: "row-2",
            kind: .context,
            old: diffLine(id: "old-2", side: .old, oldLine: 2, text: "two", rowIndex: 1),
            new: diffLine(id: "new-3", side: .new, newLine: 3, text: "three", rowIndex: 1),
            collapsedLineCount: 0
        )
        let group = DiffDisplayGroup(
            id: "group",
            header: "@@ -1,2 +2,2 @@",
            sourceHunk: parsedDiff().hunks[0],
            rows: [firstRow, secondRow]
        )
        let pendingAnchor = DiffReviewLineAnchor(
            path: "A.swift",
            side: .unknown,
            line: 2,
            rowIndex: 1,
            selectedLines: [
                DiffReviewLineAnchor.SelectedLine(side: .unknown, line: 2, isChange: false),
            ],
            selectedText: "two"
        )

        let segments = ReviewDraftCommentRowSegmentation.segments(
            for: group,
            placement: ReviewDraftCommentPlacement.position([], in: [group]),
            pendingAnchor: pendingAnchor
        )

        #expect(segments.items.filter(\.showsComposer).count == 1)
        #expect(segments.items.filter(\.showsComposer).first?.rows.map(\.id) == ["row-1", "row-2"])
    }

    @Test func sourceIndexedPendingAnchorMapsSegmentLocalRowsToDisplayRows() {
        let row = DiffDisplayRow(
            id: "row-2",
            kind: .context,
            old: diffLine(id: "old-2", side: .old, oldLine: 2, text: "two", rowIndex: 1),
            new: diffLine(id: "new-3", side: .new, newLine: 3, text: "three", rowIndex: 1),
            collapsedLineCount: 0
        )
        let localAnchor = DiffReviewLineAnchor(
            path: "A.swift",
            side: .unknown,
            line: 2,
            rowIndex: 0,
            selectedLines: [
                DiffReviewLineAnchor.SelectedLine(side: .unknown, line: 2, isChange: false),
            ],
            selectedText: "two"
        )

        let sourceAnchor = ReviewDraftCommentRowSegmentation.sourceIndexedAnchor(localAnchor, in: [row])

        #expect(sourceAnchor.rowIndex == 1)
        #expect(sourceAnchor.endRowIndex == 1)
    }

    @Test func pendingUnknownDraftComposerUsesSourceRowAfterExistingDraftSegment() {
        let firstRow = DiffDisplayRow(
            id: "row-1",
            kind: .context,
            old: diffLine(id: "old-1", side: .old, oldLine: 1, text: "one", rowIndex: 0),
            new: diffLine(id: "new-2", side: .new, newLine: 2, text: "two", rowIndex: 0),
            collapsedLineCount: 0
        )
        let secondRow = DiffDisplayRow(
            id: "row-2",
            kind: .context,
            old: diffLine(id: "old-2", side: .old, oldLine: 2, text: "two", rowIndex: 1),
            new: diffLine(id: "new-3", side: .new, newLine: 3, text: "three", rowIndex: 1),
            collapsedLineCount: 0
        )
        let group = DiffDisplayGroup(
            id: "group",
            header: "@@ -1,2 +2,2 @@",
            sourceHunk: parsedDiff().hunks[0],
            rows: [firstRow, secondRow]
        )
        let localAnchor = DiffReviewLineAnchor(
            path: "A.swift",
            side: .unknown,
            line: 2,
            rowIndex: 0,
            selectedLines: [
                DiffReviewLineAnchor.SelectedLine(side: .unknown, line: 2, isChange: false),
            ],
            selectedText: "two"
        )
        let sourceAnchor = ReviewDraftCommentRowSegmentation.sourceIndexedAnchor(localAnchor, in: [secondRow])
        let placement = ReviewDraftCommentPlacement.position(
            [draftComment(id: "draft-shifted", path: "A.swift", side: .unknown, startLine: 2)],
            in: [group]
        )

        let segments = ReviewDraftCommentRowSegmentation.segments(
            for: group,
            placement: placement,
            pendingAnchor: sourceAnchor
        )

        #expect(segments.items.map(\.rows).map { $0.map(\.id) } == [["row-1"], ["row-2"]])
        #expect(segments.items[0].draftComments.map(\.id) == ["draft-shifted"])
        #expect(segments.items[0].showsComposer == false)
        #expect(segments.items[1].draftComments.isEmpty)
        #expect(segments.items[1].showsComposer)
    }

    @Test func localDraftCommentsWithUnknownSideDoNotDuplicateAcrossMatchingHunks() {
        let firstGroup = DiffDisplayGroup(
            id: "first-group",
            header: "@@ -1,1 +2,1 @@",
            sourceHunk: parsedDiff().hunks[0],
            rows: [
                DiffDisplayRow(
                    id: "first-row",
                    kind: .context,
                    old: diffLine(id: "first-old", side: .old, oldLine: 1, text: "one"),
                    new: diffLine(id: "first-new", side: .new, newLine: 2, text: "two"),
                    collapsedLineCount: 0
                ),
            ]
        )
        let secondGroup = DiffDisplayGroup(
            id: "second-group",
            header: "@@ -2,1 +3,1 @@",
            sourceHunk: parsedDiff().hunks[0],
            rows: [
                DiffDisplayRow(
                    id: "second-row",
                    kind: .context,
                    old: diffLine(id: "second-old", side: .old, oldLine: 2, text: "two"),
                    new: diffLine(id: "second-new", side: .new, newLine: 3, text: "three"),
                    collapsedLineCount: 0
                ),
            ]
        )
        let comment = draftComment(id: "draft-cross-hunk", path: "A.swift", side: .unknown, startLine: 2)
        let placement = ReviewDraftCommentPlacement.position([comment], in: [firstGroup, secondGroup])

        let firstSegments = ReviewDraftCommentRowSegmentation.segments(
            for: firstGroup,
            placement: placement,
            pendingAnchor: nil
        )
        let secondSegments = ReviewDraftCommentRowSegmentation.segments(
            for: secondGroup,
            placement: placement,
            pendingAnchor: nil
        )

        #expect(placement.groupIDByCommentID["draft-cross-hunk"] == "first-group")
        #expect(firstSegments.items.flatMap(\.draftComments).map(\.id) == ["draft-cross-hunk"])
        #expect(secondSegments.items.flatMap(\.draftComments).isEmpty)
    }

    @Test func fileSectionRendersVisibleLocalDraftCommentCard() {
        let file = DiffReviewFileSectionModel(
            summary: summary(path: "Sources/App.swift"),
            parsedDiff: parsedDiff(),
            displayModel: displayModel(),
            placeholderMessage: nil,
            openFile: nil,
            contextProvider: nil
        )
        let comment = draftComment(id: "draft-visible", fileID: file.id, path: file.summary.path, side: .new, startLine: 2)
        var layout = DiffLayoutMode.split
        var wrap = false
        var whitespace = false

        let view = DiffReviewFileSection(
            file: file,
            draftComments: [comment],
            layoutMode: Binding(get: { layout }, set: { layout = $0 }),
            wrapLines: Binding(get: { wrap }, set: { wrap = $0 }),
            showWhitespace: Binding(get: { whitespace }, set: { whitespace = $0 }),
            codeFontFamily: "",
            codeFontSize: 13,
            showsSourceBadge: false
        )
        .environment(\.theme, theme())

        let controller = host(view, width: 900, height: 500)

        #expect(subview(withAccessibilityIdentifier: "diff-review-draft-comment-draft-visible", in: controller.view) != nil)
        #expect(accessibilityLabel(in: controller.view, containing: "Local draft") != nil)
        #expect(accessibilityLabel(in: controller.view, containing: "Please revisit this line.") != nil)
    }

    @Test func fileSectionRenderContextCacheIgnoresPresentationOnlyChanges() {
        let file = DiffReviewFileSectionModel(
            summary: summary(path: "Sources/App.swift"),
            parsedDiff: parsedDiff(),
            displayModel: displayModel(),
            placeholderMessage: nil,
            openFile: nil,
            contextProvider: nil
        )
        let comment = draftComment(id: "draft-visible", fileID: file.id, path: file.summary.path, side: .new, startLine: 2)
        var layout = DiffLayoutMode.split
        var wrap = false
        var whitespace = false
        var cacheMisses = 0

        func makeView() -> some View {
            DiffReviewFileSection(
                file: file,
                draftComments: [comment],
                layoutMode: Binding(get: { layout }, set: { layout = $0 }),
                wrapLines: Binding(get: { wrap }, set: { wrap = $0 }),
                showWhitespace: Binding(get: { whitespace }, set: { whitespace = $0 }),
                codeFontFamily: "",
                codeFontSize: 13,
                showsSourceBadge: false,
                onRenderContextCacheMissForTesting: { cacheMisses += 1 }
            )
            .environment(\.theme, theme())
        }

        let controller = host(makeView(), width: 900, height: 500)
        #expect(cacheMisses == 1)
        #expect(subview(withAccessibilityIdentifier: "diff-review-draft-comment-draft-visible", in: controller.view) != nil)

        wrap = true
        whitespace = true
        layout = .stacked
        controller.rootView = makeView()
        controller.view.layoutSubtreeIfNeeded()

        #expect(cacheMisses == 1)
        #expect(subview(withAccessibilityIdentifier: "diff-review-draft-comment-draft-visible", in: controller.view) != nil)
    }

    @Test func fileSectionCachedRenderContextRendersInlineFeedbackAndDraftComment() {
        let file = DiffReviewFileSectionModel(
            summary: summary(path: "Sources/App.swift"),
            parsedDiff: parsedDiff(),
            displayModel: displayModel(),
            placeholderMessage: nil,
            openFile: nil,
            contextProvider: nil
        )
        let feedback = DiffReviewInlineFeedback(
            id: "thread-cached-inline",
            providerName: "GitHub",
            author: "reviewer",
            bodyPreview: "Review this cached line.",
            status: .actionable,
            providerURL: nil,
            anchor: DiffReviewInlineFeedbackAnchor(path: file.summary.path, line: 2, side: .new),
            evidenceItemID: "thread-cached-inline"
        )
        let comment = draftComment(
            id: "draft-cached-inline",
            fileID: file.id,
            path: file.summary.path,
            side: .new,
            startLine: 2
        )
        var layout = DiffLayoutMode.split
        var wrap = false
        var whitespace = false

        let view = DiffReviewFileSection(
            file: file,
            inlineFeedback: [feedback],
            draftComments: [comment],
            layoutMode: Binding(get: { layout }, set: { layout = $0 }),
            wrapLines: Binding(get: { wrap }, set: { wrap = $0 }),
            showWhitespace: Binding(get: { whitespace }, set: { whitespace = $0 }),
            codeFontFamily: "",
            codeFontSize: 13,
            showsSourceBadge: false
        )
        .environment(\.theme, theme())

        let controller = host(view, width: 900, height: 620)

        #expect(subview(withAccessibilityIdentifier: "diff-review-inline-feedback-thread-cached-inline", in: controller.view) != nil)
        #expect(subview(withAccessibilityIdentifier: "diff-review-draft-comment-draft-cached-inline", in: controller.view) != nil)
    }

    @Test func reviewSurfaceUsesLanesForActionableFeedbackAndDrafts() {
        let file = DiffReviewFileSectionModel(
            summary: summary(path: "Sources/App/AlphaView.swift"),
            parsedDiff: parsedDiff(),
            displayModel: displayModel(),
            placeholderMessage: nil,
            openFile: nil,
            contextProvider: nil
        )
        let feedback = DiffReviewInlineFeedback(
            id: "old-feedback",
            providerName: "GitHub",
            author: "reviewer",
            bodyPreview: "Old-side feedback",
            status: .actionable,
            providerURL: nil,
            anchor: .init(path: file.summary.path, line: 2, side: .old),
            evidenceItemID: "old-feedback"
        )
        let comment = draftComment(
            id: "new-draft",
            fileID: file.id,
            path: file.summary.path,
            side: .new,
            startLine: 2
        )
        var layout = DiffLayoutMode.split
        var wrap = false
        var whitespace = false
        let makeView = {
            DiffReviewFileSection(
                file: file,
                inlineFeedback: [feedback],
                draftComments: [comment],
                layoutMode: Binding(get: { layout }, set: { layout = $0 }),
                wrapLines: Binding(get: { wrap }, set: { wrap = $0 }),
                showWhitespace: Binding(get: { whitespace }, set: { whitespace = $0 }),
                codeFontFamily: "",
                codeFontSize: 13,
                showsSourceBadge: false
            )
            .environment(\.theme, theme())
        }

        let splitController = host(makeView(), width: 900, height: 620)

        #expect(subview(withAccessibilityIdentifier: "diff-feedback-lane-left", in: splitController.view) != nil)
        #expect(subview(withAccessibilityIdentifier: "diff-feedback-lane-right", in: splitController.view) != nil)

        layout = .stacked
        let stackedController = host(makeView(), width: 900, height: 620)

        #expect(subview(withAccessibilityIdentifier: "diff-feedback-lane-full", in: stackedController.view) != nil)
    }

    @Test func fileSectionDraftCommentCardShowsProviderPublishAndErrorState() {
        let file = DiffReviewFileSectionModel(
            summary: summary(path: "Sources/App.swift"),
            parsedDiff: parsedDiff(),
            displayModel: displayModel(),
            placeholderMessage: nil,
            openFile: nil,
            contextProvider: nil
        )
        var published = draftComment(id: "draft-published-inline", fileID: file.id, path: file.summary.path, side: .new, startLine: 2)
        published.providerPublish = ReviewDraftProviderPublish(
            provider: .github,
            host: "github.com",
            repositorySlug: "mrmans0n/alas",
            reviewNumber: 527,
            threadID: "thread-1",
            commentID: "comment-1",
            url: nil,
            publishedAt: Date(timeIntervalSince1970: 3)
        )
        var failed = draftComment(id: "draft-error-inline", fileID: file.id, path: file.summary.path, side: .new, startLine: 2)
        failed.providerError = ReviewDraftProviderError(
            provider: .gitlab,
            message: "Line is no longer commentable.",
            occurredAt: Date(timeIntervalSince1970: 4)
        )
        var layout = DiffLayoutMode.split
        var wrap = false
        var whitespace = false

        let view = DiffReviewFileSection(
            file: file,
            draftComments: [published, failed],
            layoutMode: Binding(get: { layout }, set: { layout = $0 }),
            wrapLines: Binding(get: { wrap }, set: { wrap = $0 }),
            showWhitespace: Binding(get: { whitespace }, set: { whitespace = $0 }),
            codeFontFamily: "",
            codeFontSize: 13,
            showsSourceBadge: false
        )
        .environment(\.theme, theme())

        let controller = host(view, width: 900, height: 620)

        #expect(accessibilityLabel(in: controller.view, containing: "published to GitHub") != nil)
        #expect(accessibilityLabel(in: controller.view, containing: "GitLab error: Line is no longer commentable.") != nil)
    }

    @Test func draftComposerKeyboardShortcutsMapToSaveAndCancel() {
        #expect(ReviewDraftComposerKeyboardAction.resolve(key: "\r", modifiers: [.command]) == .save)
        #expect(ReviewDraftComposerKeyboardAction.resolve(key: "\u{1b}", modifiers: []) == .cancel)
        #expect(ReviewDraftComposerKeyboardAction.resolve(key: "\r", modifiers: []) == nil)
    }

    @Test func gutterCommentAffordanceUsesCompactPlusButton() {
        let rowRect = NSRect(x: 0, y: 10, width: 42, height: 20)
        let plusRect = DiffPaneLineNumberRulerView.reviewAffordanceRect(in: rowRect, ruleThickness: 42)

        #expect(plusRect.width == 16)
        #expect(plusRect.height == 16)
        #expect(plusRect.maxX <= rowRect.maxX - 4)
        #expect(plusRect.midY == rowRect.midY)
    }

    @Test func fileSectionDraftCommentCardCanDismissComment() {
        let file = DiffReviewFileSectionModel(
            summary: summary(path: "Sources/App.swift"),
            parsedDiff: parsedDiff(),
            displayModel: displayModel(),
            placeholderMessage: nil,
            openFile: nil,
            contextProvider: nil
        )
        let comment = draftComment(id: "draft-dismiss-inline", fileID: file.id, path: file.summary.path, side: .new, startLine: 2)
        var layout = DiffLayoutMode.split
        var wrap = false
        var whitespace = false
        var dismissedID: String?
        let actions = ReviewDraftCommentActions(
            availability: { _ in
                ReviewDraftCommentActionAvailability(
                    canEdit: false,
                    canDelete: false,
                    canResolve: false,
                    canDismiss: true,
                    canCopyPrompt: false,
                    canShowSendToAgent: false,
                    canSendToAgent: false
                )
            },
            dismiss: { dismissedID = $0.id }
        )

        let view = DiffReviewFileSection(
            file: file,
            draftComments: [comment],
            layoutMode: Binding(get: { layout }, set: { layout = $0 }),
            wrapLines: Binding(get: { wrap }, set: { wrap = $0 }),
            showWhitespace: Binding(get: { whitespace }, set: { whitespace = $0 }),
            codeFontFamily: "",
            codeFontSize: 13,
            showsSourceBadge: false,
            draftCommentActions: actions
        )
        .environment(\.theme, theme())

        let controller = host(view, width: 900, height: 500)

        #expect(pressAccessibilityElement(
            withAccessibilityIdentifier: "diff-review-draft-comment-action-dismiss-draft-dismiss-inline",
            in: controller.view
        ))
        #expect(dismissedID == "draft-dismiss-inline")
    }

    @Test func fileSectionDraftCommentCardCanPublishProviderComment() {
        let file = DiffReviewFileSectionModel(
            summary: summary(path: "Sources/App.swift"),
            parsedDiff: parsedDiff(),
            displayModel: displayModel(),
            placeholderMessage: nil,
            openFile: nil,
            contextProvider: nil
        )
        let comment = draftComment(id: "draft-publish-inline", fileID: file.id, path: file.summary.path, side: .new, startLine: 2)
        var layout = DiffLayoutMode.split
        var wrap = false
        var whitespace = false
        var publishedID: String?
        let actions = ReviewDraftCommentActions(
            availability: { _ in
                ReviewDraftCommentActionAvailability(
                    canEdit: false,
                    canDelete: false,
                    canResolve: false,
                    canDismiss: false,
                    canCopyPrompt: false,
                    canShowSendToAgent: false,
                    canSendToAgent: false,
                    canPublishProvider: true
                )
            },
            publishProvider: { publishedID = $0.id }
        )

        let view = DiffReviewFileSection(
            file: file,
            draftComments: [comment],
            layoutMode: Binding(get: { layout }, set: { layout = $0 }),
            wrapLines: Binding(get: { wrap }, set: { wrap = $0 }),
            showWhitespace: Binding(get: { whitespace }, set: { whitespace = $0 }),
            codeFontFamily: "",
            codeFontSize: 13,
            showsSourceBadge: false,
            draftCommentActions: actions
        )
        .environment(\.theme, theme())

        let controller = host(view, width: 900, height: 500)

        #expect(pressAccessibilityElement(
            withAccessibilityIdentifier: "diff-review-draft-comment-publish-draft-publish-inline",
            in: controller.view
        ))
        #expect(publishedID == "draft-publish-inline")
    }

    @Test func fileSectionDraftCommentCardUsesProvidedReviewTargetForPromptActions() {
        let file = DiffReviewFileSectionModel(
            summary: summary(path: "Sources/App.swift"),
            parsedDiff: parsedDiff(),
            displayModel: displayModel(),
            placeholderMessage: nil,
            openFile: nil,
            contextProvider: nil
        )
        let target = ReviewFeedbackTarget(
            title: "Review working tree",
            repositoryPath: "/repo",
            providerDescription: "GitHub #123",
            sourceDescription: "Review Changes"
        )
        let comment = draftComment(id: "draft-target-inline", fileID: file.id, path: file.summary.path, side: .new, startLine: 2)
        var layout = DiffLayoutMode.split
        var wrap = false
        var whitespace = false
        let recorder = ReviewBundleActionRecorder()
        let actions = ReviewDraftCommentActions(
            availability: { _ in
                ReviewDraftCommentActionAvailability(
                    canEdit: false,
                    canDelete: false,
                    canResolve: false,
                    canDismiss: false,
                    canCopyPrompt: true,
                    canShowSendToAgent: false,
                    canSendToAgent: false
                )
            },
            copyPrompt: { recorder.copied = $0 }
        )

        let view = DiffReviewFileSection(
            file: file,
            draftComments: [comment],
            layoutMode: Binding(get: { layout }, set: { layout = $0 }),
            wrapLines: Binding(get: { wrap }, set: { wrap = $0 }),
            showWhitespace: Binding(get: { whitespace }, set: { whitespace = $0 }),
            codeFontFamily: "",
            codeFontSize: 13,
            showsSourceBadge: false,
            draftCommentActions: actions,
            reviewFeedbackTarget: target
        )
        .environment(\.theme, theme())

        let controller = host(view, width: 900, height: 500)

        #expect(pressAccessibilityElement(
            withAccessibilityIdentifier: "diff-review-draft-comment-action-copy-draft-target-inline",
            in: controller.view
        ))
        #expect(recorder.copied?.target == target)
        #expect(recorder.copied?.comments == [comment])
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))
        controller.view.layoutSubtreeIfNeeded()
        #expect(accessibilityLabel(in: controller.view, containing: "Copied prompt") != nil)
    }

    @Test func activeCommentResolverPrefersHoveredCardsBeforeFocusedFallbacks() {
        let inlineOverDraft = DiffReviewActiveCommentIDs(
            hoveredDraftCommentID: nil,
            focusedDraftCommentID: "focused-draft",
            hoveredInlineFeedbackID: "hovered-inline",
            focusedFeedbackID: nil,
            activeThreadID: nil
        )
        #expect(inlineOverDraft.orderedCandidates == [
            .inlineFeedback("hovered-inline"),
            .draft("focused-draft"),
        ])

        let threadOverDraft = DiffReviewActiveCommentIDs(
            hoveredDraftCommentID: nil,
            focusedDraftCommentID: "focused-draft",
            hoveredInlineFeedbackID: nil,
            focusedFeedbackID: nil,
            activeThreadID: "active-thread"
        )
        #expect(threadOverDraft.orderedCandidates == [
            .thread("active-thread"),
            .draft("focused-draft"),
        ])
    }

    @Test func commentCardsReportHoverOnlyForHoverPriority() {
        #expect(ReviewDraftCommentCard.reportsHover(isHovered: true, isFocused: false))
        #expect(ReviewDraftCommentCard.reportsHover(isHovered: true, isFocused: true))
        #expect(!ReviewDraftCommentCard.reportsHover(isHovered: false, isFocused: true))
        #expect(!ReviewDraftCommentCard.reportsHover(isHovered: false, isFocused: false))

        #expect(DiffReviewInlineFeedbackCard.reportsHover(isHovered: true, isFocused: false))
        #expect(DiffReviewInlineFeedbackCard.reportsHover(isHovered: true, isFocused: true))
        #expect(!DiffReviewInlineFeedbackCard.reportsHover(isHovered: false, isFocused: true))
        #expect(!DiffReviewInlineFeedbackCard.reportsHover(isHovered: false, isFocused: false))
    }

    @Test func fileSectionDraftCommentCardDoesNotFireDisabledSendAction() {
        let file = DiffReviewFileSectionModel(
            summary: summary(path: "Sources/App.swift"),
            parsedDiff: parsedDiff(),
            displayModel: displayModel(),
            placeholderMessage: nil,
            openFile: nil,
            contextProvider: nil
        )
        let comment = draftComment(
            id: "draft-disabled-send-inline",
            fileID: file.id,
            path: file.summary.path,
            side: .new,
            startLine: 2,
            state: .resolved
        )
        var layout = DiffLayoutMode.split
        var wrap = false
        var whitespace = false
        let actions = ReviewDraftCommentActions(
            availability: { _ in
                ReviewDraftCommentActionAvailability(
                    canEdit: false,
                    canDelete: false,
                    canResolve: false,
                    canDismiss: false,
                    canCopyPrompt: false,
                    canShowSendToAgent: true,
                    canSendToAgent: false
                )
            },
            agentTargets: { [.newChat(agentID: "codex", title: "Codex")] },
            sendToAgent: { _, _ in Issue.record("disabled send action fired") }
        )

        let view = DiffReviewFileSection(
            file: file,
            draftComments: [comment],
            layoutMode: Binding(get: { layout }, set: { layout = $0 }),
            wrapLines: Binding(get: { wrap }, set: { wrap = $0 }),
            showWhitespace: Binding(get: { whitespace }, set: { whitespace = $0 }),
            codeFontFamily: "",
            codeFontSize: 13,
            showsSourceBadge: false,
            draftCommentActions: actions
        )
        .environment(\.theme, theme())

        let controller = host(view, width: 900, height: 500)

        #expect(!pressAccessibilityElement(
            withAccessibilityIdentifier: "diff-review-draft-comment-action-send-draft-disabled-send-inline",
            in: controller.view
        ))
    }

    @Test func fileSectionDraftCommentEditorDoesNotKeepCardSelectionButtonActive() {
        let file = DiffReviewFileSectionModel(
            summary: summary(path: "Sources/App.swift"),
            parsedDiff: parsedDiff(),
            displayModel: displayModel(),
            placeholderMessage: nil,
            openFile: nil,
            contextProvider: nil
        )
        let comment = draftComment(id: "draft-edit-inline", fileID: file.id, path: file.summary.path, side: .new, startLine: 2)
        var layout = DiffLayoutMode.split
        var wrap = false
        var whitespace = false
        var selectedID: String?
        let actions = ReviewDraftCommentActions(
            availability: { _ in
                ReviewDraftCommentActionAvailability(
                    canEdit: true,
                    canDelete: false,
                    canResolve: false,
                    canDismiss: false,
                    canCopyPrompt: false,
                    canShowSendToAgent: false,
                    canSendToAgent: false
                )
            }
        )

        let view = DiffReviewFileSection(
            file: file,
            draftComments: [comment],
            layoutMode: Binding(get: { layout }, set: { layout = $0 }),
            wrapLines: Binding(get: { wrap }, set: { wrap = $0 }),
            showWhitespace: Binding(get: { whitespace }, set: { whitespace = $0 }),
            codeFontFamily: "",
            codeFontSize: 13,
            showsSourceBadge: false,
            draftCommentActions: actions,
            onSelectDraftComment: { selectedID = $0.id }
        )
        .environment(\.theme, theme())

        let controller = host(view, width: 900, height: 500)
        #expect(pressAccessibilityElement(
            withAccessibilityIdentifier: "diff-review-draft-comment-action-edit-draft-edit-inline",
            in: controller.view
        ))
        controller.view.layoutSubtreeIfNeeded()

        #expect(subview(withAccessibilityIdentifier: "diff-review-draft-comment-action-save-draft-edit-inline", in: controller.view) != nil)
        #expect(!pressAccessibilityElement(withAccessibilityIdentifier: "diff-review-draft-comment-select-draft-edit-inline", in: controller.view))
        #expect(selectedID == nil)
    }

    @Test func inlineFeedbackContextFormatterIncludesReviewMetadata() {
        let file = summary(path: "Sources/App.swift")
        let item = DiffReviewInlineFeedback(
            id: "thread-1",
            providerName: "GitHub",
            author: "reviewer",
            bodyPreview: "Please update `configId`.",
            status: .actionable,
            providerURL: URL(string: "https://github.com/org/repo/pull/1#discussion_r1"),
            anchor: DiffReviewInlineFeedbackAnchor(path: "Sources/App.swift", line: 56, side: .new),
            evidenceItemID: "thread-1"
        )

        let context = DiffReviewInlineFeedbackContextFormatter.format(item: item, file: file)

        #expect(context.contains("GitHub feedback"))
        #expect(context.contains("Author: reviewer"))
        #expect(context.contains("File: Sources/App.swift"))
        #expect(context.contains("Line: 56"))
        #expect(context.contains("Side: new"))
        #expect(context.contains("Status: actionable"))
        #expect(context.contains("URL: https://github.com/org/repo/pull/1#discussion_r1"))
        #expect(context.contains("Please update `configId`."))
    }

    @Test func inlineFeedbackContextFormatterIncludesDistinctAnchorPath() {
        let file = summary(path: "Sources/NewApp.swift", originalPath: "Sources/OldApp.swift")
        let item = DiffReviewInlineFeedback(
            id: "thread-rename",
            providerName: "GitHub",
            author: "reviewer",
            bodyPreview: "Check the old-side mapping.",
            status: .actionable,
            providerURL: nil,
            anchor: DiffReviewInlineFeedbackAnchor(path: "Sources/OldApp.swift", line: 12, side: .old),
            evidenceItemID: "thread-rename"
        )

        let context = DiffReviewInlineFeedbackContextFormatter.format(item: item, file: file)

        #expect(context.contains("File: Sources/NewApp.swift"))
        #expect(context.contains("Anchor file: Sources/OldApp.swift"))
        #expect(context.contains("Line: 12"))
        #expect(context.contains("Side: old"))
    }

    @Test func inlineFeedbackScrollCommandAdvancesForRepeatedSelections() {
        let fileID = DiffReviewFileID(namespace: "github-pr", path: "Sources/App.swift")
        var controller = DiffReviewInlineFeedbackScrollController()

        let first = controller.command(feedbackID: "thread-1", fileID: fileID)
        let second = controller.command(feedbackID: "thread-1", fileID: fileID)

        #expect(first.feedbackID == "thread-1")
        #expect(first.fileID == fileID)
        #expect(second.generation == first.generation + 1)
        #expect(second.targetID == DiffReviewInlineFeedbackTargetID(fileID: fileID, feedbackID: "thread-1"))
    }

    @Test func inlineFeedbackTargetIDDoesNotCollideForAmbiguousFlattenedStrings() {
        let firstFileID = DiffReviewFileID(namespace: "github-pr", path: "Sources/App-a")
        let secondFileID = DiffReviewFileID(namespace: "github-pr", path: "Sources/App")

        let first = DiffReviewInlineFeedbackTargetID(fileID: firstFileID, feedbackID: "b")
        let second = DiffReviewInlineFeedbackTargetID(fileID: secondFileID, feedbackID: "a-b")

        #expect("\(firstFileID.rawValue)-b" == "\(secondFileID.rawValue)-a-b")
        #expect(first != second)
    }

    @MainActor
    @Test func inlineFeedbackMarkdownRendersCommonReviewMarkup() throws {
        let rendered = NSAttributedString(
            ACPMarkdownText.inlineMarkdown("Use **bold** and `configId`, then see [docs](https://example.com/docs).")
        )

        #expect(rendered.string == "Use bold and configId, then see docs.")

        let linkRange = (rendered.string as NSString).range(of: "docs")
        try #require(linkRange.location != NSNotFound)
        let url = rendered.attribute(NSAttributedString.Key.link, at: linkRange.location, effectiveRange: nil) as? URL
        #expect(url?.absoluteString == "https://example.com/docs")
    }

    @MainActor
    @Test func inlineFeedbackMarkdownPlainTextStripsDelimitersForAccessibility() {
        let plain = DiffReviewInlineFeedbackMarkdown.plainText("Use **bold** and `configId`.")

        #expect(plain == "Use bold and configId.")
    }

    @MainActor
    @Test func inlineFeedbackMarkdownPlainTextUsesImageAltAndStripsSubscript() {
        let plain = DiffReviewInlineFeedbackMarkdown.plainText(
            "**<sub>![P2 Badge](https://img.shields.io/badge/P2-yellow?style=flat)</sub> Preserve streamed text**"
        )

        #expect(plain == "P2 Badge Preserve streamed text")
    }

    @MainActor
    @Test func inlineFeedbackMarkdownPlainTextNormalizesTableCells() {
        let plain = DiffReviewInlineFeedbackMarkdown.plainText(
            """
            | Priority | Message |
            | --- | --- |
            | <sub>![P2 Badge](https://img.shields.io/badge/P2-yellow?style=flat)</sub> | **Fix** this |
            """
        )

        #expect(plain == "Priority Message P2 Badge Fix this")
    }

    @Test func textDocumentViewClearsInactivePaneLSPContextWhenLayoutChanges() {
        let manager = WorkspaceLSPManager(registry: LanguageServerRegistry(userDefined: []))
        let context = DiffPaneLSPContext(
            worktreeId: "worktree-1",
            worktreeRoot: URL(fileURLWithPath: "/tmp/worktree"),
            relativePath: "Sources/App/AlphaView.swift",
            language: "swift",
            lsp: manager,
            openTarget: { _, _, _ in }
        )
        let container = DiffPaneTextDocumentContainerView(frame: NSRect(x: 0, y: 0, width: 900, height: 500))
        let group = try! #require(displayModel().groups.first)

        container.update(
            group: group,
            expandedCollapsedRowIDs: [],
            layoutMode: .split,
            wrapLines: false,
            showWhitespace: false,
            fileExtension: "swift",
            font: CenterTypography.resolveCodeFont(family: "SF Mono", size: 13),
            theme: theme(),
            lspContext: context
        )
        container.layoutSubtreeIfNeeded()

        let splitTextViews = allSubviews(of: container).compactMap { $0 as? DiffPaneCodeTextView }
        #expect(splitTextViews.filter(\.hasLSPContextForTesting).count == 1)

        container.update(
            group: group,
            expandedCollapsedRowIDs: [],
            layoutMode: .stacked,
            wrapLines: false,
            showWhitespace: false,
            fileExtension: "swift",
            font: CenterTypography.resolveCodeFont(family: "SF Mono", size: 13),
            theme: theme(),
            lspContext: context
        )
        container.layoutSubtreeIfNeeded()

        let stackedTextViews = allSubviews(of: container).compactMap { $0 as? DiffPaneCodeTextView }
        #expect(stackedTextViews.filter(\.hasLSPContextForTesting).count == 1)
    }

    @Test func placeholderSectionsRenderMessageWithoutDiffPane() {
        let file = DiffReviewFileSectionModel(
            summary: summary(path: "Assets/logo.png", status: .modified, isRenderable: false),
            parsedDiff: nil,
            displayModel: nil,
            placeholderMessage: "Binary files are not shown.",
            openFile: nil,
            contextProvider: nil
        )
        var layout = DiffLayoutMode.split
        var wrap = false
        var whitespace = false

        let view = DiffReviewFileSection(
            file: file,
            layoutMode: Binding(get: { layout }, set: { layout = $0 }),
            wrapLines: Binding(get: { wrap }, set: { wrap = $0 }),
            showWhitespace: Binding(get: { whitespace }, set: { whitespace = $0 }),
            codeFontFamily: "",
            codeFontSize: 13,
            showsSourceBadge: true
        )
        .environment(\.theme, theme())

        let controller = host(view, width: 900, height: 260)

        #expect(subview(withAccessibilityIdentifier: "diff-review-file-section-\(file.id.rawValue)", in: controller.view) != nil)
        #expect(accessibilityLabel(in: controller.view, containing: "Binary files are not shown.") != nil)
        #expect(!allSubviews(of: controller.view).contains { $0 is DiffPaneTextScrollView })
    }

    @Test func aggregateBudgetDeferralHidesTextDiffUntilReviewerRequestsIt() {
        let file = DiffReviewFileSectionModel(
            summary: summary(path: "Sources/Deferred.swift"),
            parsedDiff: parsedDiff(),
            displayModel: displayModel(),
            placeholderMessage: nil,
            openFile: nil,
            contextProvider: nil
        )
        var layout = DiffLayoutMode.split
        var wrap = false
        var whitespace = false

        let view = DiffReviewFileSection(
            file: file,
            layoutMode: Binding(get: { layout }, set: { layout = $0 }),
            wrapLines: Binding(get: { wrap }, set: { wrap = $0 }),
            showWhitespace: Binding(get: { whitespace }, set: { whitespace = $0 }),
            codeFontFamily: "",
            codeFontSize: 13,
            showsSourceBadge: true,
            automaticallyRendersDiff: false
        )
        .environment(\.theme, theme())

        let controller = host(view, width: 900, height: 260)

        #expect(subview(
            withAccessibilityIdentifier: "diff-review-aggregate-budget-\(file.id.rawValue)",
            in: controller.view
        ) != nil)
        #expect(!allSubviews(of: controller.view).contains { $0 is DiffPaneTextScrollView })

        #expect(pressAccessibilityElement(
            withAccessibilityIdentifier: "diff-review-show-full-diff-\(file.id.rawValue)",
            in: controller.view
        ))
        controller.view.layoutSubtreeIfNeeded()

        #expect(allSubviews(of: controller.view).contains { $0 is DiffPaneTextScrollView })
    }

    @Test func surfaceRepairsInvalidSelectedIDToFirstSessionFile() {
        let first = summary(path: "Sources/App/AlphaView.swift")
        let second = summary(path: "Tests/BetaTests.swift")
        let loaded = loadedSession(summaries: [first, second])
        var selected: DiffReviewFileID? = DiffReviewFileID(namespace: "commit", path: "Missing.swift")
        var collapsed = false
        var layout = DiffLayoutMode.split
        var wrap = false
        var whitespace = false

        let view = DiffReviewSurface(
            session: loaded,
            selectedFileID: Binding(get: { selected }, set: { selected = $0 }),
            railCollapsed: Binding(get: { collapsed }, set: { collapsed = $0 }),
            layoutMode: Binding(get: { layout }, set: { layout = $0 }),
            wrapLines: Binding(get: { wrap }, set: { wrap = $0 }),
            showWhitespace: Binding(get: { whitespace }, set: { whitespace = $0 }),
            codeFontFamily: "",
            codeFontSize: 13
        )
        .environment(\.theme, theme())

        _ = host(view, width: 1000, height: 700)
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))

        #expect(selected == first.id)
    }

    @Test func surfacePassesFeedbackToMatchingFileOnly() {
        let first = summary(path: "Sources/App.swift")
        let second = summary(path: "Sources/Other.swift")
        let session = loadedSession(summaries: [first, second])
        let feedback = [
            first.id: [
                DiffReviewInlineFeedback(
                    id: "thread-app",
                    providerName: "GitHub",
                    author: "reviewer",
                    bodyPreview: "App feedback.",
                    status: .actionable,
                    providerURL: nil,
                    anchor: DiffReviewInlineFeedbackAnchor(path: first.path, line: 2, side: .new),
                    evidenceItemID: "thread-app"
                ),
            ],
        ]
        var selected: DiffReviewFileID? = second.id
        var collapsed = false
        var layout = DiffLayoutMode.split
        var wrap = false
        var whitespace = false

        let view = DiffReviewSurface(
            session: session,
            selectedFileID: Binding(get: { selected }, set: { selected = $0 }),
            railCollapsed: Binding(get: { collapsed }, set: { collapsed = $0 }),
            layoutMode: Binding(get: { layout }, set: { layout = $0 }),
            wrapLines: Binding(get: { wrap }, set: { wrap = $0 }),
            showWhitespace: Binding(get: { whitespace }, set: { whitespace = $0 }),
            codeFontFamily: "",
            codeFontSize: 13,
            inlineFeedbackByFileID: feedback
        )
        .environment(\.theme, theme())

        let controller = host(view, width: 1000, height: 700)

        let matchingCards = allSubviews(of: controller.view).filter {
            $0.accessibilityIdentifier() == "diff-review-inline-feedback-thread-app"
        }
        #expect(matchingCards.count == 1)
        #expect(accessibilityLabel(in: controller.view, containing: "line 2") != nil)
        #expect(accessibilityLabel(in: controller.view, containing: "App feedback.") != nil)
    }

    @Test func surfaceShowsDraftSummaryRailAndSelectsDraftComment() throws {
        let file = summary(path: "Sources/App.swift")
        let session = loadedSession(summaries: [file])
        let comment = draftComment(id: "draft-summary", fileID: file.id, path: file.path, side: .new, startLine: 2)
        var selectedFileID: DiffReviewFileID? = file.id
        var railCollapsed = false
        var summaryCollapsed = false
        var layout = DiffLayoutMode.split
        var wrap = false
        var whitespace = false
        var selectedDraftID: String?

        let view = DiffReviewSurface(
            session: session,
            selectedFileID: Binding(get: { selectedFileID }, set: { selectedFileID = $0 }),
            railCollapsed: Binding(get: { railCollapsed }, set: { railCollapsed = $0 }),
            reviewSummaryCollapsed: Binding(get: { summaryCollapsed }, set: { summaryCollapsed = $0 }),
            layoutMode: Binding(get: { layout }, set: { layout = $0 }),
            wrapLines: Binding(get: { wrap }, set: { wrap = $0 }),
            showWhitespace: Binding(get: { whitespace }, set: { whitespace = $0 }),
            codeFontFamily: "",
            codeFontSize: 13,
            draftCommentsByFileID: [file.id: [comment]],
            onSelectDraftComment: { selectedDraftID = $0.id }
        )
        .environment(\.theme, theme())

        let controller = host(view, width: 1200, height: 700)

        #expect(subview(withAccessibilityIdentifier: "review-draft-summary-rail", in: controller.view) != nil)
        let pressed = pressAccessibilityElement(
            withAccessibilityIdentifier: "review-draft-summary-comment-draft-summary",
            in: controller.view
        )

        #expect(pressed)
        #expect(selectedDraftID == "draft-summary")
    }

    @Test func surfaceCanShowDraftSummaryRailBeforeCommentsExist() throws {
        let file = summary(path: "Sources/App.swift")
        let session = loadedSession(summaries: [file])
        var selectedFileID: DiffReviewFileID? = file.id
        var railCollapsed = false
        var summaryCollapsed = false
        var layout = DiffLayoutMode.split
        var wrap = false
        var whitespace = false

        let view = DiffReviewSurface(
            session: session,
            selectedFileID: Binding(get: { selectedFileID }, set: { selectedFileID = $0 }),
            railCollapsed: Binding(get: { railCollapsed }, set: { railCollapsed = $0 }),
            reviewSummaryCollapsed: Binding(get: { summaryCollapsed }, set: { summaryCollapsed = $0 }),
            layoutMode: Binding(get: { layout }, set: { layout = $0 }),
            wrapLines: Binding(get: { wrap }, set: { wrap = $0 }),
            showWhitespace: Binding(get: { whitespace }, set: { whitespace = $0 }),
            codeFontFamily: "",
            codeFontSize: 13,
            showsDraftSummaryRail: true
        )
        .environment(\.theme, theme())

        let controller = host(view, width: 1200, height: 700)

        #expect(subview(withAccessibilityIdentifier: "review-draft-summary-rail", in: controller.view) != nil)
    }

    @Test func surfaceKeepsDraftSummaryRailWhenOnlyDismissedCommentsRemain() throws {
        let file = summary(path: "Sources/App.swift")
        let session = loadedSession(summaries: [file])
        let comment = draftComment(id: "draft-dismissed-only", fileID: file.id, path: file.path, side: .new, startLine: 2, state: .dismissed)
        var selectedFileID: DiffReviewFileID? = file.id
        var railCollapsed = false
        var summaryCollapsed = false
        var layout = DiffLayoutMode.split
        var wrap = false
        var whitespace = false

        let view = DiffReviewSurface(
            session: session,
            selectedFileID: Binding(get: { selectedFileID }, set: { selectedFileID = $0 }),
            railCollapsed: Binding(get: { railCollapsed }, set: { railCollapsed = $0 }),
            reviewSummaryCollapsed: Binding(get: { summaryCollapsed }, set: { summaryCollapsed = $0 }),
            layoutMode: Binding(get: { layout }, set: { layout = $0 }),
            wrapLines: Binding(get: { wrap }, set: { wrap = $0 }),
            showWhitespace: Binding(get: { whitespace }, set: { whitespace = $0 }),
            codeFontFamily: "",
            codeFontSize: 13,
            draftCommentsByFileID: [file.id: [comment]]
        )
        .environment(\.theme, theme())

        let controller = host(view, width: 1200, height: 700)

        #expect(subview(withAccessibilityIdentifier: "review-draft-summary-rail", in: controller.view) != nil)
        #expect(accessibilityLabel(in: controller.view, containing: "dismissed") != nil)
    }

    @Test func summaryRailUsesProvidedBundleForCopyAndSendActions() throws {
        let file = summary(path: "Sources/App.swift")
        let comment = draftComment(id: "draft-bundle", fileID: file.id, path: file.path, side: .new, startLine: 2)
        let bundle = ReviewFeedbackBundle(
            target: ReviewFeedbackTarget(
                title: "Review Sources/App.swift",
                repositoryPath: "/repo",
                providerDescription: nil,
                sourceDescription: "Local draft comments"
            ),
            comments: [comment]
        )
        var collapsed = false
        let recorder = ReviewBundleActionRecorder()
        let actions = ReviewDraftCommentActions(
            availability: { _ in
                ReviewDraftCommentActionAvailability(
                    canEdit: false,
                    canDelete: false,
                    canResolve: false,
                    canDismiss: false,
                    canCopyPrompt: true,
                    canShowSendToAgent: true,
                    canSendToAgent: true
                )
            },
            copyPrompt: { recorder.copied = $0 },
            agentTargets: { [.newChat(agentID: "codex", title: "Codex")] },
            sendToAgent: { bundle, target in
                recorder.sent = bundle
                recorder.sentTarget = target
            }
        )

        let view = ReviewDraftSummaryRail(
            comments: [comment],
            bundle: bundle,
            collapsed: Binding(get: { collapsed }, set: { collapsed = $0 }),
            draftCommentActions: actions,
            onSelectDraftComment: { _ in }
        )
        .environment(\.theme, theme())

        let controller = host(view, width: 280, height: 500)
        #expect(pressAccessibilityElement(withAccessibilityIdentifier: "review-draft-summary-copy-prompt", in: controller.view))
        #expect(pressAccessibilityElement(withAccessibilityIdentifier: "review-draft-summary-send-agent", in: controller.view))

        #expect(recorder.copied == bundle)
        #expect(recorder.sent == bundle)
        #expect(recorder.sentTarget == .newChat(agentID: "codex", title: "Codex"))
    }

    @Test func summaryRailCanPublishReview() throws {
        let file = summary(path: "Sources/App.swift")
        let comment = draftComment(id: "draft-publish-summary", fileID: file.id, path: file.path, side: .new, startLine: 2)
        let bundle = ReviewFeedbackBundle(
            target: ReviewFeedbackTarget(
                title: "Review provider request",
                repositoryPath: "/repo",
                providerDescription: "GitHub #527",
                sourceDescription: "Provider review"
            ),
            comments: [comment]
        )
        var collapsed = false
        var didPublish = false
        let actions = ReviewDraftCommentActions(
            availability: { _ in .none },
            canPublishReview: { true },
            publishReview: { didPublish = true }
        )

        let view = ReviewDraftSummaryRail(
            comments: [comment],
            bundle: bundle,
            collapsed: Binding(get: { collapsed }, set: { collapsed = $0 }),
            draftCommentActions: actions,
            onSelectDraftComment: { _ in }
        )
        .environment(\.theme, theme())

        let controller = host(view, width: 280, height: 500)

        #expect(pressAccessibilityElement(withAccessibilityIdentifier: "review-draft-summary-publish-review", in: controller.view))
        #expect(didPublish)
    }

    @Test func summaryRailHidesSendActionWhenNoAgentTargetExists() throws {
        let file = summary(path: "Sources/App.swift")
        let comment = draftComment(id: "draft-disabled-actions", fileID: file.id, path: file.path, side: .new, startLine: 2)
        let bundle = ReviewFeedbackBundle(
            target: ReviewFeedbackTarget(
                title: "Review Sources/App.swift",
                repositoryPath: "/repo",
                providerDescription: nil,
                sourceDescription: "Local draft comments"
            ),
            comments: [comment]
        )
        var collapsed = false
        let actions = ReviewDraftCommentActions(
            availability: { _ in .none },
            copyPrompt: { _ in Issue.record("disabled copy action fired") },
            agentTargets: { [] },
            sendToAgent: { _, _ in Issue.record("hidden send action fired") }
        )

        let view = ReviewDraftSummaryRail(
            comments: [comment],
            bundle: bundle,
            collapsed: Binding(get: { collapsed }, set: { collapsed = $0 }),
            draftCommentActions: actions,
            onSelectDraftComment: { _ in }
        )
        .environment(\.theme, theme())

        let controller = host(view, width: 280, height: 500)

        #expect(!pressAccessibilityElement(withAccessibilityIdentifier: "review-draft-summary-copy-prompt", in: controller.view))
        #expect(subview(withAccessibilityIdentifier: "review-draft-summary-send-agent", in: controller.view) == nil)
    }

    @Test func summaryRailCanDismissDraftComment() throws {
        let file = summary(path: "Sources/App.swift")
        let comment = draftComment(id: "draft-dismiss-summary", fileID: file.id, path: file.path, side: .new, startLine: 2)
        let bundle = ReviewFeedbackBundle(
            target: ReviewFeedbackTarget(
                title: "Review Sources/App.swift",
                repositoryPath: "/repo",
                providerDescription: nil,
                sourceDescription: "Local draft comments"
            ),
            comments: [comment]
        )
        var collapsed = false
        var dismissedID: String?
        let actions = ReviewDraftCommentActions(
            availability: { _ in
                ReviewDraftCommentActionAvailability(
                    canEdit: false,
                    canDelete: false,
                    canResolve: false,
                    canDismiss: true,
                    canCopyPrompt: false,
                    canShowSendToAgent: false,
                    canSendToAgent: false
                )
            },
            dismiss: { dismissedID = $0.id }
        )

        let view = ReviewDraftSummaryRail(
            comments: [comment],
            bundle: bundle,
            collapsed: Binding(get: { collapsed }, set: { collapsed = $0 }),
            draftCommentActions: actions,
            onSelectDraftComment: { _ in }
        )
        .environment(\.theme, theme())

        let controller = host(view, width: 280, height: 500)

        #expect(pressAccessibilityElement(
            withAccessibilityIdentifier: "review-draft-summary-dismiss-draft-dismiss-summary",
            in: controller.view
        ))
        #expect(dismissedID == "draft-dismiss-summary")
    }

    @Test func summaryRailEditorDoesNotKeepCardSelectionPressActive() throws {
        let file = summary(path: "Sources/App.swift")
        let comment = draftComment(id: "draft-edit-summary", fileID: file.id, path: file.path, side: .new, startLine: 2)
        let bundle = ReviewFeedbackBundle(
            target: ReviewFeedbackTarget(
                title: "Review Sources/App.swift",
                repositoryPath: "/repo",
                providerDescription: nil,
                sourceDescription: "Local draft comments"
            ),
            comments: [comment]
        )
        var collapsed = false
        var selectedID: String?
        let actions = ReviewDraftCommentActions(
            availability: { _ in
                ReviewDraftCommentActionAvailability(
                    canEdit: true,
                    canDelete: false,
                    canResolve: false,
                    canDismiss: false,
                    canCopyPrompt: false,
                    canShowSendToAgent: false,
                    canSendToAgent: false
                )
            }
        )

        let view = ReviewDraftSummaryRail(
            comments: [comment],
            bundle: bundle,
            collapsed: Binding(get: { collapsed }, set: { collapsed = $0 }),
            draftCommentActions: actions,
            onSelectDraftComment: { selectedID = $0.id }
        )
        .environment(\.theme, theme())

        let controller = host(view, width: 280, height: 500)
        #expect(pressAccessibilityElement(
            withAccessibilityIdentifier: "review-draft-summary-edit-draft-edit-summary",
            in: controller.view
        ))
        controller.view.layoutSubtreeIfNeeded()

        #expect(subview(withAccessibilityIdentifier: "review-draft-summary-save-draft-edit-summary", in: controller.view) != nil)
        #expect(!pressAccessibilityElement(withAccessibilityIdentifier: "review-draft-summary-comment-draft-edit-summary", in: controller.view))
        #expect(selectedID == nil)
    }

    @Test func summaryRailShowsDismissedCommentsWithSideAndStatus() throws {
        let file = summary(path: "Sources/App.swift")
        let comment = draftComment(
            id: "draft-dismissed-visible",
            fileID: file.id,
            path: file.path,
            side: .old,
            startLine: 7,
            state: .dismissed
        )
        let bundle = ReviewFeedbackBundle(
            target: ReviewFeedbackTarget(
                title: "Review Sources/App.swift",
                repositoryPath: "/repo",
                providerDescription: nil,
                sourceDescription: "Local draft comments"
            ),
            comments: [comment]
        )
        var collapsed = false

        let view = ReviewDraftSummaryRail(
            comments: [comment],
            bundle: bundle,
            collapsed: Binding(get: { collapsed }, set: { collapsed = $0 }),
            draftCommentActions: ReviewDraftCommentActions(),
            onSelectDraftComment: { _ in }
        )
        .environment(\.theme, theme())

        let controller = host(view, width: 280, height: 500)

        #expect(subview(withAccessibilityIdentifier: "review-draft-summary-comment-draft-dismissed-visible", in: controller.view) != nil)
        #expect(accessibilityLabel(in: controller.view, containing: "old line 7") != nil)
        #expect(accessibilityLabel(in: controller.view, containing: "dismissed") != nil)
    }

    @Test func summaryRailShowsProviderPublishAndErrorState() throws {
        let file = summary(path: "Sources/App.swift")
        var published = draftComment(id: "draft-published-summary", fileID: file.id, path: file.path, side: .new, startLine: 2)
        published.providerPublish = ReviewDraftProviderPublish(
            provider: .github,
            host: "github.com",
            repositorySlug: "mrmans0n/alas",
            reviewNumber: 527,
            threadID: "thread-1",
            commentID: "comment-1",
            url: nil,
            publishedAt: Date(timeIntervalSince1970: 3)
        )
        var failed = draftComment(id: "draft-error-summary", fileID: file.id, path: file.path, side: .new, startLine: 2)
        failed.providerError = ReviewDraftProviderError(
            provider: .gitlab,
            message: "Line is no longer commentable.",
            occurredAt: Date(timeIntervalSince1970: 4)
        )
        let bundle = ReviewFeedbackBundle(
            target: ReviewFeedbackTarget(
                title: "Review Sources/App.swift",
                repositoryPath: "/repo",
                providerDescription: nil,
                sourceDescription: "Local draft comments"
            ),
            comments: [published, failed]
        )
        var collapsed = false

        let view = ReviewDraftSummaryRail(
            comments: [published, failed],
            bundle: bundle,
            collapsed: Binding(get: { collapsed }, set: { collapsed = $0 }),
            draftCommentActions: ReviewDraftCommentActions(),
            onSelectDraftComment: { _ in }
        )
        .environment(\.theme, theme())

        let controller = host(view, width: 280, height: 520)

        #expect(accessibilityLabel(in: controller.view, containing: "published to GitHub") != nil)
        #expect(accessibilityLabel(in: controller.view, containing: "GitLab error: Line is no longer commentable.") != nil)
    }

    @Test func collapsedSummaryRailKeepsFinishActionsAccessible() throws {
        let file = summary(path: "Sources/App.swift")
        let comment = draftComment(id: "draft-collapsed", fileID: file.id, path: file.path, side: .new, startLine: 2)
        let bundle = ReviewFeedbackBundle(
            target: ReviewFeedbackTarget(
                title: "Review Sources/App.swift",
                repositoryPath: "/repo",
                providerDescription: nil,
                sourceDescription: "Local draft comments"
            ),
            comments: [comment]
        )
        var collapsed = true
        let recorder = ReviewBundleActionRecorder()
        let actions = ReviewDraftCommentActions(
            availability: { _ in
                ReviewDraftCommentActionAvailability(
                    canEdit: false,
                    canDelete: false,
                    canResolve: false,
                    canDismiss: false,
                    canCopyPrompt: true,
                    canShowSendToAgent: true,
                    canSendToAgent: true
                )
            },
            copyPrompt: { recorder.copied = $0 },
            agentTargets: { [.newChat(agentID: "codex", title: "Codex")] },
            sendToAgent: { bundle, target in
                recorder.sent = bundle
                recorder.sentTarget = target
            }
        )

        let view = ReviewDraftSummaryRail(
            comments: [comment],
            bundle: bundle,
            collapsed: Binding(get: { collapsed }, set: { collapsed = $0 }),
            draftCommentActions: actions,
            onSelectDraftComment: { _ in }
        )
        .environment(\.theme, theme())

        let controller = host(view, width: 80, height: 500)
        #expect(pressAccessibilityElement(withAccessibilityIdentifier: "review-draft-summary-copy-prompt", in: controller.view))
        #expect(pressAccessibilityElement(withAccessibilityIdentifier: "review-draft-summary-send-agent", in: controller.view))

        #expect(recorder.copied == bundle)
        #expect(recorder.sent == bundle)
        #expect(recorder.sentTarget == .newChat(agentID: "codex", title: "Codex"))
    }

    @Test func selectionSynchronizationClearsEmptySessions() {
        let selected = DiffReviewFileID(namespace: "commit", path: "Stale.swift")

        let result = DiffReviewSurfaceSelectionSync.synchronizedSelection(
            current: selected,
            fileIDs: []
        )

        #expect(result == nil)
    }

    @Test func selectionSynchronizationRepairsMissingSelection() {
        let first = DiffReviewFileID(namespace: "commit", path: "First.swift")
        let second = DiffReviewFileID(namespace: "commit", path: "Second.swift")
        let missing = DiffReviewFileID(namespace: "commit", path: "Missing.swift")

        let result = DiffReviewSurfaceSelectionSync.synchronizedSelection(
            current: missing,
            fileIDs: [first, second]
        )

        #expect(result == first)
    }

    @Test func sessionFileSetChangesResetProgrammaticScrollSuppression() {
        let first = DiffReviewFileID(namespace: "commit", path: "First.swift")
        let second = DiffReviewFileID(namespace: "commit", path: "Second.swift")
        var controller = DiffReviewProgrammaticScrollController()

        _ = controller.beginProgrammaticScroll(to: first)
        let result = DiffReviewSurfaceSelectionSync.synchronize(
            current: first,
            previousFileSetKey: "commit:First.swift",
            fileIDs: [second],
            programmaticScroll: controller
        )

        #expect(result.selectedFileID == second)
        #expect(result.fileSetKey == DiffReviewSurfaceSelectionSync.fileSetKey(for: [second]))
        #expect(!result.programmaticScroll.isSuppressing)
    }

    @Test func visibleScrollTargetsSelectFirstVisibleTargetInViewportOrder() {
        let first = DiffReviewFileID(namespace: "commit", path: "First.swift")
        let second = DiffReviewFileID(namespace: "commit", path: "Second.swift")
        let third = DiffReviewFileID(namespace: "commit", path: "Third.swift")

        let result = DiffReviewSurfaceSelectionSync.updatedSelectionFromVisibility(
            current: first,
            visibleRawIDs: [
                DiffReviewSurfaceSelectionSync.sectionVisibilityTargetID(for: third),
                DiffReviewSurfaceSelectionSync.sectionVisibilityTargetID(for: second)
            ],
            fileIDs: [first, second, third],
            programmaticScroll: DiffReviewProgrammaticScrollController()
        )

        #expect(result == third)
    }

    @Test func visibleScrollTargetsPreferVisibleFileTopSentinelForHandoff() {
        let first = DiffReviewFileID(namespace: "commit", path: "First.swift")
        let second = DiffReviewFileID(namespace: "commit", path: "Second.swift")

        let result = DiffReviewSurfaceSelectionSync.updatedSelectionFromVisibility(
            current: first,
            visibleRawIDs: [
                DiffReviewSurfaceSelectionSync.sectionVisibilityTargetID(for: first),
                DiffReviewSurfaceSelectionSync.topVisibilityTargetID(for: second),
                DiffReviewSurfaceSelectionSync.sectionVisibilityTargetID(for: second)
            ],
            fileIDs: [first, second],
            programmaticScroll: DiffReviewProgrammaticScrollController()
        )

        #expect(result == second)
    }

    @Test func visibleScrollTargetsKeepCurrentSelectionWhenCurrentFileRemainsVisible() {
        let penultimate = DiffReviewFileID(namespace: "commit", path: "Penultimate.swift")
        let last = DiffReviewFileID(namespace: "commit", path: "Last.swift")

        let result = DiffReviewSurfaceSelectionSync.updatedSelectionFromVisibility(
            current: last,
            visibleRawIDs: [
                DiffReviewSurfaceSelectionSync.sectionVisibilityTargetID(for: penultimate),
                DiffReviewSurfaceSelectionSync.sectionVisibilityTargetID(for: last)
            ],
            fileIDs: [penultimate, last],
            programmaticScroll: DiffReviewProgrammaticScrollController()
        )

        #expect(result == nil)
    }

    @Test func visibleScrollTargetsRespectProgrammaticScrollSuppression() {
        let first = DiffReviewFileID(namespace: "commit", path: "First.swift")
        let second = DiffReviewFileID(namespace: "commit", path: "Second.swift")
        var controller = DiffReviewProgrammaticScrollController()
        _ = controller.beginProgrammaticScroll(to: first)

        let result = DiffReviewSurfaceSelectionSync.updatedSelectionFromVisibility(
            current: first,
            visibleRawIDs: [DiffReviewSurfaceSelectionSync.sectionVisibilityTargetID(for: second)],
            fileIDs: [first, second],
            programmaticScroll: controller
        )

        #expect(result == nil)
    }

    @Test func visibleScrollTargetsUseIntersectionThresholdForOversizedFiles() {
        #expect(DiffReviewSurfaceSelectionSync.visibilityThreshold == 0)
    }

    @Test func initialRestoredNonFirstSelectionRequestsScroll() {
        let first = DiffReviewFileID(namespace: "commit", path: "First.swift")
        let second = DiffReviewFileID(namespace: "commit", path: "Second.swift")

        #expect(
            DiffReviewSurfaceSelectionSync.shouldScrollRestoredSelection(
                previousFileSetKey: nil,
                previousSelection: second,
                selectedFileID: second,
                firstFileID: first
            )
        )
        #expect(
            !DiffReviewSurfaceSelectionSync.shouldScrollRestoredSelection(
                previousFileSetKey: nil,
                previousSelection: first,
                selectedFileID: first,
                firstFileID: first
            )
        )
        #expect(
            !DiffReviewSurfaceSelectionSync.shouldScrollRestoredSelection(
                previousFileSetKey: DiffReviewSurfaceSelectionSync.fileSetKey(for: [first, second]),
                previousSelection: second,
                selectedFileID: second,
                firstFileID: first
            )
        )
    }

    @Test func scrollCommandAdvancesGenerationForRepeatedFileSelections() {
        let file = DiffReviewFileID(namespace: "commit", path: "Sources/App.swift")
        var controller = DiffReviewScrollCommandController()

        let first = controller.command(to: file)
        let second = controller.command(to: file)

        #expect(first.id == file)
        #expect(second.id == file)
        #expect(second.generation == first.generation + 1)
    }

    @Test func scrollCommandConsumptionClearsOnlyConsumedCommand() {
        let file = DiffReviewFileID(namespace: "commit", path: "Sources/App.swift")
        let other = DiffReviewFileID(namespace: "commit", path: "Sources/Other.swift")
        var controller = DiffReviewScrollCommandController()

        let first = controller.command(to: file)
        let second = controller.command(to: other)

        #expect(
            DiffReviewScrollCommandConsumption.consume(
                current: first,
                consumed: first
            ) == nil
        )
        #expect(
            DiffReviewScrollCommandConsumption.consume(
                current: second,
                consumed: first
            ) == second
        )
    }

    @Test func estimatedSectionHeightScalesWithDiffRows() {
        let small = DiffReviewFileSectionModel(
            summary: summary(path: "Sources/Small.swift"),
            parsedDiff: parsedDiff(),
            displayModel: displayModel(),
            placeholderMessage: nil,
            openFile: nil,
            contextProvider: nil
        )
        var largeRows = Array(
            repeating: ParsedDiff.Hunk.Line(kind: .add, text: "let value = 1", oldNumber: nil, newNumber: 1),
            count: 40
        )
        largeRows.insert(.init(kind: .context, text: "let before = 0", oldNumber: 1, newNumber: 1), at: 0)
        let largeDiff = ParsedDiff(hunks: [
            ParsedDiff.Hunk(header: "@@ -1,1 +1,41 @@", oldStart: 1, newStart: 1, lines: largeRows),
        ])
        let large = DiffReviewFileSectionModel(
            summary: summary(path: "Sources/Large.swift", additions: 40),
            parsedDiff: largeDiff,
            displayModel: DiffDisplayModelBuilder.build(diff: largeDiff, filePath: "Sources/Large.swift"),
            placeholderMessage: nil,
            openFile: nil,
            contextProvider: nil
        )

        #expect(DiffReviewFileSectionHeightEstimator.estimatedHeight(for: large) > DiffReviewFileSectionHeightEstimator.estimatedHeight(for: small))
    }

    @Test func estimatedSectionHeightReservesBoundedInlineFeedbackHeight() {
        let file = DiffReviewFileSectionModel(
            summary: summary(path: "Sources/App.swift"),
            parsedDiff: parsedDiff(),
            displayModel: displayModel(),
            placeholderMessage: nil,
            openFile: nil,
            contextProvider: nil
        )

        let noFeedback = DiffReviewFileSectionHeightEstimator.estimatedHeight(for: file, inlineFeedbackCount: 0)
        let oneFeedback = DiffReviewFileSectionHeightEstimator.estimatedHeight(for: file, inlineFeedbackCount: 1)
        let cappedFeedback = DiffReviewFileSectionHeightEstimator.estimatedHeight(for: file, inlineFeedbackCount: 4)
        let manyFeedback = DiffReviewFileSectionHeightEstimator.estimatedHeight(for: file, inlineFeedbackCount: 10)

        #expect(oneFeedback > noFeedback)
        #expect(cappedFeedback > oneFeedback)
        #expect(manyFeedback == cappedFeedback)
    }

    @Test func estimatedSectionHeightGrowsWithInlineFeedbackBodyLength() {
        let file = DiffReviewFileSectionModel(
            summary: summary(path: "Sources/App.swift"),
            parsedDiff: parsedDiff(),
            displayModel: displayModel(),
            placeholderMessage: nil,
            openFile: nil,
            contextProvider: nil
        )
        let shortFeedback = [
            DiffReviewInlineFeedback(
                id: "short",
                providerName: "GitHub",
                author: "reviewer",
                bodyPreview: "Short.",
                status: .actionable,
                providerURL: nil,
                anchor: DiffReviewInlineFeedbackAnchor(path: file.summary.path, line: nil, side: .unknown),
                evidenceItemID: "short"
            ),
        ]
        let longFeedback = [
            DiffReviewInlineFeedback(
                id: "long",
                providerName: "GitHub",
                author: "reviewer",
                bodyPreview: Array(repeating: "This review comment needs to remain fully visible.", count: 12).joined(separator: " "),
                status: .actionable,
                providerURL: nil,
                anchor: DiffReviewInlineFeedbackAnchor(path: file.summary.path, line: nil, side: .unknown),
                evidenceItemID: "long"
            ),
        ]

        #expect(
            DiffReviewFileSectionHeightEstimator.estimatedHeight(for: file, inlineFeedback: longFeedback)
                > DiffReviewFileSectionHeightEstimator.estimatedHeight(for: file, inlineFeedback: shortFeedback)
        )
    }

    @Test func estimatedSectionHeightGrowsWithDraftComments() {
        let file = DiffReviewFileSectionModel(
            summary: summary(path: "Sources/App.swift"),
            parsedDiff: parsedDiff(),
            displayModel: displayModel(),
            placeholderMessage: nil,
            openFile: nil,
            contextProvider: nil
        )
        let comment = draftComment(id: "draft-height", fileID: file.id, path: file.summary.path, side: .new, startLine: 2)

        #expect(
            DiffReviewFileSectionHeightEstimator.estimatedHeight(for: file, inlineFeedback: [], draftComments: [comment])
                > DiffReviewFileSectionHeightEstimator.estimatedHeight(for: file, inlineFeedback: [], draftComments: [])
        )
    }

    @Test func estimatedSectionHeightGrowsWithDraftCommentsOnCollapsedRows() {
        let hiddenLine = diffLine(id: "hidden-new", side: .new, newLine: 12, text: "let hidden = true")
        let collapsedParent = DiffDisplayRow(
            id: "collapsed-parent",
            kind: .collapsed,
            old: nil,
            new: nil,
            collapsedLineCount: 1,
            collapsedRows: [
                DiffDisplayRow(
                    id: "hidden-row",
                    kind: .context,
                    old: nil,
                    new: hiddenLine,
                    collapsedLineCount: 0
                ),
            ]
        )
        let displayModel = DiffDisplayModel(
            filePath: "Sources/App.swift",
            groups: [
                DiffDisplayGroup(
                    id: "group",
                    header: "@@ -10,3 +10,3 @@",
                    sourceHunk: parsedDiff().hunks[0],
                    rows: [collapsedParent]
                ),
            ]
        )
        let file = DiffReviewFileSectionModel(
            summary: summary(path: "Sources/App.swift"),
            parsedDiff: parsedDiff(),
            displayModel: displayModel,
            placeholderMessage: nil,
            openFile: nil,
            contextProvider: nil
        )
        let comment = draftComment(
            id: "draft-collapsed-height",
            fileID: file.id,
            path: file.summary.path,
            side: .new,
            startLine: 12
        )

        #expect(
            DiffReviewFileSectionHeightEstimator.estimatedHeight(for: file, inlineFeedback: [], draftComments: [comment])
                > DiffReviewFileSectionHeightEstimator.estimatedHeight(for: file, inlineFeedback: [], draftComments: [])
        )
    }

    @Test func inlineFeedbackCardEstimateUsesDynamicBodyHeight() {
        let short = DiffReviewInlineFeedback(
            id: "short",
            providerName: "GitHub",
            author: "reviewer",
            bodyPreview: "Short.",
            status: .actionable,
            providerURL: nil,
            anchor: DiffReviewInlineFeedbackAnchor(path: "Sources/App.swift", line: nil, side: .unknown),
            evidenceItemID: "short"
        )
        let long = DiffReviewInlineFeedback(
            id: "long",
            providerName: "GitHub",
            author: "reviewer",
            bodyPreview: Array(repeating: "Long feedback body.", count: 24).joined(separator: " "),
            status: .actionable,
            providerURL: nil,
            anchor: DiffReviewInlineFeedbackAnchor(path: "Sources/App.swift", line: nil, side: .unknown),
            evidenceItemID: "long"
        )

        #expect(DiffReviewInlineFeedbackDisplayPolicy.estimatedCardHeight(for: long) > DiffReviewInlineFeedbackDisplayPolicy.estimatedCardHeight(for: short))
        #expect(DiffReviewInlineFeedbackDisplayPolicy.estimatedCardHeight(for: short) >= DiffReviewInlineFeedbackDisplayPolicy.cardMinimumHeight)
    }

    @Test func summaryRailRendersGitHubFeedbackSection() {
        let fileID = DiffReviewFileID(namespace: "github", path: "Sources/App.swift")
        let feedback = DiffReviewInlineFeedback(
            id: "thread-1",
            providerName: "GitHub",
            author: "reviewer",
            bodyPreview: "Please fix this.",
            status: .actionable,
            providerURL: nil,
            anchor: DiffReviewInlineFeedbackAnchor(path: "Sources/App.swift", line: 2, side: .new),
            evidenceItemID: "thread-1"
        )
        var collapsed = false
        let view = ReviewDraftSummaryRail(
            comments: [],
            bundle: ReviewFeedbackBundle(
                target: ReviewFeedbackTarget(
                    title: "PR",
                    repositoryPath: nil,
                    providerDescription: nil,
                    sourceDescription: "Diff review"
                ),
                comments: []
            ),
            collapsed: Binding(get: { collapsed }, set: { collapsed = $0 }),
            inlineFeedbackByFileID: [fileID: [feedback]]
        )
        .environment(\.theme, theme())

        let controller = host(view, width: 320, height: 500)

        #expect(subview(withAccessibilityIdentifier: "review-summary-feedback-header", in: controller.view) != nil)
        #expect(subview(withAccessibilityIdentifier: "review-summary-feedback-thread-1", in: controller.view) != nil)
        #expect(accessibilityLabel(in: controller.view, containing: "Please fix this.") != nil)
    }

    @Test func summaryRailOmitsGitHubFeedbackSectionWhenEmpty() {
        var collapsed = false
        let view = ReviewDraftSummaryRail(
            comments: [],
            bundle: ReviewFeedbackBundle(
                target: ReviewFeedbackTarget(
                    title: "PR",
                    repositoryPath: nil,
                    providerDescription: nil,
                    sourceDescription: "Diff review"
                ),
                comments: []
            ),
            collapsed: Binding(get: { collapsed }, set: { collapsed = $0 })
        )
        .environment(\.theme, theme())

        let controller = host(view, width: 320, height: 500)

        #expect(subview(withAccessibilityIdentifier: "review-summary-feedback-header", in: controller.view) == nil)
    }

    @Test func surfaceForwardsInlineFeedbackToSummaryRail() throws {
        let file = summary(path: "Sources/App.swift")
        let session = loadedSession(summaries: [file])
        let feedback = DiffReviewInlineFeedback(
            id: "thread-1",
            providerName: "GitHub",
            author: "reviewer",
            bodyPreview: "Please fix this.",
            status: .actionable,
            providerURL: nil,
            anchor: DiffReviewInlineFeedbackAnchor(path: file.path, line: 2, side: .new),
            evidenceItemID: "thread-1"
        )
        var selectedFileID: DiffReviewFileID? = file.id
        var railCollapsed = false
        var summaryCollapsed = false
        var layout = DiffLayoutMode.split
        var wrap = false
        var whitespace = false

        let view = DiffReviewSurface(
            session: session,
            selectedFileID: Binding(get: { selectedFileID }, set: { selectedFileID = $0 }),
            railCollapsed: Binding(get: { railCollapsed }, set: { railCollapsed = $0 }),
            reviewSummaryCollapsed: Binding(get: { summaryCollapsed }, set: { summaryCollapsed = $0 }),
            layoutMode: Binding(get: { layout }, set: { layout = $0 }),
            wrapLines: Binding(get: { wrap }, set: { wrap = $0 }),
            showWhitespace: Binding(get: { whitespace }, set: { whitespace = $0 }),
            codeFontFamily: "",
            codeFontSize: 13,
            showsDraftSummaryRail: true,
            inlineFeedbackByFileID: [file.id: [feedback]]
        )
        .environment(\.theme, theme())

        let controller = host(view, width: 1200, height: 700)

        #expect(subview(withAccessibilityIdentifier: "review-summary-feedback-thread-1", in: controller.view) != nil)
    }

    private func parsedDiff() -> ParsedDiff {
        ParsedDiff(hunks: [
            ParsedDiff.Hunk(
                header: "@@ -1,2 +1,2 @@",
                oldStart: 1,
                newStart: 1,
                lines: [
                    .init(kind: .context, text: "let a = 1", oldNumber: 1, newNumber: 1),
                    .init(kind: .delete, text: "let b = 2", oldNumber: 2, newNumber: nil),
                    .init(kind: .add, text: "let b = 3", oldNumber: nil, newNumber: 2),
                ]
            ),
        ])
    }

    private func displayModel() -> DiffDisplayModel {
        DiffDisplayModelBuilder.build(diff: parsedDiff(), filePath: "Sources/App/AlphaView.swift")
    }

    private func largeDisplayModel(groupCount: Int, filePath: String) -> DiffDisplayModel {
        let sourceHunk = parsedDiff().hunks[0]
        let groups = (0..<groupCount).map { index in
            let line = index + 1
            let displayLine = diffLine(
                id: "line-\(line)",
                side: .new,
                newLine: line,
                text: "let value\(line) = \(line)",
                rowIndex: index
            )
            return DiffDisplayGroup(
                id: "group-\(index)",
                header: "@@ -\(line),1 +\(line),1 @@",
                sourceHunk: sourceHunk,
                rows: [
                    DiffDisplayRow(
                        id: "row-\(line)",
                        kind: .add,
                        old: nil,
                        new: displayLine,
                        collapsedLineCount: 0
                    ),
                ]
            )
        }
        return DiffDisplayModel(filePath: filePath, groups: groups)
    }

    private func largeSingleGroupDisplayModel(rowCount: Int, filePath: String) -> DiffDisplayModel {
        let rows = (0..<rowCount).map { index in
            let line = index + 1
            return DiffDisplayRow(
                id: "row-\(line)",
                kind: .add,
                old: nil,
                new: diffLine(
                    id: "line-\(line)",
                    side: .new,
                    newLine: line,
                    text: "let value\(line) = \(line)",
                    kind: .add,
                    rowIndex: index
                ),
                collapsedLineCount: 0
            )
        }
        let sourceHunk = ParsedDiff.Hunk(
            header: "@@ -0,0 +1,\(rowCount) @@",
            oldStart: 0,
            newStart: 1,
            lines: []
        )
        let group = DiffDisplayGroup(
            id: "large-group",
            header: sourceHunk.header,
            sourceHunk: sourceHunk,
            rows: rows
        )
        return DiffDisplayModel(filePath: filePath, groups: [group])
    }

    private func collapsedContextDisplayModel(filePath: String, hiddenRowCount: Int) -> DiffDisplayModel {
        let hiddenRows = (1...hiddenRowCount).map { line in
            DiffDisplayRow(
                id: "hidden-row-\(line)",
                kind: .context,
                old: nil,
                new: diffLine(
                    id: "hidden-line-\(line)",
                    side: .new,
                    newLine: line,
                    text: "let hidden\(line) = \(line)",
                    rowIndex: line - 1
                ),
                collapsedLineCount: 0
            )
        }
        let collapsed = DiffDisplayRow(
            id: "collapsed-context",
            kind: .collapsed,
            old: nil,
            new: nil,
            collapsedLineCount: hiddenRowCount,
            collapsedRows: hiddenRows
        )
        let changed = DiffDisplayRow(
            id: "visible-change",
            kind: .add,
            old: nil,
            new: diffLine(
                id: "visible-line",
                side: .new,
                newLine: hiddenRowCount + 1,
                text: "let visible = true",
                kind: .add,
                rowIndex: hiddenRowCount
            ),
            collapsedLineCount: 0
        )
        let group = DiffDisplayGroup(
            id: "context-group",
            header: "@@ -1,\(hiddenRowCount + 1) +1,\(hiddenRowCount + 1) @@",
            sourceHunk: parsedDiff().hunks[0],
            rows: [collapsed, changed]
        )
        return DiffDisplayModel(filePath: filePath, groups: [group])
    }

    private func expandedContextDisplayModel(filePath: String, hiddenRowCount: Int) -> DiffDisplayModel {
        let collapsedModel = collapsedContextDisplayModel(filePath: filePath, hiddenRowCount: hiddenRowCount)
        let group = collapsedModel.groups[0]
        let expandedRows = group.rows.flatMap { row in
            row.kind == .collapsed ? [row] + row.collapsedRows : [row]
        }
        return DiffDisplayModel(
            filePath: filePath,
            groups: [
                DiffDisplayGroup(
                    id: group.id,
                    header: group.header,
                    sourceHunk: group.sourceHunk,
                    rows: expandedRows
                ),
            ]
        )
    }

    private func fileSection(
        summary: DiffReviewFileSummary,
        displayModel: DiffDisplayModel?,
        imageProvider: DiffReviewImageProvider? = nil,
        stagedMutationActions: DiffReviewStagedMutationActions? = nil
    ) -> DiffReviewFileSectionModel {
        var file = DiffReviewFileSectionModel(
            summary: summary,
            parsedDiff: displayModel == nil ? nil : parsedDiff(),
            displayModel: displayModel,
            placeholderMessage: displayModel == nil && imageProvider == nil ? "No diff." : nil,
            openFile: nil,
            contextProvider: nil,
            imageProvider: imageProvider
        )
        file.stagedMutationActions = stagedMutationActions
        return file
    }

    private func loadedSession(summaries: [DiffReviewFileSummary]) -> DiffReviewLoadedSession {
        DiffReviewLoadedSession(
            files: summaries.map { summary in
                DiffReviewFileSectionModel(
                    summary: summary,
                    parsedDiff: nil,
                    displayModel: nil,
                    placeholderMessage: "No diff.",
                    openFile: nil,
                    contextProvider: nil
                )
            },
            summary: DiffReviewSessionModel(files: summaries, groupsEnabled: false)
        )
    }

    private func loadedSession(files: [DiffReviewFileSectionModel]) -> DiffReviewLoadedSession {
        DiffReviewLoadedSession(
            files: files,
            summary: DiffReviewSessionModel(files: files.map(\.summary), groupsEnabled: false)
        )
    }

    private func inlineFeedbackItems(
        count: Int,
        path: String,
        lineAnchored: Bool = true
    ) -> [DiffReviewInlineFeedback] {
        (1...count).map { index in
            DiffReviewInlineFeedback(
                id: "thread-\(index)",
                providerName: "GitHub",
                author: "reviewer",
                bodyPreview: "Feedback \(index).",
                status: .actionable,
                providerURL: nil,
                anchor: DiffReviewInlineFeedbackAnchor(
                    path: path,
                    line: lineAnchored ? index : nil,
                    side: lineAnchored ? .new : .unknown
                ),
                evidenceItemID: "thread-\(index)"
            )
        }
    }

    private func draftComment(
        id: String,
        fileID: DiffReviewFileID = DiffReviewFileID(namespace: "commit", path: "A.swift"),
        path: String = "A.swift",
        side: DiffReviewInlineFeedbackSide = .new,
        startLine: Int,
        endLine: Int? = nil,
        state: ReviewDraftCommentState = .active
    ) -> ReviewDraftComment {
        ReviewDraftComment(
            id: id,
            sessionID: .commit(
                worktreeID: "wt",
                repositoryPath: URL(fileURLWithPath: "/repo"),
                sha: "abc123"
            ),
            fileID: fileID,
            path: path,
            originalPath: nil,
            side: side,
            startLine: startLine,
            endLine: endLine,
            selectedText: "let b = 3",
            bodyMarkdown: "Please revisit this line.",
            state: state,
            createdAt: Date(timeIntervalSince1970: 1),
            updatedAt: Date(timeIntervalSince1970: 2)
        )
    }

    private func diffLine(
        id: String,
        side: DiffLineSide,
        oldLine: Int? = nil,
        newLine: Int? = nil,
        text: String,
        kind: ParsedDiff.Hunk.Line.Kind = .context,
        rowIndex: Int = 0
    ) -> DiffDisplayLine {
        DiffDisplayLine(
            id: id,
            anchor: DiffLineAnchor(
                filePath: "A.swift",
                hunkIndex: 0,
                rowIndex: rowIndex,
                side: side,
                oldLine: oldLine,
                newLine: newLine
            ),
            text: text,
            lineNumber: oldLine ?? newLine,
            kind: kind,
            inlineSpans: [],
            noTrailingNewline: false
        )
    }

    private func summary(
        path: String,
        namespace: String = "commit",
        groupID: String? = nil,
        groupTitle: String? = nil,
        status: DiffReviewFileStatus = .modified,
        additions: Int = 1,
        deletions: Int = 0,
        isRenderable: Bool = true,
        originalPath: String? = nil
    ) -> DiffReviewFileSummary {
        DiffReviewFileSummary(
            path: path,
            namespace: namespace,
            groupID: groupID,
            groupTitle: groupTitle,
            status: status,
            additions: additions,
            deletions: deletions,
            isRenderable: isRenderable,
            originalPath: originalPath
        )
    }

    private func host<Content: View>(
        _ view: Content,
        width: CGFloat,
        height: CGFloat
    ) -> NSHostingController<Content> {
        let controller = NSHostingController(rootView: view)
        controller.view.frame = NSRect(x: 0, y: 0, width: width, height: height)
        controller.view.layoutSubtreeIfNeeded()
        return controller
    }

    private func attachWindow<Content: View>(
        _ controller: NSHostingController<Content>,
        width: CGFloat,
        height: CGFloat
    ) -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: width, height: height),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.contentViewController = controller
        controller.view.frame = window.contentView?.bounds ?? NSRect(x: 0, y: 0, width: width, height: height)
        controller.view.layoutSubtreeIfNeeded()
        return window
    }

    private func appKitReviewScroller(in view: NSView) -> AppKitDiffScrollView? {
        allSubviews(of: view).compactMap { $0 as? AppKitDiffScrollView }.first
    }

    private func withAppKitReviewScroller(
        _ body: () async throws -> Void
    ) async rethrows {
        let originalOverride = AppKitDiffScrollerFlag.readOverride(from: .standard)
        defer {
            if let originalOverride {
                AppKitDiffScrollerFlag.setOverride(originalOverride)
            } else {
                UserDefaults.standard.removeObject(forKey: AppKitDiffScrollerFlag.defaultsKey)
                NotificationCenter.default.post(name: AppKitDiffScrollerFlag.overrideDidChangeNotification, object: nil)
            }
        }
        AppKitDiffScrollerFlag.setOverride(true)
        try await body()
    }

    private func drainSwiftUI(_ view: NSView) async {
        for _ in 0..<6 {
            view.layoutSubtreeIfNeeded()
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.001))
            await Task.yield()
        }
    }

    private func allSubviews(of view: NSView) -> [NSView] {
        view.subviews + view.subviews.flatMap { allSubviews(of: $0) }
    }

    private func subview(withAccessibilityIdentifier identifier: String, in view: NSView) -> NSView? {
        if view.accessibilityIdentifier() == identifier {
            return view
        }
        return view.subviews.lazy.compactMap { subview(withAccessibilityIdentifier: identifier, in: $0) }.first
    }

    private func subviews(withAccessibilityIdentifier identifier: String, in view: NSView) -> [NSView] {
        var matches: [NSView] = []
        if view.accessibilityIdentifier() == identifier {
            matches.append(view)
        }
        matches.append(contentsOf: view.subviews.flatMap { subviews(withAccessibilityIdentifier: identifier, in: $0) })
        return matches
    }

    private func pressAccessibilityElement(withAccessibilityIdentifier identifier: String, in view: NSView) -> Bool {
        for match in subviews(withAccessibilityIdentifier: identifier, in: view) {
            if match.accessibilityPerformPress() {
                return true
            }
        }
        return false
    }

    private func pressButton(withToolTip toolTip: String, in view: NSView) -> Bool {
        for button in allSubviews(of: view).compactMap({ $0 as? NSButton })
            where button.toolTip == toolTip || button.accessibilityLabel() == toolTip {
            button.performClick(nil)
            return true
        }
        return false
    }

    private func selectReviewLine(selectionIndex: Int, in view: NSView) throws {
        let selectableRows = allSubviews(of: view)
            .compactMap { $0 as? DiffPaneLineNumberRulerView }
            .filter(\.allowsReviewLineSelection)
            .flatMap { ruler -> [(ruler: DiffPaneLineNumberRulerView, row: Int)] in
                guard let textView = ruler.scrollView?.documentView as? DiffPaneCodeTextView else { return [] }
                return (0..<200).compactMap { row in
                    textView.reviewLineAnchor(atRow: row).map { _ in (ruler, row) }
                }
            }
        let selection = try #require(selectableRows.dropFirst(selectionIndex).first)
        selection.ruler.invokeReviewLineSelectionForTesting(row: selection.row)
    }

    private func draftComposerTextView(in view: NSView) -> NSTextView? {
        allSubviews(of: view).compactMap { subview -> NSTextView? in
            guard let textView = subview as? NSTextView,
                  !(textView is DiffPaneCodeTextView)
            else { return nil }
            return textView
        }.first
    }

    private func accessibilityLabel(in view: NSView, containing text: String) -> String? {
        if let label = view.accessibilityLabel(), label.contains(text) {
            return label
        }
        return view.subviews.lazy.compactMap { accessibilityLabel(in: $0, containing: text) }.first
    }
}

@MainActor
private final class ImagePairLoadGate {
    private var continuation: CheckedContinuation<ImageDiffPair, Never>?

    func wait() async -> ImageDiffPair {
        await withCheckedContinuation { continuation = $0 }
    }

    func resume(returning pair: ImageDiffPair) {
        continuation?.resume(returning: pair)
        continuation = nil
    }
}

@Observable
@MainActor
private final class ImageProviderRemovalModel {
    var file: DiffReviewFileSectionModel

    init(file: DiffReviewFileSectionModel) {
        self.file = file
    }
}

@MainActor
private struct ImageProviderRemovalHarness: View {
    let theme: Theme
    let model: ImageProviderRemovalModel
    @State private var layout = DiffLayoutMode.split
    @State private var wrapLines = false
    @State private var showWhitespace = false

    var body: some View {
        DiffReviewFileSection(
            file: model.file,
            layoutMode: $layout,
            wrapLines: $wrapLines,
            showWhitespace: $showWhitespace,
            codeFontFamily: "",
            codeFontSize: 13,
            showsSourceBadge: false,
            allowsDraftCommentCreation: false
        )
        .environment(\.theme, theme)
    }
}

@MainActor
private final class ReviewDraftComposerFocusRetainer {
    private static var retainedObjects: [AnyObject] = []

    static func retain(_ objects: AnyObject...) {
        retainedObjects.append(contentsOf: objects)
    }
}

@MainActor
private final class ReviewDraftComposerFocusModel: ObservableObject {
    @Published var focusRequestGeneration = 1
}

@MainActor
private struct ReviewDraftComposerFocusHarness: View {
    @State private var text = ""
    @FocusState private var focused: Bool

    let theme: Theme
    @ObservedObject var model: ReviewDraftComposerFocusModel

    var body: some View {
        VStack {
            ReviewDraftComposerTextEditor(
                text: $text,
                theme: theme,
                isFocused: $focused,
                focusRequestGeneration: model.focusRequestGeneration,
                onSave: {},
                onCancel: {}
            )
            .frame(height: 100)

            ReviewDraftComposerFocusSiblingView()

            Button("Request focus") {
                model.focusRequestGeneration += 1
            }
            .accessibilityIdentifier("draft-composer-request-focus")
        }
        .padding()
    }
}

private struct ReviewDraftComposerFocusSiblingView: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = FocusSinkView(frame: NSRect(x: 0, y: 0, width: 40, height: 20))
        view.setAccessibilityIdentifier("draft-composer-focus-sibling")
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
}

private final class FocusSinkView: NSView {
    override var acceptsFirstResponder: Bool { true }
}

@Observable
@MainActor
private final class AppKitReviewSurfaceWindowModel {
    var session: DiffReviewLoadedSession
    var selected: DiffReviewFileID?
    var railCollapsed = false
    var layout = DiffLayoutMode.stacked
    var wrap = false
    var whitespace = false
    var inlineFeedbackByFileID: [DiffReviewFileID: [DiffReviewInlineFeedback]] = [:]
    var draftCommentsByFileID: [DiffReviewFileID: [ReviewDraftComment]] = [:]
    var inlineFeedbackCommand: DiffReviewInlineFeedbackScrollCommand?
    var draftCommentCommand: DiffReviewDraftCommentScrollCommand?

    init(session: DiffReviewLoadedSession) {
        self.session = session
        selected = session.files.first?.id
    }
}

@MainActor
private struct AppKitReviewSurfaceWindowHarness: View {
    let model: AppKitReviewSurfaceWindowModel

    var body: some View {
        DiffReviewSurface(
            session: model.session,
            selectedFileID: Binding(get: { model.selected }, set: { model.selected = $0 }),
            railCollapsed: Binding(get: { model.railCollapsed }, set: { model.railCollapsed = $0 }),
            layoutMode: Binding(get: { model.layout }, set: { model.layout = $0 }),
            wrapLines: Binding(get: { model.wrap }, set: { model.wrap = $0 }),
            showWhitespace: Binding(get: { model.whitespace }, set: { model.whitespace = $0 }),
            codeFontFamily: "",
            codeFontSize: 13,
            inlineFeedbackByFileID: model.inlineFeedbackByFileID,
            inlineFeedbackScrollCommand: model.inlineFeedbackCommand,
            draftCommentsByFileID: model.draftCommentsByFileID,
            draftCommentScrollCommand: model.draftCommentCommand
        )
    }
}

private final class ReviewBundleActionRecorder: @unchecked Sendable {
    var copied: ReviewFeedbackBundle?
    var sent: ReviewFeedbackBundle?
    var sentTarget: ReviewFeedbackAgentTarget?
}

@MainActor
private final class AppKitImageRetryRecorder {
    private(set) var loadCount = 0

    func load() async -> ImageDiffPair {
        loadCount += 1
        return ImageDiffPair(
            before: .failed(.init(message: "Could not decode before image")),
            after: .missing,
            oldPath: nil,
            kind: .deleted
        )
    }
}

@MainActor
private final class AppKitReviewActionRecorder {
    var unstagedFiles = 0
    var unstagedHunks = 0
}
