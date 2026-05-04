import Testing
@testable import Alas

struct DragHandleTests {
    @Test func clampsToMinAndMax() {
        let clamped = DragHandle.clamp(value: 9000, min: 200, max: 600)
        #expect(clamped == 600)
        let clampedLow = DragHandle.clamp(value: 0, min: 200, max: 600)
        #expect(clampedLow == 200)
    }

    @Test func passesThroughInRange() {
        #expect(DragHandle.clamp(value: 350, min: 200, max: 600) == 350)
    }
}
