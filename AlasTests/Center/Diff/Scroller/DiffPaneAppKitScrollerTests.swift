import AppKit
import SwiftUI
import Testing
@testable import Alas

@MainActor
private final class DiffPaneHarnessState: ObservableObject {
    @Published var layout: DiffLayoutMode
    @Published var wrap: Bool
    @Published var whitespace: Bool

    init(layout: DiffLayoutMode, wrap: Bool, whitespace: Bool) {
        self.layout = layout
        self.wrap = wrap
        self.whitespace = whitespace
    }
}

private struct DiffPaneHarness: View {
    @ObservedObject var state: DiffPaneHarnessState
    let model: DiffDisplayModel
    let theme: Theme
    var onReviewLineSelected: (DiffReviewLineAnchor) -> Void = { _ in }

    var body: some View {
        DiffPaneView(
            model: model,
            fileExtension: "swift",
            layoutMode: $state.layout,
            wrapLines: $state.wrap,
            showWhitespace: $state.whitespace,
            codeFontFamily: "",
            codeFontSize: 13,
            showsToolbar: false,
            onReviewLineSelected: onReviewLineSelected,
            hunkActions: { _ in DiffPaneHunkActions(stage: {}, discard: {}) }
        )
        .environment(\.theme, theme)
    }
}

@MainActor
private final class DiffPaneHarnessRetainer {
    private static var retainedObjects: [AnyObject] = []

    static func retain(_ objects: AnyObject...) {
        retainedObjects.append(contentsOf: objects)
    }
}

@MainActor
@Suite("Standalone AppKit diff scroller", .serialized)
struct DiffPaneAppKitScrollerTests {
    private func theme() -> Theme { try! ThemeStore().current }

    private func model(
        groupCount: Int = 1,
        includesCollapsedContext: Bool = false,
        sourceMarker: String = "let a = 1"
    ) -> DiffDisplayModel {
        let lines: [ParsedDiff.Hunk.Line] = includesCollapsedContext
            ? (1...15).map { (index: Int) in
                .init(kind: .context, text: "let value\(index) = \(index)", oldNumber: index, newNumber: index)
            }
            : [
                .init(kind: .context, text: sourceMarker, oldNumber: 1, newNumber: 1),
                .init(kind: .delete, text: "let b = 2", oldNumber: 2, newNumber: nil),
                .init(kind: .add, text: "let b = 3", oldNumber: nil, newNumber: 2),
            ]
        let diff = ParsedDiff(hunks: (0..<groupCount).map { index in
            .init(
                header: "@@ -\(index + 1),2 +\(index + 1),2 @@",
                oldStart: index + 1,
                newStart: index + 1,
                lines: lines
            )
        })
        return DiffDisplayModelBuilder.build(diff: diff, filePath: "Sources/App.swift")
    }

    private func pane(
        model: DiffDisplayModel,
        layout: Binding<DiffLayoutMode>,
        wrap: Binding<Bool>,
        whitespace: Binding<Bool>,
        onReviewLineSelected: @escaping (DiffReviewLineAnchor) -> Void = { _ in }
    ) -> some View {
        DiffPaneView(
            model: model,
            fileExtension: "swift",
            layoutMode: layout,
            wrapLines: wrap,
            showWhitespace: whitespace,
            codeFontFamily: "",
            codeFontSize: 13,
            showsToolbar: false,
            onReviewLineSelected: onReviewLineSelected,
            hunkActions: { _ in DiffPaneHunkActions(stage: {}, discard: {}) }
        )
        .environment(\.theme, theme())
    }

