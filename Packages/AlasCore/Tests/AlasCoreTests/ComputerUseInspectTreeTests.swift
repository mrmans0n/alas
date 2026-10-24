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
    /// answering, then the time limit, which may have kept the read from its node budget.
    @Test(arguments: [
        (true, true, true, true, String?("limit")),
        (false, true, true, true, "app_not_responding"),
        (false, false, true, true, "time_limit"),
        (false, false, false, true, "node_budget"),
        (false, false, false, false, nil),
    ])
    func aTruncatedResultNamesWhatCutIt(
        limitReached: Bool, appNotResponding: Bool, timedOut: Bool, budgetSpent: Bool, truncatedBy: String?
    ) {
        let cut = ComputerUseReadCut.reason(appNotResponding: appNotResponding, timedOut: timedOut, budgetSpent: budgetSpent)
        #expect(ComputerUseInspectTree.truncation(limitReached: limitReached, cut: cut) == truncatedBy)
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
    /// A web area the app hasn't filled yet.
    private static let hollow = ComputerUseAXNode(role: "AXWindow", children: [ComputerUseAXNode(role: "AXWebArea")])

    /// Only a Chromium or Electron window without a web area, read for the first time, is read again.
    @Test(arguments: [
        (true, String?("com.tinyspeck.slackmacgap"), false, empty, true),
        (false, "com.google.Chrome", false, empty, true),
        (true, "com.tinyspeck.slackmacgap", false, built, false),
        (true, "com.tinyspeck.slackmacgap", false, hollow, true),
        (true, "com.tinyspeck.slackmacgap", true, empty, false),
        (false, "com.apple.TextEdit", false, empty, false),
    ])
    func aWebWindowWithoutItsWebAreaIsReadOnceMore(
        manual: Bool, bundleID: String?, woken: Bool, root: ComputerUseAXNode, wakes: Bool
    ) {
        #expect(ComputerUseWebContent.needsWake(
            acceptsManualAccessibility: manual, bundleID: bundleID, alreadyWoken: woken, root: root) == wakes)
    }

    /// AXEnhancedUserInterface is only the second try, for a Chromium browser still showing no web area.
    @Test(arguments: [
        (String?("com.google.Chrome"), empty, true),
        ("com.google.Chrome", built, false),
        ("com.tinyspeck.slackmacgap", empty, false),
    ])
    func onlyAChromeWindowStillEmptyGetsEnhancedUserInterface(bundleID: String?, root: ComputerUseAXNode, sets: Bool) {
        #expect(ComputerUseWebContent.needsEnhancedUserInterface(bundleID: bundleID, root: root) == sets)
    }

    /// Only a setting Alas turned on is turned off again.
    @Test(arguments: [(Bool?(false), true, true), (nil, true, true), (true, true, false), (false, false, false)])
    func onlyWhatAlasTurnedOnIsRestored(before: Bool?, setSucceeded: Bool, restores: Bool) {
        #expect(ComputerUseWebContent.restores(before: before, setSucceeded: setSucceeded) == restores)
    }

    /// After the wake, the window is read again until its web area has something in it, for at
    /// most `contentDeadline`.
    @Test(arguments: [
        (empty, Duration.zero, true),
        (hollow, .milliseconds(1250), true),
        (hollow, .milliseconds(1500), false),
        (built, .zero, false),
    ])
    func firstContactWaitsForWebContentUntilTheDeadline(root: ComputerUseAXNode, waited: Duration, waits: Bool) {
        #expect(ComputerUseWebContent.keepsWaiting(root: root, waited: waited) == waits)
    }
}
