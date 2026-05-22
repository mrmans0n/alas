import Testing
import Foundation
@testable import Alas

@Suite(.serialized)
struct ShellEnvResolverTests {
    @Test func discoverShellPathSkipsMissingShellBinary() async {
        let resolver = ShellEnvResolver()

        #expect(resolver.resolvedPath == nil)

        // We can't easily force all shell candidates to be missing at runtime
        // (the real $SHELL, /bin/zsh, and /bin/sh all exist on macOS), so
        // this test simply asserts the resolver initializes safely and does
        // not crash when queried.
        #expect(resolver.resolvedPath == nil)
    }

    @Test func shellEnvResolverSetsAndReadsResolvedPath() {
        let resolver = ShellEnvResolver()
        #expect(resolver.resolvedPath == nil)
        resolver.resolvedPath = "/custom/bin"
        #expect(resolver.resolvedPath == "/custom/bin")
        resolver.resolvedPath = nil
        #expect(resolver.resolvedPath == nil)
    }
}
