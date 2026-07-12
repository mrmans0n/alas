import Testing
@testable import Alas

struct RemoteHostCapabilitiesTests {
    @Test func parsesLinuxHostWithEverything() {
        let output = """
        Linux
        git version 2.43.0
        rg=yes
        zmx=yes
        """
        let capabilities = RemoteHostCapabilities.parse(output)
        #expect(capabilities.os == .linux)
        #expect(capabilities.gitVersion == "2.43.0")
        #expect(capabilities.hasRipgrep)
        #expect(capabilities.hasZmx)
    }

    @Test func parsesMacHostWithoutTools() {
        let output = """
        Darwin
        git version 2.39.5 (Apple Git-154)
        rg=no
        zmx=no
        """
        let capabilities = RemoteHostCapabilities.parse(output)
        #expect(capabilities.os == .macos)
        #expect(capabilities.gitVersion == "2.39.5")
        #expect(!capabilities.hasRipgrep)
        #expect(!capabilities.hasZmx)
    }

    @Test func missingGitYieldsNilVersion() {
        let capabilities = RemoteHostCapabilities.parse("Linux\nrg=no\nzmx=no")
        #expect(capabilities.gitVersion == nil)
        #expect(capabilities.os == .linux)
    }

    @Test func unknownUnameIsOther() {
        #expect(RemoteHostCapabilities.parse("FreeBSD\nrg=no\nzmx=no").os == .other)
        #expect(RemoteHostCapabilities.parse("").os == .other)
    }

    @Test func probeCommandIsPOSIXPortable() {
        #expect(!RemoteHostCapabilities.probeCommand.contains("xargs"))
        #expect(!RemoteHostCapabilities.probeCommand.contains("--"))
    }

    @Test func probeCommandChecksInstalledZmxFallback() {
        #expect(RemoteHostCapabilities.probeCommand.contains("[ -x \"$HOME/.alas/bin/zmx\" ]"))
    }

    @Test func parsesArchAndNormalizesArm64() {
        #expect(RemoteHostCapabilities.parse("Linux\narch=x86_64").arch == "x86_64")
        #expect(RemoteHostCapabilities.parse("Darwin\narch=arm64").arch == "aarch64")
        #expect(RemoteHostCapabilities.parse("Linux").arch == nil)
    }

    @Test func probeCommandEmitsArchLine() {
        #expect(RemoteHostCapabilities.probeCommand.contains("echo \"arch=$(uname -m)\""))
    }
}
