import Foundation
import Testing
@testable import AlasPlatform

struct ComputerUseInspectTreeTests {
    private func node(_ role: String, title: String? = nil, value: String? = nil, subrole: String? = nil, handle: Int? = nil,
                      _ children: [ComputerUseAXNode] = []) -> ComputerUseAXNode {
        ComputerUseAXNode(role: role, subrole: subrole, title: title, value: value, children: children, handle: handle)
    }

    private var sample: ComputerUseAXNode {
        node("AXWindow", handle: 0, [
            node("AXGroup", handle: 1, [node("AXButton", title: "OK", handle: 2), node("AXButton", title: "Cancel", handle: 3)]),
            node("AXTextField", value: "hello", handle: 4),
        ])
    }

    /// A truncated result names what cut it: the element limit first, then an app that stopped
    /// answering, then the time limit, then elements whose children couldn't be read, any of
    /// which may have kept the read from its node budget.
    @Test(arguments: [
        (true, true, true, true, true, String?("limit")),
        (false, true, true, true, true, "app_not_responding"),
        (false, false, true, true, true, "time_limit"),
        (false, false, false, true, true, "elements_unreadable"),
        (false, false, false, false, true, "node_budget"),
        (false, false, false, false, false, nil),
    ])
    func aTruncatedResultNamesWhatCutIt(
        limitReached: Bool, appNotResponding: Bool, timedOut: Bool, unreadable: Bool, budgetSpent: Bool,
        truncatedBy: String?
    ) {
        let cut = ComputerUseReadCut.reason(
            appNotResponding: appNotResponding, timedOut: timedOut, elementsUnreadable: unreadable, budgetSpent: budgetSpent)
        #expect(ComputerUseInspectTree.truncation(limitReached: limitReached, cut: cut) == truncatedBy)
    }

    /// An element's children are read, absent, gone with it, unanswered, or unreadable, and a
    /// batch that came back malformed or refused is read again one attribute at a time.
    @Test(arguments: [
        (Int32(0), true, Int32?.none, ComputerUseReadCut.ChildrenRead.read),
        (0, false, nil, .perAttribute),
        (-25200, false, nil, .perAttribute),
        (-25202, false, nil, .gone),
        (-25204, false, nil, .unanswered),
        (0, true, -25212, .none),
        (0, true, -25202, .gone),
        (0, true, -25204, .unanswered),
        (0, true, -25200, .unreadable),
    ])
    func anElementsChildrenReadAsWhatTheAppAnswered(
        batchResult: Int32, complete: Bool, childrenError: Int32?, read: ComputerUseReadCut.ChildrenRead
    ) {
        #expect(ComputerUseReadCut.children(batchResult: batchResult, batchComplete: complete, childrenError: childrenError) == read)
    }

    /// The depth warning only suggests what would read deeper.
    @Test(arguments: [
        (12, false, true, "Some elements are deeper than max_depth; pass a higher max_depth (up to 32), or a query, which reads 32 levels unless max_depth is given."),
        (20, true, true, "Some elements are deeper than max_depth; pass a higher max_depth (up to 32)."),
        (32, true, true, "Some elements are deeper than 32 levels, the deepest this read goes."),
        (32, true, false, "Some elements are deeper than 32 levels, the deepest this read goes."),
    ])
    func theDepthWarningOnlySuggestsWhatReadsDeeper(maxDepth: Int, query: Bool, takesMaxDepth: Bool, hint: String) {
        #expect(ComputerUseInspectTree.depthHint(maxDepth: maxDepth, queryGiven: query, takesMaxDepth: takesMaxDepth) == hint)
    }

    @Test func flattenAssignsPreOrderRefsAndDepths() {
        let result = ComputerUseInspectTree.flatten(sample, query: nil, limit: 100, maxDepth: 10)
        #expect(result.elements.map(\.ref) == ["e1", "e2", "e3", "e4", "e5"])
        #expect(result.elements.map(\.role) == ["AXWindow", "AXGroup", "AXButton", "AXButton", "AXTextField"])
        #expect(result.elements.map(\.depth) == [0, 1, 2, 2, 1])
        #expect(!result.truncated)
    }

    @Test func flattenCarriesHandlesInEmittedOrder() {
        let tree = ComputerUseAXNode(role: "AXWindow", children: [
            ComputerUseAXNode(role: "AXGroup", children: [ComputerUseAXNode(role: "AXButton", handle: 7)], handle: 3),
            ComputerUseAXNode(role: "AXTextField"),
        ], handle: 1)
        let result = ComputerUseInspectTree.flatten(tree, query: nil, limit: 100, maxDepth: 10)
        #expect(result.elements.map(\.handle) == [1, 3, 7, nil])
    }

