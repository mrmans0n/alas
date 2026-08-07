import Foundation
import Testing
@testable import Alas

struct TrackedRevisionTargetTests {
    @Test func expressionIdentityKeyIsTheExpressionItself() {
        #expect(TrackedRevisionTarget.expression("HEAD~3").identityKey == "HEAD~3")
        #expect(TrackedRevisionTarget.expression("HEAD~3").displayLabel == "HEAD~3")
    }

    @Test func stackEntryIdentityKeyIsNamespaced() {
        let target = TrackedRevisionTarget.stackEntry(ggID: "c-abc1234")
        #expect(target.identityKey == "gg:c-abc1234")
        #expect(target.displayLabel == "c-abc1234")
    }

    @Test func accessorsDiscriminateCases() {
        let expression = TrackedRevisionTarget.expression("main")
        let entry = TrackedRevisionTarget.stackEntry(ggID: "c-abc1234")

        #expect(expression.expressionValue == "main")
        #expect(expression.ggID == nil)
        #expect(!expression.isStackEntry)
        #expect(entry.expressionValue == nil)
        #expect(entry.ggID == "c-abc1234")
        #expect(entry.isStackEntry)
    }

    @Test func normalizationTrimsAndRejectsEmpty() {
        #expect(TrackedRevisionTarget.expression("  HEAD~1 ").normalized() == .expression("HEAD~1"))
        #expect(TrackedRevisionTarget.stackEntry(ggID: " c-abc1234 ").normalized() == .stackEntry(ggID: "c-abc1234"))
        #expect(TrackedRevisionTarget.expression("   ").normalized() == nil)
        #expect(TrackedRevisionTarget.stackEntry(ggID: "").normalized() == nil)
    }

    @Test func codableRoundTripsBothCases() throws {
        for target in [
            TrackedRevisionTarget.expression("HEAD~3"),
            TrackedRevisionTarget.stackEntry(ggID: "c-abc1234"),
        ] {
            let data = try JSONEncoder().encode(target)
            #expect(try JSONDecoder().decode(TrackedRevisionTarget.self, from: data) == target)
        }
    }

    @Test func encodedStackEntryUsesStableWireKind() throws {
        let data = try JSONEncoder().encode(TrackedRevisionTarget.stackEntry(ggID: "c-abc1234"))
        let json = try #require(
            try JSONSerialization.jsonObject(with: data) as? [String: String]
        )
        #expect(json["kind"] == "stack-entry")
        #expect(json["value"] == "c-abc1234")
    }
}
