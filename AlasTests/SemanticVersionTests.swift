import Testing
@testable import Alas

struct SemanticVersionTests {
    @Test func parsesPlainTriple() {
        let v = SemanticVersion(parsing: "1.2.3")
        #expect(v == SemanticVersion(major: 1, minor: 2, patch: 3))
    }

    @Test func stripsLeadingV() {
        #expect(SemanticVersion(parsing: "v0.5.1") == SemanticVersion(major: 0, minor: 5, patch: 1))
    }

    @Test func padsMissingComponents() {
        #expect(SemanticVersion(parsing: "1") == SemanticVersion(major: 1, minor: 0, patch: 0))
        #expect(SemanticVersion(parsing: "1.2") == SemanticVersion(major: 1, minor: 2, patch: 0))
    }

    @Test func ignoresPrereleaseAndBuildSuffix() {
        #expect(SemanticVersion(parsing: "1.2.3-rc1") == SemanticVersion(major: 1, minor: 2, patch: 3))
        #expect(SemanticVersion(parsing: "1.2.3+build7") == SemanticVersion(major: 1, minor: 2, patch: 3))
    }

    @Test func orderingIsNumericNotLexical() {
        #expect(SemanticVersion(parsing: "0.10.0")! > SemanticVersion(parsing: "0.9.0")!)
        #expect(SemanticVersion(parsing: "1.0.0")! > SemanticVersion(parsing: "0.99.99")!)
    }

    @Test func equalVersionsAreNotLess() {
        let a = SemanticVersion(parsing: "0.5.1")!
        #expect(!(a < a))
    }

    @Test func rejectsMalformed() {
        #expect(SemanticVersion(parsing: "") == nil)
        #expect(SemanticVersion(parsing: "abc") == nil)
        #expect(SemanticVersion(parsing: "1.x.0") == nil)
        #expect(SemanticVersion(parsing: "1.2.3.4") == nil)
    }

    @Test func descriptionRoundTrips() {
        #expect(SemanticVersion(major: 0, minor: 5, patch: 1).description == "0.5.1")
    }
}
