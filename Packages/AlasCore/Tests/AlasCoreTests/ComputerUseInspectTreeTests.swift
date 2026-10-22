import Foundation
import Testing
@testable import AlasPlatform

struct ComputerUseInspectTreeTests {
    private func node(_ role: String, title: String? = nil, value: String? = nil, subrole: String? = nil,
                      _ children: [ComputerUseAXNode] = []) -> ComputerUseAXNode {
        ComputerUseAXNode(role: role, subrole: subrole, title: title, value: value, children: children)
    }

    private var sample: ComputerUseAXNode {
        node("AXWindow", [
            node("AXGroup", [node("AXButton", title: "OK"), node("AXButton", title: "Cancel")]),
            node("AXTextField", value: "hello"),
        ])
    }

    @Test func flattenAssignsPreOrderRefsAndDepths() {
        let result = ComputerUseInspectTree.flatten(sample, query: nil, limit: 100, maxDepth: 10)
        #expect(result.elements.map(\.ref) == ["e1", "e2", "e3", "e4", "e5"])
        #expect(result.elements.map(\.role) == ["AXWindow", "AXGroup", "AXButton", "AXButton", "AXTextField"])
        #expect(result.elements.map(\.depth) == [0, 1, 2, 2, 1])
        #expect(!result.truncated)
    }

    @Test func flattenStopsAtLimitAndReportsTruncation() {
        let cut = ComputerUseInspectTree.flatten(sample, query: nil, limit: 3, maxDepth: 10)
        #expect(cut.elements.count == 3)
        #expect(cut.truncated)
        let exact = ComputerUseInspectTree.flatten(sample, query: nil, limit: 5, maxDepth: 10)
        #expect(exact.elements.count == 5)
        #expect(!exact.truncated)
    }

    @Test func flattenSkipsBeyondMaxDepth() {
        let result = ComputerUseInspectTree.flatten(sample, query: nil, limit: 100, maxDepth: 1)
        #expect(result.elements.map(\.role) == ["AXWindow", "AXGroup", "AXTextField"])
        #expect(!result.truncated)
    }

    @Test func queryMatchesCaseInsensitivelyAndKeepsDescendantsReachable() {
        let result = ComputerUseInspectTree.flatten(sample, query: "cANcel", limit: 100, maxDepth: 10)
        #expect(result.elements.map(\.title) == ["Cancel"])
        #expect(result.elements.first?.ref == "e1")
        #expect(result.elements.first?.depth == 2)
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
