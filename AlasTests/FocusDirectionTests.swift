import Testing
import Foundation
@testable import Alas

struct FocusDirectionTests {
    // Layout (2-pane horizontal-axis split, i.e. side-by-side):
    //  ┌─────┬─────┐
    //  │  A  │  B  │
    //  └─────┴─────┘
    private let twoPaneHorizontal: [String: CGRect] = [
        "A": CGRect(x: 0,   y: 0, width: 100, height: 100),
        "B": CGRect(x: 100, y: 0, width: 100, height: 100),
    ]

    // 2x2 grid:
    //  ┌──┬──┐
    //  │A │B │
    //  ├──┼──┤
    //  │C │D │
    //  └──┴──┘
    private let twoByTwoGrid: [String: CGRect] = [
        "A": CGRect(x: 0,   y: 0,   width: 100, height: 100),
        "B": CGRect(x: 100, y: 0,   width: 100, height: 100),
        "C": CGRect(x: 0,   y: 100, width: 100, height: 100),
        "D": CGRect(x: 100, y: 100, width: 100, height: 100),
    ]

    @Test func rightFromAReturnsB() {
        let r = PaneFocusFinder.nearestLeaf(from: "A", direction: .right, frames: twoPaneHorizontal)
        #expect(r == "B")
    }

    @Test func leftFromBReturnsA() {
        let r = PaneFocusFinder.nearestLeaf(from: "B", direction: .left, frames: twoPaneHorizontal)
        #expect(r == "A")
    }

    @Test func upFromAInTwoPaneHorizontalIsNil() {
        let r = PaneFocusFinder.nearestLeaf(from: "A", direction: .up, frames: twoPaneHorizontal)
        #expect(r == nil)
    }

    @Test func downFromAInGridReturnsC() {
        let r = PaneFocusFinder.nearestLeaf(from: "A", direction: .down, frames: twoByTwoGrid)
        #expect(r == "C")
    }

    @Test func rightFromCInGridReturnsD() {
        let r = PaneFocusFinder.nearestLeaf(from: "C", direction: .right, frames: twoByTwoGrid)
        #expect(r == "D")
    }

    @Test func upFromDInGridReturnsB() {
        let r = PaneFocusFinder.nearestLeaf(from: "D", direction: .up, frames: twoByTwoGrid)
        #expect(r == "B")
    }

    @Test func directionAtEdgeReturnsNil() {
        let r = PaneFocusFinder.nearestLeaf(from: "B", direction: .right, frames: twoPaneHorizontal)
        #expect(r == nil)
    }

    @Test func missingSourceReturnsNil() {
        let r = PaneFocusFinder.nearestLeaf(from: "missing", direction: .right, frames: twoPaneHorizontal)
        #expect(r == nil)
    }
}