    private func mount<Content: View>(_ content: Content) -> (NSWindow, NSHostingController<Content>) {
        let controller = NSHostingController(rootView: content)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 480),
            styleMask: [.titled], backing: .buffered, defer: false
        )
        window.animationBehavior = .none
        window.contentView = controller.view
        window.makeKeyAndOrderFront(nil)
        controller.view.layoutSubtreeIfNeeded()
        return (window, controller)
    }

    private func allSubviews(of view: NSView) -> [NSView] {
        [view] + view.subviews.flatMap(allSubviews)
    }

    private func appKitScroller(in view: NSView) -> AppKitDiffScrollView? {
        allSubviews(of: view).compactMap { $0 as? AppKitDiffScrollView }.first
    }

    private func visibleTextScrollViews(in view: NSView) -> [DiffPaneTextScrollView] {
        allSubviews(of: view)
            .compactMap { $0 as? DiffPaneTextScrollView }
            .filter { !$0.isHidden }
    }

    private func renderedText(in view: NSView) -> [String] {
        allSubviews(of: view)
            .compactMap { ($0 as? NSTextView)?.string }
            .filter { !$0.isEmpty }
    }

    private func settle(_ view: NSView) {
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        view.layoutSubtreeIfNeeded()
    }

    @Test("only internally scrolling panes switch to AppKit")
    func switchContract() {
        #expect(DiffPaneView.usesAppKitScroller(flagEnabled: true, verticalScrollMode: .internalScroll))
        #expect(!DiffPaneView.usesAppKitScroller(flagEnabled: false, verticalScrollMode: .internalScroll))
        #expect(!DiffPaneView.usesAppKitScroller(flagEnabled: true, verticalScrollMode: .staticHeight))
    }

    @Test("mounted AppKit pane retains standalone diff interactions")
    func mountedPaneInteractions() throws {
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
        let state = DiffPaneHarnessState(layout: .split, wrap: false, whitespace: false)
        var selectedAnchor: DiffReviewLineAnchor?
        let mounted = mount(DiffPaneHarness(
            state: state,
            model: model(includesCollapsedContext: true),
            theme: theme(),
            onReviewLineSelected: { selectedAnchor = $0 }
        ))
        defer { DiffPaneHarnessRetainer.retain(mounted.0, mounted.1) }

        #expect(appKitScroller(in: mounted.1.view) != nil)
        let buttons = allSubviews(of: mounted.1.view).compactMap { $0 as? NSButton }
        #expect(buttons.compactMap(\.toolTip).contains("Stage hunk"))
        let expand = try #require(buttons.first { $0.toolTip == "Expand context" })
        expand.performClick(nil)
        mounted.1.view.layoutSubtreeIfNeeded()
        let updatedHelpTexts = allSubviews(of: mounted.1.view).compactMap { view -> String? in
            guard let button = view as? NSButton else { return nil }
            return button.toolTip
        }
        #expect(updatedHelpTexts.contains("Collapse context"))

        let rulers = allSubviews(of: mounted.1.view)
            .compactMap { $0 as? DiffPaneTextScrollView }
            .compactMap { $0.verticalRulerView as? DiffPaneLineNumberRulerView }
        let ruler = try #require(rulers.first)
        let textView = try #require(ruler.scrollView?.documentView as? DiffPaneCodeTextView)
        let row = try #require((0..<100).first { textView.reviewLineAnchor(atRow: $0) != nil })
        ruler.invokeReviewLineSelectionForTesting(row: row)
        #expect(selectedAnchor != nil)
        #expect(textView.isSelectable)
        textView.setSelectedRange(NSRange(location: 0, length: 1))
        #expect(textView.selectedRange().length == 1)

        #expect(visibleTextScrollViews(in: mounted.1.view).count == 2)
        #expect(visibleTextScrollViews(in: mounted.1.view).allSatisfy { $0.hasHorizontalScroller })
        #expect(!renderedText(in: mounted.1.view).contains { $0.contains("let·value1·=·1") })

        state.layout = .stacked
        state.wrap = true
        state.whitespace = true
        AppKitDiffScrollerFlag.setOverride(true)
        settle(mounted.1.view)

        #expect(appKitScroller(in: mounted.1.view) != nil)
        let updatedTextScrollViews = visibleTextScrollViews(in: mounted.1.view)
        #expect(updatedTextScrollViews.count == 1)
        #expect(updatedTextScrollViews.allSatisfy { !$0.hasHorizontalScroller })
        #expect(renderedText(in: mounted.1.view).contains { $0.contains("let·value1·=·1") })
    }

    @Test("AppKit hosts stay bounded and rebuild after a flag change")
    func hostsAreBoundedAndFlagChangeRetainsBindings() throws {
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
        var layout = DiffLayoutMode.stacked
        var wrap = true
        var whitespace = true
        let sourceModel = model(groupCount: 80, sourceMarker: "source model survives rebuild")
        let mounted = mount(pane(
            model: sourceModel,
            layout: Binding(get: { layout }, set: { layout = $0 }),
            wrap: Binding(get: { wrap }, set: { wrap = $0 }),
            whitespace: Binding(get: { whitespace }, set: { whitespace = $0 })
        ))
        defer { DiffPaneHarnessRetainer.retain(mounted.0, mounted.1) }

        let initialScroller = try #require(appKitScroller(in: mounted.1.view))
        let hostCount = allSubviews(of: mounted.1.view).filter { $0 is AppKitDiffRowHostingView }.count
        #expect(hostCount > 0)
        #expect(hostCount < sourceModel.groups.count)

        AppKitDiffScrollerFlag.setOverride(false)
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        mounted.1.view.layoutSubtreeIfNeeded()
        #expect(appKitScroller(in: mounted.1.view) == nil)

        AppKitDiffScrollerFlag.setOverride(true)
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        mounted.1.view.layoutSubtreeIfNeeded()
        let rebuiltScroller = try #require(appKitScroller(in: mounted.1.view))
        #expect(ObjectIdentifier(rebuiltScroller) != ObjectIdentifier(initialScroller))
        #expect(layout == .stacked)
        #expect(wrap)
        #expect(whitespace)
        #expect(renderedText(in: mounted.1.view).contains { $0.contains("source·model·survives·rebuild") })
    }
}
