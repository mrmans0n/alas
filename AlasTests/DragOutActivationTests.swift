import Foundation
import Testing
@testable import Alas

struct DragOutActivationTests {
    @Test func aClickDoesNotTravelFarEnoughToPrefetch() {
        #expect(DragOutActivation.travel(CGSize(width: 0, height: 0))
            < DragOutActivation.prefetchDistance)
    }

    @Test func prefetchStartsBeforeTheDragActivates() {
        #expect(DragOutActivation.prefetchDistance < DragOutActivation.activationDistance)
    }

    @Test func shortTravelDoesNotActivate() {
        #expect(DragOutActivation.travel(CGSize(width: 3, height: 0))
            < DragOutActivation.activationDistance)
    }

    @Test func travelIsDiagonalDistanceNotAxisDistance() {
        // 5-12-13 triangle: neither axis reaches the threshold on its own.
        #expect(DragOutActivation.travel(CGSize(width: 5, height: 12)) == 13)
    }

    @Test func longTravelActivates() {
        #expect(DragOutActivation.travel(CGSize(width: 0, height: -20))
            >= DragOutActivation.activationDistance)
    }
}
