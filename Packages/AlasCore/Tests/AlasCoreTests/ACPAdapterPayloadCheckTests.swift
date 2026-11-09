import Foundation
import Testing
import AlasCore

private let node = AgentPath.resolveExecutable(
    named: "node", base: ProcessInfo.processInfo.environment["PATH"], wellKnown: AgentPath.wellKnownDirectories)

/// Runs the check's Node script against package trees shaped like npm's.
@Suite(.enabled(if: node != nil, "needs node on PATH"))
struct ACPAdapterPayloadCheckTests {
    private static let platform = "\(nodePlatform)-\(nodeArch)"
    private static var nodePlatform: String {
        #if os(macOS)
        "darwin"
        #else
        "linux"
        #endif
    }
    private static var nodeArch: String {
        #if arch(arm64)
        "arm64"
        #else
        "x64"
        #endif
    }

    enum Layout: String, CaseIterable, Sendable {
        /// npm's usual layout: the platform package beside its parent.
        case hoisted
        /// Installed under the parent's own node_modules.
        case nested
        /// npm skipped the platform package.
        case missing
        /// Only other platforms are declared, so nothing applies here.
        case otherPlatformsOnly
        /// A libc variant (`-musl`) satisfies the platform.
        case variantOnly
    }

    @Test(arguments: Layout.allCases)
    func reportsOnlySkippedPlatformPackages(layout: Layout) async throws {
        let adapter = FileManager.default.temporaryDirectory
            .appendingPathComponent("alas-payload-\(UUID().uuidString)/adapter")
        defer { try? FileManager.default.removeItem(at: adapter.deletingLastPathComponent()) }
        let sdk = adapter.appendingPathComponent("node_modules/@vendor/sdk")
        let optional: [String] = layout == .otherPlatformsOnly
            ? ["@vendor/sdk-plan9-mips"]
            : ["@vendor/sdk-\(Self.platform)", "@vendor/sdk-\(Self.platform)-musl", "@vendor/sdk-plan9-mips"]
        try Self.package(at: adapter, manifest: ["name": "adapter"])
        try Self.package(at: sdk, manifest: [
            "name": "@vendor/sdk",
            "optionalDependencies": Dictionary(uniqueKeysWithValues: optional.map { ($0, "1.0.0") }),
        ])
        switch layout {
        case .hoisted:
            try Self.package(at: adapter.appendingPathComponent("node_modules/@vendor/sdk-\(Self.platform)"))
        case .nested:
            try Self.package(at: sdk.appendingPathComponent("node_modules/@vendor/sdk-\(Self.platform)"))
        case .variantOnly:
            try Self.package(at: adapter.appendingPathComponent("node_modules/@vendor/sdk-\(Self.platform)-musl"))
        case .missing, .otherPlatformsOnly:
            break
        }

        let missing = await ACPAdapterPayloadCheck.missingPackages(
            packageDirectory: adapter.path, node: try #require(node), env: ProcessInfo.processInfo.environment)

        #expect(missing == (layout == .missing ? ["@vendor/sdk-\(Self.platform)"] : []))
    }

    private static func package(at directory: URL, manifest: [String: Any] = [:]) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: manifest)
            .write(to: directory.appendingPathComponent("package.json"))
    }
}