    @Test func flattenStopsAtLimitAndReportsTruncation() {
        let cut = ComputerUseInspectTree.flatten(sample, query: nil, limit: 3, maxDepth: 10)
        #expect(cut.elements.count == 3)
        #expect(cut.truncated)
        let exact = ComputerUseInspectTree.flatten(sample, query: nil, limit: 5, maxDepth: 10)
        #expect(exact.elements.count == 5)
        #expect(!exact.truncated)
    }

    /// An element is marked hidden when none of its frame shows in the window and its scroll
    /// areas, such as a name cell scrolled under the sidebar; one without a frame isn't.
    @Test func flattenMarksElementsNothingOfWhichShows() {
        let tree = ComputerUseAXNode(role: "AXWindow", frame: CGRect(x: 0, y: 0, width: 500, height: 400), children: [
            ComputerUseAXNode(role: "AXScrollArea", frame: CGRect(x: 200, y: 0, width: 300, height: 400), children: [
                ComputerUseAXNode(role: "AXTextField", title: "under the sidebar", frame: CGRect(x: 50, y: 10, width: 100, height: 20)),
                ComputerUseAXNode(role: "AXTextField", title: "half shown", frame: CGRect(x: 150, y: 40, width: 100, height: 20)),
                ComputerUseAXNode(role: "AXButton", title: "no frame"),
            ]),
            ComputerUseAXNode(role: "AXButton", title: "below the window", frame: CGRect(x: 10, y: 420, width: 50, height: 20)),
        ])
        let visible = ComputerUseInspectTree.flatten(tree, query: nil, limit: 100, maxDepth: 10).elements
            .map { "\($0.title ?? $0.role)=\($0.isVisible)" }
        #expect(visible == [
            "AXWindow=true", "AXScrollArea=true", "under the sidebar=false", "half shown=true", "no frame=true",
            "below the window=false",
        ])
    }

    @Test func flattenSkipsBeyondMaxDepth() {
        let result = ComputerUseInspectTree.flatten(sample, query: nil, limit: 100, maxDepth: 1)
        #expect(result.elements.map(\.role) == ["AXWindow", "AXGroup", "AXTextField"])
        #expect(!result.truncated && result.depthLimited)
        // Deep enough for every element: nothing was left out for depth.
        #expect(!ComputerUseInspectTree.flatten(sample, query: nil, limit: 100, maxDepth: 2).depthLimited)
        // The read itself stopped above children it didn't read.
        var cut = sample
        cut.children[1].childrenUnread = true
        #expect(ComputerUseInspectTree.flatten(cut, query: nil, limit: 100, maxDepth: 10).depthLimited)
    }

    @Test func queryMatchesCaseInsensitivelyAndKeepsDescendantsReachable() {
        let result = ComputerUseInspectTree.flatten(sample, query: "cANcel", limit: 100, maxDepth: 10)
        #expect(result.elements.map(\.title) == ["Cancel"])
        #expect(result.elements.first?.depth == 2)
    }

    @Test(arguments: [("cancel", 1), ("AXButton", 1), ("hello", 100), ("AXButton", 2)] as [(String, Int)])
    func filteredRefsNameTheSameElementAsTheFullListing(query: String, limit: Int) {
        let full = ComputerUseInspectTree.flatten(sample, query: nil, limit: 100, maxDepth: 10)
        let refToRole = Dictionary(uniqueKeysWithValues: full.elements.map { ($0.ref, "\($0.role)|\($0.title ?? "")|\($0.value ?? "")") })
        let filtered = ComputerUseInspectTree.flatten(sample, query: query, limit: limit, maxDepth: 10)
        #expect(!filtered.elements.isEmpty)
        for element in filtered.elements {
            #expect(refToRole[element.ref] == "\(element.role)|\(element.title ?? "")|\(element.value ?? "")")
        }
        // The elements the query or limit left out keep their refs too.
        #expect(filtered.refs == full.refs)
        #expect(full.refs == ["e1": 0, "e2": 1, "e3": 2, "e4": 3, "e5": 4])
    }

    @Test(arguments: [("AXTextField", "AXSecureTextField"), ("AXSecureTextField", nil)] as [(String, String?)])
    func secureFieldsNeverExposeValue(role: String, subrole: String?) {
        let secure = node(role, value: "hunter2", subrole: subrole)
        let root = node("AXWindow", [secure])
        let all = ComputerUseInspectTree.flatten(root, query: nil, limit: 10, maxDepth: 10)
        #expect(all.elements.last?.value == nil)
        let byValue = ComputerUseInspectTree.flatten(root, query: "hunter2", limit: 10, maxDepth: 10)
        #expect(byValue.elements.isEmpty)
    }

    @Test func stringsAreTruncatedTo200Characters() {
        let long = String(repeating: "x", count: 500)
        let result = ComputerUseInspectTree.flatten(node("AXStaticText", title: long, value: long), query: nil, limit: 1, maxDepth: 1)
        #expect(result.elements[0].title?.count == 200)
        #expect(result.elements[0].value?.count == 200)
        // Only a clipped value says how long it really is, in characters.
        #expect(result.elements[0].valueLength == 500)
        let emoji = String(repeating: "👍🏽", count: 201)
        let short = ComputerUseInspectTree.flatten(node("AXWindow", value: "short", [node("AXTextArea", value: emoji)]),
                                                   query: nil, limit: 2, maxDepth: 1)
        #expect(short.elements.map(\.valueLength) == [nil, 201])
    }

    /// How the window read after a drag differs from the one before it: a window with an outline
    /// of four rows, of which a three-node prefix reads the window, the outline and the first row.
    enum PrefixChange: CaseIterable {
        case titleInPrefix, rowGonePastPrefix, onlyPastCommonLength, focusOnly, unreadableCut, partialLastNode, none
    }

    /// A cut-short read shows a change only in the nodes both reads hashed, a container's child
    /// count included; focus doesn't count, nor a read whose cut makes it incomparable, nor the
    /// node a time limit stopped at.
    @Test(arguments: PrefixChange.allCases)
    func cutShortReadsShowAChangeOnlyInTheNodesBothRead(_ change: PrefixChange) {
        func window(rows: Int = 4, title: String = "a", focused: Bool = false, partialFirstRow: Bool = false) -> ComputerUseAXNode {
            let cells = (0..<rows).map { index in
                ComputerUseAXNode(
                    role: "AXRow", title: index == 0 ? title : "\(index)",
                    value: index == 0 && partialFirstRow ? nil : "v", isFocused: index == 0 && focused, childCount: 0)
            }
            let outline = ComputerUseAXNode(role: "AXOutline", children: cells, childCount: rows)
            return ComputerUseAXNode(role: "AXWindow", children: [outline], childCount: 1)
        }
        func hashes(_ root: ComputerUseAXNode, cut: ComputerUseReadCut? = .nodeBudget, limit: Int = 3) -> [Int]? {
            ComputerUseChangeCheck.prefixHashes(root, cut: cut, maxDepth: 32, limit: limit)
        }
        let before = hashes(window())
        let (after, changed): ([Int]?, Bool) = switch change {
        case .titleInPrefix: (hashes(window(title: "b")), true)
        case .rowGonePastPrefix: (hashes(window(rows: 3)), true)
        case .onlyPastCommonLength: (hashes(window(title: "b"), limit: 2), false)
        case .focusOnly: (hashes(window(focused: true)), false)
        case .unreadableCut: (hashes(window(title: "b"), cut: .elementsUnreadable), false)
        case .partialLastNode: (hashes(window(partialFirstRow: true), cut: .timeLimit), false)
        case .none: (hashes(window()), false)
        }
        #expect(ComputerUseChangeCheck.prefixChanged(before, after) == changed)
    }

    @Test(arguments: [
        (CGSize(width: 1000, height: 500), CGFloat(2), CGSize(width: 1280, height: 640), CGFloat(1.28)),
        (CGSize(width: 600, height: 400), CGFloat(2), CGSize(width: 1200, height: 800), CGFloat(2)),
        (CGSize(width: 2000, height: 100), CGFloat(1), CGSize(width: 1280, height: 64), CGFloat(0.64)),
        (CGSize(width: 0.4, height: 0.4), CGFloat(1), CGSize(width: 1, height: 1), CGFloat(1)),
    ])
    func screenshotGeometry(point: CGSize, backing: CGFloat, pixels: CGSize, scale: CGFloat) {
        let out = ComputerUseScreenshotGeometry.output(pointSize: point, backingScale: backing)
        #expect(out.pixelSize == pixels)
        #expect(abs(out.scale - scale) < 0.0001)
    }
}

