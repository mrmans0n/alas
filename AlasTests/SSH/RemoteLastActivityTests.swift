import Foundation
import Testing
@testable import Alas

struct RemoteLastActivityTests {
    @Test func parsesEpochSeconds() {
        #expect(WorktreeService.date(fromEpochOutput: "1752249600\n") == Date(timeIntervalSince1970: 1_752_249_600))
    }
    @Test func rejectsInvalidEpochs() {
        #expect(WorktreeService.date(fromEpochOutput: "bad") == nil)
        #expect(WorktreeService.date(fromEpochOutput: "") == nil)
    }
}
