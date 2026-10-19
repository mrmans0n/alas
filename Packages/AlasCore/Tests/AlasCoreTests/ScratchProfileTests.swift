import Foundation
import Testing
@testable import AlasCore

struct ScratchProfileTests {
    /// The tests run on a scratch profile, never the everyday one: every
    /// store that resolves `Paths` writes there.
    @Test func theTestsDoNotUseTheEverydayProfile() {
        #expect(AlasProfile.current.isIsolated)
        #expect(!AlasProfile.isSameDirectory(Paths.appSupportRoot, Paths.standardAppSupportRoot))
    }
}