struct ComputerUseWebContentTests {
    private static let empty = ComputerUseAXNode(role: "AXWindow", children: [ComputerUseAXNode(role: "AXGroup")])
    private static let built = ComputerUseAXNode(role: "AXWindow", children: [
        ComputerUseAXNode(role: "AXGroup", children: [
            ComputerUseAXNode(role: "AXWebArea", children: [ComputerUseAXNode(role: "AXTextField")]),
        ]),
    ])
    /// A read that stopped at its depth limit above the web content.
    private static let deep = ComputerUseAXNode(role: "AXWindow", children: [ComputerUseAXNode(role: "AXGroup", childrenUnread: true)])
    /// A web area the app hasn't filled yet.
    private static let hollow = ComputerUseAXNode(role: "AXWindow", children: [ComputerUseAXNode(role: "AXWebArea")])
    /// Chrome's page area before its web tree is built: nested groups down to an empty one, no web area.
    private static let unbuilt = ComputerUseAXNode(role: "AXWindow", children: [
        ComputerUseAXNode(role: "AXGroup", children: [
            ComputerUseAXNode(role: "AXGroup", children: [ComputerUseAXNode(role: "AXGroup")]),
        ]),
    ])

    /// Only a Chromium or Electron window without a web area with content, due a try, is woken.
    @Test(arguments: [
        (true, String?("com.tinyspeck.slackmacgap"), true, false, true),
        (false, "com.google.Chrome", true, false, true),
        (true, "com.tinyspeck.slackmacgap", true, true, false),
        (true, "com.tinyspeck.slackmacgap", false, false, false),
        (false, "com.apple.TextEdit", true, false, false),
    ])
    func aWebWindowWithoutItsWebContentIsWoken(manual: Bool, bundleID: String?, due: Bool, content: Bool, wakes: Bool) {
        #expect(ComputerUseWebContent.needsWake(
            acceptsManualAccessibility: manual, bundleID: bundleID, wakesAgain: due, showsContent: content) == wakes)
    }

    /// Content is a web area with something in it: not groups alone (Chrome's page area before its
    /// tree is built), not an empty web area, not a read that stopped above it.
    @Test(arguments: [(empty, false), (unbuilt, false), (hollow, false), (deep, false), (built, true)])
    func webContentIsAWebAreaWithSomethingInIt(root: ComputerUseAXNode, shows: Bool) {
        #expect(ComputerUseWebContent.hasWebContent(root) == shows)
    }

    /// AXEnhancedUserInterface only for a Chromium browser that has no AXManualAccessibility; a
    /// set that failed otherwise (an app still starting) is no reason.
    @Test(arguments: [
        (ComputerUseWebContent.SetResult.unsupported, String?("com.google.Chrome"), true),
        (.set, "com.google.Chrome", false),
        (.failed, "com.google.Chrome", false),
        (.unsupported, "com.tinyspeck.slackmacgap", false),
        (.unsupported, nil, false),
    ])
    func enhancedUserInterfaceOnlyForAChromeWithoutManualAccessibility(
        manual: ComputerUseWebContent.SetResult, bundleID: String?, falls: Bool
    ) {
        #expect(ComputerUseWebContent.fallsBackToEnhancedUserInterface(after: manual, bundleID: bundleID) == falls)
    }

    /// A set that failed in a way that may pass (Chrome still starting) is tried again within the
    /// wait; an attribute the app doesn't have falls back to AXEnhancedUserInterface only in a
    /// Chromium browser, and only from AXManualAccessibility.
    @Test(arguments: [
        (ComputerUseWebContent.SetResult.set, "AXManualAccessibility", String?("com.google.Chrome"),
         ComputerUseWebContent.NextSet.accepted),
        (.set, "AXEnhancedUserInterface", "com.google.Chrome", .accepted),
        (.failed, "AXManualAccessibility", "com.google.Chrome", .retry),
        (.failed, "AXEnhancedUserInterface", "com.google.Chrome", .retry),
        (.failed, "AXManualAccessibility", "com.tinyspeck.slackmacgap", .retry),
        (.unsupported, "AXManualAccessibility", "com.google.Chrome", .fallBack("AXEnhancedUserInterface")),
        (.unsupported, "AXEnhancedUserInterface", "com.google.Chrome", .waitOnly),
        (.unsupported, "AXManualAccessibility", "com.tinyspeck.slackmacgap", .waitOnly),
    ])
    func aFailedSetIsTriedAgainAndAMissingAttributeFallsBack(
        result: ComputerUseWebContent.SetResult, attribute: String, bundleID: String?, next: ComputerUseWebContent.NextSet
    ) {
        #expect(ComputerUseWebContent.next(after: result, of: attribute, bundleID: bundleID) == next)
    }

    /// Only a busy or still starting app is asked again: Chrome answers AXEnhancedUserInterface
    /// with notImplemented every time.
    @Test(arguments: [
        (Int32(0), ComputerUseWebContent.SetResult.set),
        (-25204, .failed),
        (-25200, .failed),
        (-25205, .unsupported),
        (-25208, .unsupported),
        (-25211, .unsupported),
        (-25202, .unsupported),
    ])
    func onlyATransientErrorIsTriedAgain(error: Int32, result: ComputerUseWebContent.SetResult) {
        #expect(ComputerUseWebContent.setResult(error) == result)
    }

    /// The wait's look finds the page's web area under a toolbar of more elements than a small
    /// depth-first read covers, skips the menu bar, and needs the web area to have content.
    @Test(arguments: [
        (500, true, 3000, true),
        (500, false, 3000, false),
        (5000, true, 3000, false),
        (0, true, 3000, true),
    ])
    func theWaitsLookFindsAWebAreaUnderABigToolbar(toolbar: Int, filled: Bool, budget: Int, finds: Bool) {
        let buttons = (0 ..< toolbar).map { _ in ComputerUseAXNode(role: "AXButton") }
        var page = ComputerUseAXNode(role: "AXWebArea", children: filled ? [ComputerUseAXNode(role: "AXTextField")] : [])
        for _ in 0 ..< 7 { page = ComputerUseAXNode(role: "AXGroup", children: [page]) }
        let menus = ComputerUseAXNode(role: "AXMenuBar", children: (0 ..< 5000).map { _ in ComputerUseAXNode(role: "AXMenuItem") })
        let window = ComputerUseAXNode(role: "AXWindow", children: [
            menus, ComputerUseAXNode(role: "AXToolbar", children: buttons), page,
        ])
        #expect(ComputerUseWebContent.findsWebContent(
            from: window, budget: budget, role: { $0.role }, children: { $0.children }) == finds)
    }

    /// The wait after the wake sets the attribute once more, from halfway to the deadline.
    @Test(arguments: [
        (Duration.zero, false, false),
        (.milliseconds(1750), false, false),
        (.seconds(2), false, true),
        (.milliseconds(3500), false, true),
        (.milliseconds(3500), true, false),
    ])
    func theWakeIsSetAgainHalfwayThroughTheWait(waited: Duration, reasserted: Bool, sets: Bool) {
        #expect(ComputerUseWebContent.reasserts(waited: waited, reasserted: reasserted) == sets)
    }

    /// Only a setting Alas turned on is turned off again.
    @Test(arguments: [(Bool?(false), true, true), (nil, true, true), (true, true, false), (false, false, false)])
    func onlyWhatAlasTurnedOnIsRestored(before: Bool?, setSucceeded: Bool, restores: Bool) {
        #expect(ComputerUseWebContent.restores(before: before, setSucceeded: setSucceeded) == restores)
    }

    /// After the wake, the window is looked at again until a web area has something in it, for at
    /// most `contentDeadline`.
    @Test(arguments: [
        (false, Duration.zero, true),
        (false, .milliseconds(3900), true),
        (false, .seconds(4), false),
        (true, .zero, false),
    ])
    func firstContactWaitsForWebContentUntilTheDeadline(content: Bool, waited: Duration, waits: Bool) {
        #expect(ComputerUseWebContent.keepsWaiting(showsContent: content, waited: waited) == waits)
    }

    /// A process whose content showed isn't woken again; one that timed out is, after a while, a
    /// few times.
    @Test(arguments: [
        (ComputerUseWebContent.FirstContact?.none, 0.0, true),
        (.complete, 0.0, false),
        (.complete, 600.0, false),
        (.timedOut(attempts: 1, at: Date(timeIntervalSince1970: 0)), 10.0, false),
        (.timedOut(attempts: 1, at: Date(timeIntervalSince1970: 0)), 30.0, true),
        (.timedOut(attempts: 2, at: Date(timeIntervalSince1970: 0)), 60.0, true),
        (.timedOut(attempts: 3, at: Date(timeIntervalSince1970: 0)), 600.0, false),
    ])
    func aTimedOutFirstContactIsRetriedAfterAWhileAFewTimes(last: ComputerUseWebContent.FirstContact?, after: Double, wakes: Bool) {
        #expect(ComputerUseWebContent.wakesAgain(after: last, now: Date(timeIntervalSince1970: after)) == wakes)
    }

    /// The turn's end forgets a success, so the next turn may ask again, but not a timeout's tries.
    @Test(arguments: [
        (ComputerUseWebContent.FirstContact.complete, false),
        (.timedOut(attempts: 1, at: Date(timeIntervalSince1970: 0)), true),
        (.timedOut(attempts: 3, at: Date(timeIntervalSince1970: 0)), true),
    ])
    func aTimeoutsTriesOutlastTheTurn(contact: ComputerUseWebContent.FirstContact, kept: Bool) {
        #expect(ComputerUseWebContent.keepsAfterRestore(contact) == kept)
    }
}
