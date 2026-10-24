import CoreGraphics
import Foundation
import Testing
@testable import Alas

struct ComputerUseAXActionsTests {
    /// A click by ref must show, whatever its button or count; typing by ref may target a field
    /// out of view, and scrolling is how one gets there.
    @Test(arguments: [
        (ComputerUseInput.click(.element(ComputerUseAXHandles(), 3), button: .left, count: 1), true),
        (.click(.element(ComputerUseAXHandles(), 3), button: .left, count: 2), true),
        (.click(.element(ComputerUseAXHandles(), 3), button: .right, count: 1), true),
        (.click(.point(.zero), button: .left, count: 1), false),
        (.type("a", target: .element(ComputerUseAXHandles(), 3), replace: false), false),
        (.scroll(.element(ComputerUseAXHandles(), 3), dx: 0, dy: 1), false),
        (.pointerClick(.element(ComputerUseAXHandles(), 3)), false),
    ])
    func clicksByRefAreRefusedWhenTheElementIsHidden(input: ComputerUseInput, checked: Bool) {
        #expect((input.refusedWhenHidden?.1 == 3) == checked)
    }
}
