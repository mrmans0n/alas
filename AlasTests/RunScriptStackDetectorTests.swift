import Foundation
import Testing
@testable import Alas

struct RunScriptStackDetectorTests {
    private func makeRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func touch(_ names: String..., in root: URL) throws {
        for name in names {
            try Data().write(to: root.appendingPathComponent(name))
        }
    }

    private func write(_ name: String, _ contents: String, in root: URL) throws {
        try Data(contents.utf8).write(to: root.appendingPathComponent(name))
    }

    private func detect(_ root: URL) -> [RunScriptStack: RunScriptStackContext] {
        Dictionary(uniqueKeysWithValues: RunScriptStackDetector.detect(worktreeRoot: root).map { ($0.stack, $0.context) })
    }

    @Test func emptyDirectoryDetectsNothing() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(RunScriptStackDetector.detect(worktreeRoot: root).isEmpty)
    }

    @Test func missingDirectoryDetectsNothing() {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        #expect(RunScriptStackDetector.detect(worktreeRoot: root).isEmpty)
    }

    @Test("Gradle records whether the project ships a wrapper", arguments: RunScriptStackDetectorTests.gradleWrapperCases)
    func gradleWrapper(_ fixture: DetectorFixture, expected: Bool) throws {
        let context = try detect(fixture)[.gradle]
        #expect(context?.hasWrapper == expected)
    }

    @Test("Gradle records declared and plugin-supplied tasks", arguments: RunScriptStackDetectorTests.gradleTaskCases)
    func gradleTasks(_ fixture: DetectorFixture, expected: Set<String>) throws {
        let context = try detect(fixture)[.gradle]
        #expect(context?.gradleTasks == expected)
    }

    @Test func mavenDetectsWrapper() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try touch("pom.xml", "mvnw", in: root)
        #expect(detect(root)[.maven]?.hasWrapper == true)
    }

    @Test func kotlinToolchainWrapperMustBeARegularFile() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try touch("module.yaml", in: root)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("kotlin"), withIntermediateDirectories: true)
        #expect(detect(root)[.kotlin]?.kotlinWrapper == .system)

        try FileManager.default.removeItem(at: root.appendingPathComponent("kotlin"))
        try touch("kotlin", in: root)
        #expect(detect(root)[.kotlin]?.kotlinWrapper == .kotlin)
    }

    /// module.yaml/project.yaml is shared by legacy Amper and the Kotlin
    /// toolchain that replaced it; a repo that has not migrated still ships
    /// an `amper` wrapper and must not be told to run `kotlin`.
    @Test func kotlinToolchainPrefersAmperWrapperWhenNotYetMigrated() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try touch("module.yaml", "amper", in: root)
        #expect(detect(root)[.kotlin]?.kotlinWrapper == .amper)

        try touch("kotlin", in: root)
        #expect(detect(root)[.kotlin]?.kotlinWrapper == .amper)
    }

    @Test func kotlinToolchainDetectsProjectFile() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try touch("project.yaml", in: root)
        #expect(detect(root)[.kotlin] != nil)
    }

    @Test("Cargo checks run only when exactly one runnable binary resolves", arguments: RunScriptStackDetectorTests.cargoRunnableCases)
    func cargoRunnableTarget(_ fixture: DetectorFixture, expected: Bool) throws {
        let context = try detect(fixture)[.cargo]
        #expect(context?.hasRunnableTarget == expected)
    }

    @Test func cargoDetectsARunnableBinaryThreeWays() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try write("Cargo.toml", "[package]\nname = \"lib\"\n", in: root)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("src"), withIntermediateDirectories: true)
        try touch("src/main.rs", in: root)
        #expect(detect(root)[.cargo]?.hasRunnableTarget == true)

        try FileManager.default.removeItem(at: root.appendingPathComponent("src/main.rs"))
        #expect(detect(root)[.cargo]?.hasRunnableTarget == false)

        try FileManager.default.createDirectory(at: root.appendingPathComponent("src/bin"), withIntermediateDirectories: true)
        try touch("src/bin/tool.rs", in: root)
        #expect(detect(root)[.cargo]?.hasRunnableTarget == true)

        try FileManager.default.removeItem(at: root.appendingPathComponent("src/bin"))
        try write("Cargo.toml", "[package]\nname = \"lib\"\n\n[[bin]]\nname = \"tool\"\n", in: root)
        #expect(detect(root)[.cargo]?.hasRunnableTarget == true)
    }

    @Test func javascriptPicksPackageManagerFromLockfile() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try write("package.json", #"{"scripts":{"dev":"vite","build":"vite build"}}"#, in: root)
        #expect(detect(root)[.javascript]?.packageManager == .npm)
        #expect(detect(root)[.javascript]?.packageScripts == ["dev", "build"])

        try touch("pnpm-lock.yaml", in: root)
        #expect(detect(root)[.javascript]?.packageManager == .pnpm)
        try FileManager.default.removeItem(at: root.appendingPathComponent("pnpm-lock.yaml"))

        try touch("yarn.lock", in: root)
        #expect(detect(root)[.javascript]?.packageManager == .yarn)
        try FileManager.default.removeItem(at: root.appendingPathComponent("yarn.lock"))

        try touch("bun.lock", in: root)
        #expect(detect(root)[.javascript]?.packageManager == .bun)
        try FileManager.default.removeItem(at: root.appendingPathComponent("bun.lock"))

        try touch("bun.lockb", in: root)
        #expect(detect(root)[.javascript]?.packageManager == .bun)
    }

    @Test func javascriptFallsBackToPackageManagerField() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try write("package.json", #"{"packageManager":"yarn@4.1.0","scripts":{}}"#, in: root)
        #expect(detect(root)[.javascript]?.packageManager == .yarn)
        #expect(detect(root)[.javascript]?.packageScripts == [])
    }

    @Test func javascriptWithUnreadablePackageJSONLeavesScriptsUnknown() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try write("package.json", "not json", in: root)
        #expect(detect(root)[.javascript]?.packageScripts == nil)
        #expect(detect(root)[.javascript]?.packageManager == .npm)
    }

    @Test func cmakeHidesPlainMake() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try touch("CMakeLists.txt", "Makefile", in: root)
        let stacks = detect(root)
        #expect(stacks[.cmake] != nil)
        #expect(stacks[.make] == nil)
    }

    @Test("Makefile test and clean target detection", arguments: RunScriptStackDetectorTests.makeTargetCases)
    func makeTargets(_ fixture: DetectorFixture, expected: MakeTargets) throws {
        let context = try detect(fixture)[.make]
        #expect(context?.hasMakeTestTarget == expected.test)
        #expect(context?.hasMakeCleanTarget == expected.clean)
    }

    @Test("Makefile test target detection", arguments: RunScriptStackDetectorTests.makeTestTargetCases)
    func makeTestTarget(_ fixture: DetectorFixture, expected: Bool) throws {
        let context = try detect(fixture)[.make]
        #expect(context?.hasMakeTestTarget == expected)
    }

    @Test func makefileIgnoresTargetsInsideStaticallyInactiveConditionals() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try write(
            "Makefile",
            """
            ifeq (1,0)
            test:
            \techo inactive
            endif

            ifneq "same" "same"
            clean:
            \techo inactive
            endif
            """,
            in: root
        )

        #expect(detect(root)[.make]?.hasMakeTestTarget == false)
        #expect(detect(root)[.make]?.hasMakeCleanTarget == false)

        try write(
            "Makefile",
            """
            ifeq (1,0)
            all:
            \techo inactive
            else
            test:
            \techo active
            endif
            """,
            in: root
        )
        #expect(detect(root)[.make]?.hasMakeTestTarget == true)
    }

    @Test func swiftPackageDetectsManifest() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try write("Package.swift", "let package = Package(name: \"Lib\", targets: [.target(name: \"Lib\")])", in: root)
        #expect(detect(root)[.swiftPackage]?.hasRunnableTarget == false)
        #expect(detect(root)[.swiftPackage]?.hasSwiftTestTarget == false)

        try write(
            "Package.swift",
            "let package = Package(name: \"Tool\", targets: [.executableTarget(name: \"Tool\"), .testTarget(name: \"ToolTests\", dependencies: [\"Tool\"])])",
            in: root
        )
        #expect(detect(root)[.swiftPackage]?.hasRunnableTarget == true)
        #expect(detect(root)[.swiftPackage]?.hasSwiftTestTarget == true)
    }

    @Test func swiftPackageLeavesTestUncheckedWithoutATestTarget() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try write(
            "Package.swift",
            "let package = Package(name: \"Lib\", targets: [.target(name: \"Lib\")])",
            in: root
        )

        #expect(detect(root)[.swiftPackage]?.hasSwiftTestTarget == false)
    }

    @Test("Swift package checks run only when exactly one executable resolves", arguments: RunScriptStackDetectorTests.swiftPackageRunnableCases)
    func swiftPackageRunnableTarget(_ fixture: DetectorFixture, expected: Bool) throws {
        let context = try detect(fixture)[.swiftPackage]
        #expect(context?.hasRunnableTarget == expected)
    }

    @Test func swiftPackageIgnoresExecutableTargetsInInactiveArchitectureBranches() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
#if arch(arm64)
        let inactiveArchitecture = "x86_64"
#else
        let inactiveArchitecture = "arm64"
#endif
        try write(
            "Package.swift",
            """
            #if arch(\(inactiveArchitecture))
            let package = Package(targets: [
                .executableTarget(name: "InactiveTool"),
            ])
            #else
            let package = Package(targets: [
                .target(name: "Lib"),
            ])
            #endif
            """,
            in: root
        )

        #expect(detect(root)[.swiftPackage]?.hasRunnableTarget == false)
    }

    @Test func xcodePrefersWorkspaceOverProject() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root.appendingPathComponent("App.xcodeproj"), withIntermediateDirectories: true)
        #expect(detect(root)[.xcode]?.xcodeContainer == "App.xcodeproj")

        try FileManager.default.createDirectory(at: root.appendingPathComponent("App.xcworkspace"), withIntermediateDirectories: true)
        #expect(detect(root)[.xcode]?.xcodeContainer == "App.xcworkspace")
    }

    @Test("Go resolves the go run target from main packages and build constraints", arguments: RunScriptStackDetectorTests.goRunTargetCases)
    func goRunTarget(_ fixture: DetectorFixture, expected: String?) throws {
        let context = try detect(fixture)[.go]
        #expect(context?.goRunTarget == expected)
    }

    @Test func goIgnoresToolchainIgnoredSourceFilenames() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try touch("go.mod", in: root)
        try write("_main.go", "package main\n\nfunc main() {}\n", in: root)
        #expect(detect(root)[.go]?.goRunTarget == nil)

        try FileManager.default.removeItem(at: root.appendingPathComponent("_main.go"))
        try write(".main.go", "package main\n\nfunc main() {}\n", in: root)
        #expect(detect(root)[.go]?.goRunTarget == nil)
    }

    @Test func goUsesTheCurrentArchitectureForBuildTags() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try touch("go.mod", in: root)
        #if arch(arm64)
        let excludedArchitecture = "amd64"
        #else
        let excludedArchitecture = "arm64"
        #endif
        try write("main.go", "//go:build \(excludedArchitecture)\n\npackage main\n", in: root)
        #expect(detect(root)[.go]?.goRunTarget == nil)
    }

    @Test func goResolvesReleaseTagsForTheDetectedWorktree() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try touch("go.mod", in: root)
        try write("main.go", "//go:build go1.26\n\npackage main\n\nfunc main() {}\n", in: root)
        var resolvedRoots: [URL] = []

        let stacks = Dictionary(uniqueKeysWithValues: RunScriptStackDetector.detect(
            worktreeRoot: root,
            goToolchainEnvironment: { resolvedRoot in
                resolvedRoots.append(resolvedRoot)
                return .init(
                    minorVersion: resolvedRoot == root ? 26 : 1,
                    architectureFeatures: []
                )
            }
        ).map { ($0.stack, $0.context) })

        #expect(resolvedRoots == [root])
        #expect(stacks[.go]?.goRunTarget == ".")
    }

    @Test func goResolvesArchitectureFeatureTagsFromTheToolchain() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try touch("go.mod", in: root)
        let featureTag = "amd64.v2"
        try write("main.go", "//go:build !\(featureTag)\n\npackage main\n\nfunc main() {}\n", in: root)

        let stacks = Dictionary(uniqueKeysWithValues: RunScriptStackDetector.detect(
            worktreeRoot: root,
            goToolchainEnvironment: { _ in
                .init(minorVersion: 25, operatingSystem: "darwin", architecture: "amd64", architectureFeatures: [featureTag])
            }
        ).map { ($0.stack, $0.context) })

        #expect(stacks[.go]?.goRunTarget == nil)
    }

    @Test func goParsesARM64FeatureLevelsWithExtensions() {
        #expect(RunScriptStackDetector.goArchitectureFeatureTags(level: "v8.2,lse", architecture: "arm64").contains("arm64.v8.1"))
        #expect(RunScriptStackDetector.goArchitectureFeatureTags(level: "v9.3,crypto", architecture: "arm64").contains("arm64.v9.3"))
        #expect(RunScriptStackDetector.goArchitectureFeatureTags(level: "v3", architecture: "amd64").contains("amd64.v2"))
    }

    @Test func goResolvesFilenameArchitectureFromTheDetectedToolchain() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try touch("go.mod", in: root)
        try write("main_arm64.go", "package main\n\nfunc main() {}\n", in: root)

        let stacks = Dictionary(uniqueKeysWithValues: RunScriptStackDetector.detect(
            worktreeRoot: root,
            goToolchainEnvironment: { _ in
                .init(minorVersion: 25, operatingSystem: "darwin", architecture: "amd64", architectureFeatures: ["amd64.v1"])
            }
        ).map { ($0.stack, $0.context) })

        #expect(stacks[.go]?.goRunTarget == nil)
    }

    @Test func goResolvesCoreBuildTagsFromTheDetectedToolchain() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try touch("go.mod", in: root)
        try write("main.go", "//go:build arm64\n\npackage main\n\nfunc main() {}\n", in: root)

        let stacks = Dictionary(uniqueKeysWithValues: RunScriptStackDetector.detect(
            worktreeRoot: root,
            goToolchainEnvironment: { _ in
                .init(minorVersion: 25, operatingSystem: "darwin", architecture: "amd64", architectureFeatures: ["amd64.v1"])
            }
        ).map { ($0.stack, $0.context) })

        #expect(stacks[.go]?.goRunTarget == nil)
    }

    @Test func goResolvesGOFLAGSBuildTagsFromTheDetectedToolchain() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try touch("go.mod", in: root)
        try write("main.go", "//go:build !enterprise\n\npackage main\n\nfunc main() {}\n", in: root)

        let stacks = Dictionary(uniqueKeysWithValues: RunScriptStackDetector.detect(
            worktreeRoot: root,
            goToolchainEnvironment: { _ in
                .init(minorVersion: 25, architectureFeatures: [], buildTags: ["enterprise"])
            }
        ).map { ($0.stack, $0.context) })

        #expect(stacks[.go]?.goRunTarget == nil)
    }

    @Test func goResolvesGOFLAGSToolModeTagsFromTheDetectedToolchain() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try touch("go.mod", in: root)
        try write("main.go", "//go:build !race\n\npackage main\n\nfunc main() {}\n", in: root)

        let stacks = Dictionary(uniqueKeysWithValues: RunScriptStackDetector.detect(
            worktreeRoot: root,
            goToolchainEnvironment: { _ in
                .init(minorVersion: 25, architectureFeatures: [], buildTags: RunScriptStackDetector.goBuildTags(fromGOFLAGS: "-race"))
            }
        ).map { ($0.stack, $0.context) })

        #expect(stacks[.go]?.goRunTarget == nil)

        let booleanAssignmentStacks = Dictionary(uniqueKeysWithValues: RunScriptStackDetector.detect(
            worktreeRoot: root,
            goToolchainEnvironment: { _ in
                .init(minorVersion: 25, architectureFeatures: [], buildTags: RunScriptStackDetector.goBuildTags(fromGOFLAGS: "-race=true"))
            }
        ).map { ($0.stack, $0.context) })

        #expect(booleanAssignmentStacks[.go]?.goRunTarget == nil)
    }

    @Test func goResolvesCGOTagFromTheDetectedToolchain() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try touch("go.mod", in: root)
        try write("main.go", "//go:build cgo\n\npackage main\n\nfunc main() {}\n", in: root)

        let cgoDisabled = Dictionary(uniqueKeysWithValues: RunScriptStackDetector.detect(
            worktreeRoot: root,
            goToolchainEnvironment: { _ in
                .init(minorVersion: 25, architectureFeatures: [])
            }
        ).map { ($0.stack, $0.context) })
        #expect(cgoDisabled[.go]?.goRunTarget == nil)

        let cgoEnabled = Dictionary(uniqueKeysWithValues: RunScriptStackDetector.detect(
            worktreeRoot: root,
            goToolchainEnvironment: { _ in
                .init(minorVersion: 25, architectureFeatures: [], cgoEnabled: true)
            }
        ).map { ($0.stack, $0.context) })
        #expect(cgoEnabled[.go]?.goRunTarget == ".")
    }

    @Test func goTreatsImplicitCGOImportAsExcludedWhenCGOIsDisabled() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try touch("go.mod", in: root)
        try write("main.go", "package main\n\nimport \"C\"\n\nfunc main() {}\n", in: root)

        let cgoDisabled = Dictionary(uniqueKeysWithValues: RunScriptStackDetector.detect(
            worktreeRoot: root,
            goToolchainEnvironment: { _ in
                .init(minorVersion: 25, architectureFeatures: [])
            }
        ).map { ($0.stack, $0.context) })
        #expect(cgoDisabled[.go]?.goRunTarget == nil)

        let cgoEnabled = Dictionary(uniqueKeysWithValues: RunScriptStackDetector.detect(
            worktreeRoot: root,
            goToolchainEnvironment: { _ in
                .init(minorVersion: 25, architectureFeatures: [], cgoEnabled: true)
            }
        ).map { ($0.stack, $0.context) })
        #expect(cgoEnabled[.go]?.goRunTarget == ".")
    }

    @Test func goTreatsAliasedCGOImportAsExcludedWhenCGOIsDisabled() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try touch("go.mod", in: root)
        try write("main.go", "package main\n\nimport c \"C\"\n\nfunc main() {}\n", in: root)

        let aliased = Dictionary(uniqueKeysWithValues: RunScriptStackDetector.detect(
            worktreeRoot: root,
            goToolchainEnvironment: { _ in
                .init(minorVersion: 25, architectureFeatures: [])
            }
        ).map { ($0.stack, $0.context) })
        #expect(aliased[.go]?.goRunTarget == nil)

        try write("main.go", "package main\n\nimport (\n  _ \"C\"\n)\n\nfunc main() {}\n", in: root)
        let blankIdentifier = Dictionary(uniqueKeysWithValues: RunScriptStackDetector.detect(
            worktreeRoot: root,
            goToolchainEnvironment: { _ in
                .init(minorVersion: 25, architectureFeatures: [])
            }
        ).map { ($0.stack, $0.context) })
        #expect(blankIdentifier[.go]?.goRunTarget == nil)
    }

    @Test func goTreatsRawStringCGOImportAsExcludedWhenCGOIsDisabled() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try touch("go.mod", in: root)
        try write("main.go", "package main\n\nimport `C`\n\nfunc main() {}\n", in: root)

        let cgoDisabled = Dictionary(uniqueKeysWithValues: RunScriptStackDetector.detect(
            worktreeRoot: root,
            goToolchainEnvironment: { _ in
                .init(minorVersion: 25, architectureFeatures: [])
            }
        ).map { ($0.stack, $0.context) })
        #expect(cgoDisabled[.go]?.goRunTarget == nil)

        try write("main.go", "package main\n\nimport (\n  c `C`\n)\n\nfunc main() {}\n", in: root)
        let aliasedBlock = Dictionary(uniqueKeysWithValues: RunScriptStackDetector.detect(
            worktreeRoot: root,
            goToolchainEnvironment: { _ in
                .init(minorVersion: 25, architectureFeatures: [])
            }
        ).map { ($0.stack, $0.context) })
        #expect(aliasedBlock[.go]?.goRunTarget == nil)
    }

    @Test func goDoesNotSelectRunForForeignTargetPlatforms() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try touch("go.mod", in: root)
        try write("main.go", "package main\n\nfunc main() {}\n", in: root)

        let foreignTarget = Dictionary(uniqueKeysWithValues: RunScriptStackDetector.detect(
            worktreeRoot: root,
            goToolchainEnvironment: { _ in
                .init(
                    minorVersion: 25,
                    operatingSystem: "linux",
                    architecture: GoToolchainEnvironment.hostArchitecture,
                    architectureFeatures: []
                )
            }
        ).map { ($0.stack, $0.context) })

        #expect(foreignTarget[.go]?.goRunTarget == nil)
    }

    @Test func goTreatsTargetDefaultRegabiArgsAsEnabled() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try touch("go.mod", in: root)
        try write("main.go", "//go:build !goexperiment.regabiargs\n\npackage main\n\nfunc main() {}\n", in: root)

        let stacks = Dictionary(uniqueKeysWithValues: RunScriptStackDetector.detect(
            worktreeRoot: root,
            goToolchainEnvironment: { _ in
                .init(
                    minorVersion: 25,
                    operatingSystem: "darwin",
                    architecture: GoToolchainEnvironment.hostArchitecture,
                    architectureFeatures: []
                )
            }
        ).map { ($0.stack, $0.context) })

        #expect(stacks[.go]?.goRunTarget == nil)
    }

    @Test func goTreatsGo125DefaultExperimentTagsAsEnabled() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try touch("go.mod", in: root)
        try write("main.go", "//go:build !goexperiment.swissmap\n\npackage main\n\nfunc main() {}\n", in: root)

        let stacks = Dictionary(uniqueKeysWithValues: RunScriptStackDetector.detect(
            worktreeRoot: root,
            goToolchainEnvironment: { _ in
                .init(
                    minorVersion: 25,
                    operatingSystem: "darwin",
                    architecture: "amd64",
                    architectureFeatures: []
                )
            }
        ).map { ($0.stack, $0.context) })

        #expect(stacks[.go]?.goRunTarget == nil)
    }

    @Test func goTreatsDefaultArchitectureFeatureTagsAsEnabled() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try touch("go.mod", in: root)
        #if arch(arm64)
        let featureTag = "arm64.v8.0"
        #else
        let featureTag = "amd64.v1"
        #endif
        try write("main.go", "//go:build !\(featureTag)\n\npackage main\n\nfunc main() {}\n", in: root)

        #expect(detect(root)[.go]?.goRunTarget == nil)
    }

    /// A root library with the command living under cmd/ is not itself
    /// runnable — `go run .` fails there even though `go run ./cmd/tool`
    /// would succeed.
    @Test func goPointsAtTheActualCommandUnderCmd() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try write("go.mod", "module example.com/tool\n", in: root)
        try write("lib.go", "package tool\n\nfunc DoThing() {}\n", in: root)
        let cmdToolDir = root.appendingPathComponent("cmd/tool", isDirectory: true)
        try FileManager.default.createDirectory(at: cmdToolDir, withIntermediateDirectories: true)
        #expect(detect(root)[.go]?.goRunTarget == nil, "an empty cmd/ directory confirms nothing")

        try Data("package main\n\nfunc main() {}\n".utf8).write(to: cmdToolDir.appendingPathComponent("main.go"))
        #expect(detect(root)[.go]?.goRunTarget == "./cmd/tool")
    }

    @Test func goLeavesRunUncheckedWhenMultipleCommandsExist() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try write("go.mod", "module example.com/tools\n", in: root)
        for name in ["api", "worker"] {
            let commandDirectory = root.appendingPathComponent("cmd/\(name)", isDirectory: true)
            try FileManager.default.createDirectory(at: commandDirectory, withIntermediateDirectories: true)
            try Data("package main\n\nfunc main() {}\n".utf8).write(to: commandDirectory.appendingPathComponent("main.go"))
        }

        #expect(detect(root)[.go]?.goRunTarget == nil)
    }

    @Test func pythonPicksRunnerFromLockfile() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try touch("pyproject.toml", in: root)
        #expect(detect(root)[.python]?.pythonRunner == .bare)

        try touch("poetry.lock", in: root)
        #expect(detect(root)[.python]?.pythonRunner == .poetry)

        try touch("uv.lock", in: root)
        #expect(detect(root)[.python]?.pythonRunner == .uv)
    }

    @Test func pythonDetectsRequirementsOnlyProjects() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try touch("requirements.txt", in: root)

        #expect(detect(root)[.python]?.hasRequirementsFile == true)
    }

    @Test func resultsFollowCatalogOrder() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try touch("go.mod", "Cargo.toml", "package.json", "gradlew", in: root)
        let stacks = RunScriptStackDetector.detect(worktreeRoot: root).map(\.stack)
        #expect(stacks == [.javascript, .gradle, .go, .cargo])
    }

    @Test func railsHidesPlainRubyAndReadsProjectLayout() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try touch("Gemfile", in: root)
        #expect(detect(root)[.ruby] != nil)
        #expect(detect(root)[.rails] == nil)

        try FileManager.default.createDirectory(at: root.appendingPathComponent("bin"), withIntermediateDirectories: true)
        try touch("bin/rails", ".rubocop.yml", in: root)
        try write("Gemfile", "source \"https://rubygems.org\"\ngem \"rails\"\ngem \"rspec-rails\"\ngem \"rubocop\"\n", in: root)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("spec"), withIntermediateDirectories: true)
        let stacks = detect(root)
        #expect(stacks[.ruby] == nil)
        #expect(stacks[.rails]?.hasSpecDirectory == true)
        #expect(stacks[.rails]?.hasRubocopConfig == true)
    }

    @Test func rubocopRequiresDeclaredBundleDependency() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root.appendingPathComponent("bin"), withIntermediateDirectories: true)
        try touch("bin/rails", ".rubocop.yml", in: root)
        try write("Gemfile", "source \"https://rubygems.org\"\ngem \"rails\"\n", in: root)

        #expect(detect(root)[.rails]?.hasRubocopConfig == false)

        try write("Gemfile", "source \"https://rubygems.org\"\ngem \"rails\"\ngem \"rubocop\"\n", in: root)
        #expect(detect(root)[.rails]?.hasRubocopConfig == true)

        try FileManager.default.removeItem(at: root.appendingPathComponent("bin/rails"))
        #expect(detect(root)[.ruby]?.hasRubocopConfig == true)
    }

    @Test func rspecRequiresDeclaredBundleDependency() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root.appendingPathComponent("bin"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("spec"), withIntermediateDirectories: true)
        try touch("bin/rails", in: root)
        try write("Gemfile", "source \"https://rubygems.org\"\ngem \"rails\"\n", in: root)

        #expect(detect(root)[.rails]?.hasSpecDirectory == false)

        try write("Gemfile", "source \"https://rubygems.org\"\ngem \"rails\"\ngem \"rspec-rails\"\n", in: root)
        #expect(detect(root)[.rails]?.hasSpecDirectory == true)

        try FileManager.default.removeItem(at: root.appendingPathComponent("bin/rails"))
        #expect(detect(root)[.ruby]?.hasSpecDirectory == true)
    }

    @Test("Ruby records a statically reachable Rake test task", arguments: RunScriptStackDetectorTests.rakeTestTaskCases)
    func rakeTestTask(_ fixture: DetectorFixture, expected: Bool) throws {
        let context = try detect(fixture)[.ruby]
        #expect(context?.hasRakeTestTask == expected)
    }

    @Test func djangoDetectsManageAndSharesPythonRunner() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try touch("manage.py", "requirements.txt", "uv.lock", in: root)
        let stacks = detect(root)
        #expect(stacks[.django]?.pythonRunner == .uv)
        #expect(stacks[.django]?.hasRequirementsFile == true)
        #expect(stacks[.python] == nil)
    }

    /// A typical Django repo also has a pyproject.toml; generic Python must
    /// defer to Django the same way Ruby defers to Rails.
    @Test func djangoHidesGenericPythonEvenWithPyprojectPresent() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try touch("manage.py", "pyproject.toml", in: root)
        let stacks = detect(root)
        #expect(stacks[.django] != nil)
        #expect(stacks[.python] == nil)
    }

    @Test func djangoPreservesPyprojectContext() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try touch("manage.py", "pyproject.toml", in: root)

        #expect(detect(root)[.django]?.hasPyprojectFile == true)
    }

    @Test("Python confirms pytest and ruff only from active dependency declarations", arguments: RunScriptStackDetectorTests.pythonToolCases)
    func pythonTools(_ fixture: DetectorFixture, expected: PythonTools) throws {
        let context = try detect(fixture)[.python]
        #expect(context?.hasPytest == expected.pytest)
        #expect(context?.hasRuff == expected.ruff)
    }

    @Test("Python ignores pytest dependencies excluded by environment markers", arguments: RunScriptStackDetectorTests.pythonPytestCases)
    func pythonPytest(_ fixture: DetectorFixture, expected: Bool) throws {
        let context = try detect(fixture)[.python]
        #expect(context?.hasPytest == expected)
    }

    @Test func laravelHidesPlainComposer() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try touch("composer.json", in: root)
        #expect(detect(root)[.php] != nil)
        try touch("artisan", in: root)
        #expect(detect(root)[.php] == nil)
        #expect(detect(root)[.laravel] != nil)
    }

    @Test func phpRecordsWhetherPHPUnitIsAvailable() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try write("composer.json", #"{"require":{"monolog/monolog":"^3"}}"#, in: root)
        #expect(detect(root)[.php]?.hasPHPUnit == false)

        try write("composer.json", #"{"require-dev":{"phpunit/phpunit":"^11"}}"#, in: root)
        #expect(detect(root)[.php]?.hasPHPUnit == true)
        #expect(detect(root)[.php]?.phpUnitBinaryPath == "vendor/bin/phpunit")

        try write("composer.json", #"{"require-dev":{"phpunit/phpunit":"^11"},"config":{"bin-dir":"bin"}}"#, in: root)
        #expect(detect(root)[.php]?.hasPHPUnit == true)
        #expect(detect(root)[.php]?.phpUnitBinaryPath == "bin/phpunit")

        try write("composer.json", #"{"require-dev":{"phpunit/phpunit":"^11"},"config":{"vendor-dir":"third_party/vendor"}}"#, in: root)
        #expect(detect(root)[.php]?.hasPHPUnit == true)
        #expect(detect(root)[.php]?.phpUnitBinaryPath == "third_party/vendor/bin/phpunit")

        try write("composer.json", #"{"scripts":{"test":"vendor/bin/phpunit"}}"#, in: root)
        #expect(detect(root)[.php]?.hasPHPUnit == false)

        try FileManager.default.createDirectory(at: root.appendingPathComponent("vendor/bin"), withIntermediateDirectories: true)
        try touch("vendor/bin/phpunit", in: root)
        #expect(detect(root)[.php]?.hasPHPUnit == true)
    }

    @Test func dotnetDetectsSolutionOrProjectFiles() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try touch("App.csproj", in: root)
        #expect(detect(root)[.dotnet] != nil)
    }

    @Test(".NET resolves a single executable project to run", arguments: RunScriptStackDetectorTests.dotnetRunProjectCases)
    func dotnetRunProject(_ fixture: DetectorFixture, expected: String?) throws {
        let context = try detect(fixture)[.dotnet]
        #expect(context?.dotnetRunProject == expected)
    }

    @Test func dotnetRecordsAnUnambiguousRootBuildTarget() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try write("App.sln", "", in: root)
        #expect(detect(root)[.dotnet]?.dotnetBuildTarget == "App.sln")
        #expect(detect(root)[.dotnet]?.dotnetCommandsChecked == true)

        try write("Other.sln", "", in: root)
        #expect(detect(root)[.dotnet]?.dotnetBuildTarget == nil)
        #expect(detect(root)[.dotnet]?.dotnetCommandsChecked == false)
    }

    @Test("Flutter detects a real dependency on the Flutter SDK", arguments: RunScriptStackDetectorTests.flutterSDKCases)
    func flutterSDK(_ fixture: DetectorFixture, expected: Bool) throws {
        let context = try detect(fixture)[.flutter]
        #expect(context?.usesFlutter == expected)
    }

    @Test("Elixir detects a real dependency on Phoenix", arguments: RunScriptStackDetectorTests.phoenixCases)
    func phoenixDependency(_ fixture: DetectorFixture, expected: Bool) throws {
        let context = try detect(fixture)[.elixir]
        #expect(context?.usesPhoenix == expected)
    }

    @Test func remainingMarkersDetectTheirStacks() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try touch("deno.jsonc", "build.zig", "MODULE.bazel", "compose.yaml", in: root)
        let stacks = detect(root)
        #expect(stacks[.deno] != nil)
        #expect(stacks[.zig] != nil)
        #expect(stacks[.bazel] != nil)
        #expect(stacks[.compose] != nil)
    }

    @Test("Zig records declared build steps", arguments: RunScriptStackDetectorTests.zigBuildStepCases)
    func zigBuildSteps(_ fixture: DetectorFixture, expected: Set<String>) throws {
        let context = try detect(fixture)[.zig]
        #expect(context?.zigBuildSteps == expected)
    }

    @Test("Deno reads declared task names", arguments: RunScriptStackDetectorTests.denoTaskCases)
    func denoTasks(_ fixture: DetectorFixture, expected: Set<String>?) throws {
        let context = try detect(fixture)[.deno]
        #expect(context?.denoTasks == expected)
    }
}

extension RunScriptStackDetectorTests {
    /// A worktree to build for one detection: directories are created first,
    /// then empty files touched, then files written with their contents.
    struct DetectorFixture: Sendable, CustomTestStringConvertible {
        let name: String
        var directories: [String] = []
        var touched: [String] = []
        var files: [(String, String)] = []

        init(_ name: String, directories: [String] = [], touched: [String] = [], files: [(String, String)] = []) {
            self.name = name
            self.directories = directories
            self.touched = touched
            self.files = files
        }

        var testDescription: String { name }
    }

    struct PythonTools: Sendable, CustomTestStringConvertible {
        let pytest: Bool
        let ruff: Bool

        var testDescription: String { "pytest: \(pytest), ruff: \(ruff)" }
    }

    struct MakeTargets: Sendable, CustomTestStringConvertible {
        let test: Bool
        let clean: Bool

        var testDescription: String { "test: \(test), clean: \(clean)" }
    }

    /// Builds the fixture in a fresh temporary worktree and runs detection.
    func detect(_ fixture: DetectorFixture) throws -> [RunScriptStack: RunScriptStackContext] {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        for directory in fixture.directories {
            try FileManager.default.createDirectory(at: root.appendingPathComponent(directory), withIntermediateDirectories: true)
        }
        for name in fixture.touched {
            try touch(name, in: root)
        }
        for (name, contents) in fixture.files {
            try write(name, contents, in: root)
        }
        return detect(root)
    }

    static let gradleWrapperCases: [(DetectorFixture, Bool)] = [
        (DetectorFixture("gradle wrapper is recorded", touched: ["gradlew", "settings.gradle.kts"]), true),
        (DetectorFixture("gradle without wrapper uses system tool", touched: ["build.gradle"]), false),
    ]

    static let gradleTaskCases: [(DetectorFixture, Set<String>)] = [
        (DetectorFixture("gradle records only declared tasks", files: [
            ("build.gradle.kts", """
                tasks.register("hello")
                // tasks.register("test")
                """),
        ]), ["hello"]),
        (DetectorFixture("gradle ignores task syntax inside string literals", files: [
            ("build.gradle", #"def docs = 'tasks.register("test")'"#),
        ]), []),
        (DetectorFixture("gradle ignores task syntax inside slashy string literals, step 1 of 2", files: [
            ("build.gradle", #"def docs = /tasks.register("test")/"#),
        ]), []),
        (DetectorFixture("gradle ignores task syntax inside slashy string literals, step 2 of 2", files: [
            ("build.gradle", #"def docs = $/tasks.register("check")/$"#),
        ]), []),
        (DetectorFixture("gradle records tasks supplied by the java plugin", files: [
            ("build.gradle", "plugins { id \"java\" }\n"),
        ]), ["assemble", "check", "clean", "test"]),
        (DetectorFixture("gradle records tasks supplied by legacy applied java plugin", files: [
            ("build.gradle", "apply plugin: 'java'\n"),
        ]), ["assemble", "check", "clean", "test"]),
        (DetectorFixture("gradle ignores plugins in statically inactive branches", files: [
            ("build.gradle", """
                if (false) {
                    apply plugin: 'java'
                    tasks.register("test")
                }
                """),
        ]), []),
        (DetectorFixture("gradle records tasks supplied by the groovy plugin", files: [
            ("build.gradle", "plugins { id 'groovy' }\n"),
        ]), ["assemble", "check", "clean", "test"]),
        (DetectorFixture("gradle records tasks supplied by kotlin DSL plugin accessors, step 1 of 3", files: [
            ("build.gradle.kts", "plugins { java }\n"),
        ]), ["assemble", "check", "clean", "test"]),
        (DetectorFixture("gradle records tasks supplied by kotlin DSL plugin accessors, step 2 of 3", files: [
            ("build.gradle.kts", "plugins { application }\n"),
        ]), ["assemble", "check", "clean", "test"]),
        (DetectorFixture("gradle records tasks supplied by kotlin DSL plugin accessors, step 3 of 3", files: [
            ("build.gradle.kts", "plugins { `java-library` }\n"),
        ]), ["assemble", "check", "clean", "test"]),
        (DetectorFixture("gradle ignores plugins declared only in settings", files: [
            ("settings.gradle", "pluginManagement { plugins { id 'java' } }\n"),
        ]), []),
        (DetectorFixture("gradle ignores plugin syntax inside string literals, step 1 of 2", files: [
            ("build.gradle", #"def documentation = "id 'java'""#),
        ]), []),
        (DetectorFixture("gradle ignores plugin syntax inside string literals, step 2 of 2", files: [
            ("build.gradle", #"def documentation = 'id "java"'"#),
        ]), []),
    ]

    static let cargoRunnableCases: [(DetectorFixture, Bool)] = [
        (DetectorFixture("cargo detects manifest", touched: ["Cargo.toml"]), false),
        // `cargo run` refuses to guess between multiple binaries unless
        // `default-run` resolves the ambiguity.
        (DetectorFixture("cargo leaves multiple binaries unchecked without a default run, step 1 of 2", directories: ["src/bin"], touched: ["src/bin/one.rs", "src/bin/two.rs"], files: [
            ("Cargo.toml", "[package]\nname = \"lib\"\n"),
        ]), false),
        (DetectorFixture("cargo leaves multiple binaries unchecked without a default run, step 2 of 2", directories: ["src/bin"], touched: ["src/bin/one.rs", "src/bin/two.rs"], files: [
            ("Cargo.toml", "[package]\nname = \"lib\"\ndefault-run = \"one\"\n"),
        ]), true),
        (DetectorFixture("cargo default run must be declared by the package table", directories: ["src/bin"], touched: ["src/bin/one.rs", "src/bin/two.rs"], files: [
            ("Cargo.toml", """
                [package]
                name = "lib"

                [package.metadata.alas]
                default-run = "one"
                """),
        ]), false),
        (DetectorFixture("cargo does not double count an explicit root main binary", directories: ["src"], touched: ["src/main.rs"], files: [
            ("Cargo.toml", "[package]\nname = \"tool\"\n\n[[bin]]\nname = \"tool\"\npath = \"src/main.rs\"\n"),
        ]), true),
        (DetectorFixture("cargo counts directory form bin targets, step 1 of 2", directories: ["src", "src/bin/helper"], touched: ["src/main.rs", "src/bin/helper/main.rs"], files: [
            ("Cargo.toml", "[package]\nname = \"tool\"\n"),
        ]), false),
        (DetectorFixture("cargo counts directory form bin targets, step 2 of 2", directories: ["src", "src/bin/helper"], touched: ["src/main.rs", "src/bin/helper/main.rs"], files: [
            ("Cargo.toml", "[package]\nname = \"tool\"\ndefault-run = \"tool\"\n"),
        ]), true),
        (DetectorFixture("cargo honors disabled automatic binary targets, step 1 of 2", directories: ["src", "src/bin/helper"], touched: ["src/main.rs", "src/bin/helper/main.rs"], files: [
            ("Cargo.toml", "[package]\nname = \"tool\"\nautobins = false\n"),
        ]), false),
        (DetectorFixture("cargo honors disabled automatic binary targets, step 2 of 2", directories: ["src", "src/bin/helper"], touched: ["src/main.rs", "src/bin/helper/main.rs"], files: [
            ("Cargo.toml", "[package]\nname = \"tool\"\nautobins = false\n\n[[bin]]\nname = \"tool\"\npath = \"src/main.rs\"\n"),
        ]), true),
        (DetectorFixture("cargo leaves feature gated binaries unchecked", directories: ["src"], touched: ["src/main.rs"], files: [
            ("Cargo.toml", """
                [package]
                name = "tool"

                [[bin]]
                name = "tool"
                path = "src/main.rs"
                required-features = ["cli"]
                """),
        ]), false),
        (DetectorFixture("cargo default run must not select feature gated binary", directories: ["src/bin"], touched: ["src/bin/gated.rs", "src/bin/plain.rs"], files: [
            ("Cargo.toml", """
                [package]
                name = "tools"
                default-run = "gated"

                [[bin]]
                name = "gated"
                path = "src/bin/gated.rs"
                required-features = ["cli"]

                [[bin]]
                name = "plain"
                path = "src/bin/plain.rs"
                """),
        ]), false),
        (DetectorFixture("cargo allows required features enabled by default", directories: ["src"], touched: ["src/main.rs"], files: [
            ("Cargo.toml", """
                [package]
                name = "tool"

                [features]
                default = ["cli"]
                cli = []

                [[bin]]
                name = "tool"
                path = "src/main.rs"
                required-features = ["cli"]
                """),
        ]), true),
        (DetectorFixture("cargo ignores commented out default features", directories: ["src"], touched: ["src/main.rs"], files: [
            ("Cargo.toml", """
                [package]
                name = "tool"

                [features]
                default = [ # "cli"
                ]
                cli = []

                [[bin]]
                name = "tool"
                path = "src/main.rs"
                required-features = ["cli"]
                """),
        ]), false),
        (DetectorFixture("cargo does not treat default optional dependencies as package features", directories: ["src"], touched: ["src/main.rs"], files: [
            ("Cargo.toml", """
                [package]
                name = "tool"

                [features]
                default = ["dep:cli"]
                cli = []

                [[bin]]
                name = "tool"
                path = "src/main.rs"
                required-features = ["cli"]
                """),
        ]), false),
        (DetectorFixture("cargo parses single quoted required features", directories: ["src"], touched: ["src/main.rs"], files: [
            ("Cargo.toml", """
                [package]
                name = "tool"

                [[bin]]
                name = "tool"
                path = "src/main.rs"
                required-features = ['cli']
                """),
        ]), false),
        (DetectorFixture("cargo parses single quoted bin names before checking features", directories: ["src"], touched: ["src/main.rs"], files: [
            ("Cargo.toml", """
                [package]
                name = "tool"

                [[bin]]
                name = 'tool'
                path = "src/main.rs"
                required-features = ['cli']
                """),
        ]), false),
        (DetectorFixture("cargo ignores bin tables inside multiline strings", files: [
            ("Cargo.toml", """
                [package]
                name = "library"

                [package.metadata.docs]
                example = '''
                [[bin]]
                name = "fake"
                '''
                """),
        ]), false),
    ]

    static let makeTargetCases: [(DetectorFixture, MakeTargets)] = [
        (DetectorFixture("plain makefile detects make", touched: ["GNUmakefile"]), MakeTargets(test: false, clean: false)),
        (DetectorFixture("makefile reads its declared targets, step 1 of 3", files: [
            ("Makefile", "all:\n\techo build\n\ntest: all\n\techo test\n"),
        ]), MakeTargets(test: true, clean: false)),
        (DetectorFixture("makefile reads its declared targets, step 2 of 3", files: [
            ("Makefile", "CFLAGS := -O2\n\nclean:\n\trm -rf build\n"),
        ]), MakeTargets(test: false, clean: true)),
        (DetectorFixture("makefile reads its declared targets, step 3 of 3", files: [
            ("Makefile", "all test clean:\n\techo combined\n"),
        ]), MakeTargets(test: true, clean: true)),
        (DetectorFixture("makefile ignores simple assignment operators", files: [
            ("Makefile", "test := integration\nclean ?= distclean\nall:\n\techo build\n"),
        ]), MakeTargets(test: false, clean: false)),
        (DetectorFixture("makefile allows space indented targets", files: [
            ("Makefile", "  test:\n\techo test\n\tclean:\n\techo not a clean rule\n"),
        ]), MakeTargets(test: true, clean: false)),
    ]

    static let makeTestTargetCases: [(DetectorFixture, Bool)] = [
        // A column-zero comment like "# test: disabled" must not read as a
        // rule for "test" just because it splits into that token before a colon.
        (DetectorFixture("makefile ignores comment lines, step 1 of 2", files: [
            ("Makefile", "# test: disabled\n\nall:\n\techo build\n"),
        ]), false),
        (DetectorFixture("makefile ignores comment lines, step 2 of 2", files: [
            ("Makefile", "test: build ## runs the test suite\n\techo test\n"),
        ]), true),
        (DetectorFixture("makefile ignores targets inside unresolved conditionals", files: [
            ("Makefile", """
                MODE = prod
                ifneq ($(MODE),prod)
                test:
                \techo inactive after expansion
                endif
                """),
        ]), false),
    ]

    static let swiftPackageRunnableCases: [(DetectorFixture, Bool)] = [
        // `swift run` with no argument only resolves when there's exactly one
        // executable to pick; with two, it exits requiring a name.
        (DetectorFixture("swift package leaves multiple executables unchecked", files: [
            ("Package.swift", "let package = Package(targets: [.executableTarget(name: \"A\"), .executableTarget(name: \"B\")])"),
        ]), false),
        // A commented-out `.executableTarget` is Swift source, not a real
        // target — Package.swift's `//` comments apply the same as anywhere
        // else.
        (DetectorFixture("swift package ignores a commented out executable target", files: [
            ("Package.swift", "let package = Package(targets: [\n  .target(name: \"Lib\"),\n  // .executableTarget(name: \"Removed\"),\n])"),
        ]), false),
        (DetectorFixture("swift package ignores executable targets in inactive OS branches", files: [
            ("Package.swift", """
                let package = Package(targets: [
                #if os(Linux)
                    .executableTarget(name: "LinuxTool"),
                #endif
                    .target(name: "Lib"),
                ])
                """),
        ]), false),
        (DetectorFixture("swift package ignores executable targets inside nested block comments", files: [
            ("Package.swift", """
                import PackageDescription
                let package = Package(
                    name: "Lib",
                    targets: [
                        .target(name: "Lib"),
                        /*
                        /*
                         Inner comment.
                         */
                        .executableTarget(name: "Fake")
                        */
                    ]
                )
                """),
        ]), false),
        (DetectorFixture("swift package ignores executable targets in inactive compound OS branches", files: [
            ("Package.swift", """
                let package = Package(targets: [
                #if os(Linux) && swift(>=5.9)
                    .executableTarget(name: "LinuxTool"),
                #endif
                    .target(name: "Lib"),
                ])
                """),
        ]), false),
        (DetectorFixture("swift package ignores executable targets in parenthesized inactive OS branches", files: [
            ("Package.swift", """
                let package = Package(targets: [
                #if (os(Linux))
                    .executableTarget(name: "LinuxTool"),
                #endif
                    .target(name: "Lib"),
                ])
                """),
        ]), false),
        (DetectorFixture("swift package ignores executable targets in false branches", files: [
            ("Package.swift", """
                let package = Package(targets: [
                #if false
                    .executableTarget(name: "NeverTool"),
                #else
                    .target(name: "Lib"),
                #endif
                ])
                """),
        ]), false),
        (DetectorFixture("swift package recognizes compact conditional directives", files: [
            ("Package.swift", """
                #if(os(macOS))
                let package = Package(targets: [
                    .target(name: "Lib"),
                ])
                #else
                let package = Package(targets: [
                    .executableTarget(name: "OtherTool"),
                ])
                #endif
                """),
        ]), false),
        (DetectorFixture("swift package leaves run unchecked for unresolved conditions", files: [
            ("Package.swift", """
                import PackageDescription
                let package = Package(
                    name: "App",
                    products: [
                #if swift(>=999.0)
                        .executable(name: "App", targets: ["App"]),
                #else
                        .library(name: "App", targets: ["App"]),
                #endif
                    ],
                    targets: [.target(name: "App")]
                )
                """),
        ]), false),
        (DetectorFixture("swift package leaves run unchecked for unavailable imports", files: [
            ("Package.swift", """
                import PackageDescription
                let package = Package(
                    name: "App",
                    products: [
                #if canImport(DefinitelyMissingModule)
                        .executable(name: "App", targets: ["App"]),
                #else
                        .library(name: "App", targets: ["App"]),
                #endif
                    ],
                    targets: [.target(name: "App")]
                )
                """),
        ]), false),
        (DetectorFixture("swift package leaves run unchecked for negated unknown imports", files: [
            ("Package.swift", """
                import PackageDescription
                let package = Package(
                    name: "App",
                    products: [
                #if !canImport(PackageDescription)
                        .executable(name: "App", targets: ["App"]),
                #else
                        .library(name: "App", targets: ["App"]),
                #endif
                    ],
                    targets: [.target(name: "App")]
                )
                """),
        ]), false),
        (DetectorFixture("swift package does not activate else after unknown import conditions", files: [
            ("Package.swift", """
                import PackageDescription
                let package = Package(
                    name: "App",
                    products: [
                #if canImport(PackageDescription)
                        .library(name: "App", targets: ["App"]),
                #else
                        .executable(name: "App", targets: ["App"]),
                #endif
                    ],
                    targets: [.target(name: "App")]
                )
                """),
        ]), false),
        (DetectorFixture("swift package uses manifest tools version for swift conditions", files: [
            ("Package.swift", """
                // swift-tools-version: 6.0
                import PackageDescription
                #if swift(<6.0)
                let targets: [Target] = [.executableTarget(name: "Tool")]
                #else
                let targets: [Target] = [.target(name: "Lib")]
                #endif
                let package = Package(name: "Lib", targets: targets)
                """),
        ]), false),
        (DetectorFixture("swift package leaves compiler conditions unchecked", files: [
            ("Package.swift", """
                import PackageDescription
                #if compiler(>=5.0)
                let targets: [Target] = [.executableTarget(name: "Tool")]
                #else
                let targets: [Target] = [.target(name: "Lib")]
                #endif
                let package = Package(name: "Lib", targets: targets)
                """),
        ]), false),
        (DetectorFixture("swift package leaves run unchecked for unknown conditions", files: [
            ("Package.swift", """
                import PackageDescription
                #if DEBUG
                let targets: [Target] = [.executableTarget(name: "Tool")]
                #else
                let targets: [Target] = [.target(name: "Lib")]
                #endif
                let package = Package(name: "Lib", targets: targets)
                """),
        ]), false),
        (DetectorFixture("swift package ignores executable targets inside string literals", files: [
            ("Package.swift", #"""
                let docs = """
                .executableTarget(name: "Fake")
                """
                let package = Package(targets: [
                    .target(name: "Lib"),
                ])
                """#),
        ]), false),
        (DetectorFixture("swift package ignores executable targets inside raw string literals", files: [
            ("Package.swift", """
                let docs = #"Example " .executableTarget(name: "Fake") text"#
                let package = Package(targets: [
                    .target(name: "Lib"),
                ])
                """),
        ]), false),
        (DetectorFixture("swift package recognizes the older executable product form", files: [
            ("Package.swift", "products: [.executable(name: \"Tool\", targets: [\"Tool\"])], targets: [.target(name: \"Tool\", type: .executable)]"),
        ]), true),
        (DetectorFixture("swift package recognizes an executable product with a regular target", files: [
            ("Package.swift", "products: [.executable(name: \"Tool\", targets: [\"Tool\"])], targets: [.target(name: \"Tool\")]"),
        ]), true),
        (DetectorFixture("swift package leaves mixed executable declarations unchecked", files: [
            ("Package.swift", "products: [.executable(name: \"Tool\", targets: [\"Tool\"])], targets: [.executableTarget(name: \"Other\")]"),
        ]), false),
        (DetectorFixture("swift package deduplicates executable products from their targets", files: [
            ("Package.swift", "products: [.executable(name: \"app\", targets: [\"App\"])], targets: [.executableTarget(name: \"App\")]"),
        ]), true),
    ]

    static let goRunTargetCases: [(DetectorFixture, String?)] = [
        (DetectorFixture("go detects module", touched: ["go.mod"]), nil),
        (DetectorFixture("go prefers a root main package, step 1 of 2", touched: ["go.mod"], files: [
            ("lib.go", "package mylib\n\nfunc DoThing() {}\n"),
        ]), nil),
        (DetectorFixture("go prefers a root main package, step 2 of 2", touched: ["go.mod"], files: [
            ("lib.go", "package mylib\n\nfunc DoThing() {}\n"),
            ("main.go", "package main\n\nfunc main() {}\n"),
        ]), "."),
        (DetectorFixture("go ignores main files excluded from the current host, step 1 of 3", touched: ["go.mod"], files: [
            ("main_linux.go", "package main\n\nfunc main() {}\n"),
        ]), nil),
        (DetectorFixture("go ignores main files excluded from the current host, step 2 of 3", touched: ["go.mod"], files: [
            ("main_linux.go", "package main\n\nfunc main() {}\n"),
            ("main.go", "//go:build linux\n\npackage main\n\nfunc main() {}\n"),
        ]), nil),
        (DetectorFixture("go ignores main files excluded from the current host, step 3 of 3", touched: ["go.mod"], files: [
            ("main_linux.go", "package main\n\nfunc main() {}\n"),
            ("main.go", "// +build linux\n\npackage main\n\nfunc main() {}\n"),
        ]), nil),
        (DetectorFixture("go only uses trailing filename build constraints", touched: ["go.mod"], files: [
            ("main_linux_helper.go", "package main\n\nfunc main() {}\n"),
        ]), "."),
        (DetectorFixture("go reads the actual package clause", touched: ["go.mod"], files: [
            ("main.go", """
                /*
                package main
                */
                package library

                const text = `
                package main
                `
                """),
        ]), nil),
        (DetectorFixture("go uses satisfied release build tags", touched: ["go.mod"], files: [
            ("main.go", "//go:build !go1.20\n\npackage main\n\nfunc main() {}\n"),
        ]), nil),
        (DetectorFixture("go does not assume newest release build tags are enabled", touched: ["go.mod"], files: [
            ("main.go", "//go:build go1.999\n\npackage main\n\nfunc main() {}\n"),
        ]), nil),
        (DetectorFixture("go derives newest release tags from the installed toolchain", touched: ["go.mod"], files: [
            ("main.go", "//go:build !go1.25\n\npackage main\n\nfunc main() {}\n"),
        ]), nil),
        (DetectorFixture("go accepts leading whitespace on build constraints, step 1 of 2", touched: ["go.mod"], files: [
            ("main.go", "  //go:build custom\n\npackage main\n\nfunc main() {}\n"),
        ]), nil),
        (DetectorFixture("go accepts leading whitespace on build constraints, step 2 of 2", touched: ["go.mod"], files: [
            ("main.go", "  // +build custom\n\npackage main\n\nfunc main() {}\n"),
        ]), nil),
        (DetectorFixture("go treats the standard compiler tag as enabled", touched: ["go.mod"], files: [
            ("main.go", "//go:build !gc\n\npackage main\n\nfunc main() {}\n"),
        ]), nil),
        (DetectorFixture("go treats default experiment tags as enabled", touched: ["go.mod"], files: [
            ("main.go", "//go:build !goexperiment.regabiwrappers\n\npackage main\n\nfunc main() {}\n"),
        ]), nil),
        (DetectorFixture("go requires a main function before preselecting run, step 1 of 2", touched: ["go.mod"], files: [
            ("main.go", "package main\n\nfunc helper() {}\n"),
        ]), nil),
        (DetectorFixture("go requires a main function before preselecting run, step 2 of 2", touched: ["go.mod"], files: [
            ("main.go", "package main\n\nfunc main() {}\n"),
        ]), "."),
    ]

    static let rakeTestTaskCases: [(DetectorFixture, Bool)] = [
        (DetectorFixture("ruby records declared rake test task, step 1 of 12", files: [
            ("Gemfile", "source \"https://rubygems.org\"\ngem \"rake\"\n"),
        ]), false),
        (DetectorFixture("ruby records declared rake test task, step 2 of 12", files: [
            ("Gemfile", "source \"https://rubygems.org\"\ngem \"rake\"\n"),
            ("Rakefile", "# task :test\n"),
        ]), false),
        (DetectorFixture("ruby records declared rake test task, step 3 of 12", files: [
            ("Gemfile", "source \"https://rubygems.org\"\ngem \"rake\"\n"),
            ("Rakefile", "namespace :foo do\n  task :test\nend\n"),
        ]), false),
        (DetectorFixture("ruby records declared rake test task, step 4 of 12", files: [
            ("Gemfile", "source \"https://rubygems.org\"\ngem \"rake\"\n"),
            ("Rakefile", "namespace :foo do\n  if true\n  end\n  task :test\nend\n"),
        ]), false),
        (DetectorFixture("ruby records declared rake test task, step 5 of 12", files: [
            ("Gemfile", "source \"https://rubygems.org\"\ngem \"rake\"\n"),
            ("Rakefile", "namespace(:foo) {\n  task :test\n}\n"),
        ]), false),
        (DetectorFixture("ruby records declared rake test task, step 6 of 12", files: [
            ("Gemfile", "source \"https://rubygems.org\"\ngem \"rake\"\n"),
            ("Rakefile", "docs = <<~TEXT\n  task :test\nTEXT\n"),
        ]), false),
        (DetectorFixture("ruby records declared rake test task, step 7 of 12", files: [
            ("Gemfile", "source \"https://rubygems.org\"\ngem \"rake\"\n"),
            ("Rakefile", "docs = \"\"\"\n  task :test\n\"\"\"\n"),
        ]), false),
        (DetectorFixture("ruby records declared rake test task, step 8 of 12", files: [
            ("Gemfile", "source \"https://rubygems.org\"\ngem \"rake\"\n"),
            ("Rakefile", "docs = '\n  task :test\n'\n"),
        ]), false),
        (DetectorFixture("ruby records declared rake test task, step 9 of 12", files: [
            ("Gemfile", "source \"https://rubygems.org\"\ngem \"rake\"\n"),
            ("Rakefile", "task :test do\n  ruby \"test/all_test.rb\"\nend\n"),
        ]), true),
        (DetectorFixture("ruby records declared rake test task, step 10 of 12", files: [
            ("Gemfile", "source \"https://rubygems.org\"\ngem \"rake\"\n"),
            ("Rakefile", "task(:test) do\n  ruby \"test/all_test.rb\"\nend\n"),
        ]), true),
        (DetectorFixture("ruby records declared rake test task, step 11 of 12", files: [
            ("Gemfile", "source \"https://rubygems.org\"\ngem \"rake\"\n"),
            ("Rakefile", "task(\"test\") do\n  ruby \"test/all_test.rb\"\nend\n"),
        ]), true),
        (DetectorFixture("ruby records declared rake test task, step 12 of 12", files: [
            ("Gemfile", "source \"https://rubygems.org\"\ngem \"rake\"\n"),
            ("Rakefile", "task test: :prepare do\n  ruby \"test/all_test.rb\"\nend\n"),
        ]), true),
        (DetectorFixture("ruby ignores rake tasks inside uncalled methods", files: [
            ("Gemfile", "source \"https://rubygems.org\"\ngem \"rake\"\n"),
            ("Rakefile", "def register_tasks\n  task :test do\n    ruby \"test/all_test.rb\"\n  end\nend\n"),
        ]), false),
        (DetectorFixture("ruby ignores rake tasks inside uncalled proc and lambda blocks, step 1 of 3", files: [
            ("Gemfile", "source \"https://rubygems.org\"\ngem \"rake\"\n"),
            ("Rakefile", "register = proc do\n  task :test\nend\n"),
        ]), false),
        (DetectorFixture("ruby ignores rake tasks inside uncalled proc and lambda blocks, step 2 of 3", files: [
            ("Gemfile", "source \"https://rubygems.org\"\ngem \"rake\"\n"),
            ("Rakefile", "register = -> do\n  task :test\nend\n"),
        ]), false),
        (DetectorFixture("ruby ignores rake tasks inside uncalled proc and lambda blocks, step 3 of 3", files: [
            ("Gemfile", "source \"https://rubygems.org\"\ngem \"rake\"\n"),
            ("Rakefile", "register = lambda { task :test }\n"),
        ]), false),
        (DetectorFixture("ruby ignores rake tasks inside statically false branches, step 1 of 3", files: [
            ("Gemfile", "source \"https://rubygems.org\"\ngem \"rake\"\n"),
            ("Rakefile", "if false\n  task :test do\n    ruby \"test/all_test.rb\"\n  end\nend\n"),
        ]), false),
        (DetectorFixture("ruby ignores rake tasks inside statically false branches, step 2 of 3", files: [
            ("Gemfile", "source \"https://rubygems.org\"\ngem \"rake\"\n"),
            ("Rakefile", "task :test if false\n"),
        ]), false),
        (DetectorFixture("ruby ignores rake tasks inside statically false branches, step 3 of 3", files: [
            ("Gemfile", "source \"https://rubygems.org\"\ngem \"rake\"\n"),
            ("Rakefile", "task :test unless true\n"),
        ]), false),
        (DetectorFixture("ruby ignores rake tasks inside runtime conditional branches, step 1 of 2", files: [
            ("Gemfile", "source \"https://rubygems.org\"\ngem \"rake\"\n"),
            ("Rakefile", "if ENV[\"CI\"]\n  task :test\nend\n"),
        ]), false),
        (DetectorFixture("ruby ignores rake tasks inside runtime conditional branches, step 2 of 2", files: [
            ("Gemfile", "source \"https://rubygems.org\"\ngem \"rake\"\n"),
            ("Rakefile", "unless ENV[\"SKIP_TEST\"]\n  task :test\nend\n"),
        ]), false),
    ]

    static let pythonToolCases: [(DetectorFixture, PythonTools)] = [
        // A runtime-only library that never mentions pytest or ruff most likely
        // doesn't have either installed; confirming pytest/ruff use requires
        // finding a real mention in pyproject.toml.
        (DetectorFixture("python only checks tools pyproject actually mentions, step 1 of 2", files: [
            ("pyproject.toml", "[project]\nname = \"lib\"\ndependencies = []\n"),
        ]), PythonTools(pytest: false, ruff: false)),
        (DetectorFixture("python only checks tools pyproject actually mentions, step 2 of 2", files: [
            ("pyproject.toml", "[project]\nname = \"lib\"\ndependencies = [\"pytest\", \"ruff\"]\n"),
        ]), PythonTools(pytest: true, ruff: true)),
        (DetectorFixture("python detects tools declared in requirements", files: [
            ("requirements.txt", "pytest==8.4.0\nruff>=0.12\n"),
        ]), PythonTools(pytest: true, ruff: true)),
        (DetectorFixture("python ignores requirements excluded by environment markers", files: [
            ("requirements.txt", "pytest; sys_platform == \"win32\"\nruff; sys_platform != \"darwin\"\n"),
        ]), PythonTools(pytest: false, ruff: false)),
        (DetectorFixture("python preserves URL fragments before evaluating requirement markers", files: [
            ("requirements.txt", """
                pytest @ file:///pkg.whl#sha256=deadbeef ; sys_platform == "win32"
                ruff @ file:///ruff.whl#sha256=feedface ; sys_platform == "darwin"
                """),
        ]), PythonTools(pytest: false, ruff: true)),
        (DetectorFixture("python ignores requirements excluded by python version markers", files: [
            ("requirements.txt", "pytest; python_version < \"3.1\"\nruff; python_version >= \"4\"\n"),
        ]), PythonTools(pytest: false, ruff: false)),
        (DetectorFixture("python uses interpreter platform machine for markers", files: [
            ("requirements.txt", "pytest; platform_machine == \"amd64\"\nruff; platform_machine != \"amd64\"\n"),
        ]), PythonTools(pytest: false, ruff: true)),
        (DetectorFixture("python ignores wildcard version markers that exclude current interpreter", files: [
            ("requirements.txt", "pytest; python_full_version != \"3.*\"\nruff; python_full_version == \"3.*\"\n"),
        ]), PythonTools(pytest: false, ruff: true)),
        (DetectorFixture("python ignores dependency group entries excluded by environment markers", touched: ["uv.lock"], files: [
            ("pyproject.toml", """
                [project]
                name = "lib"
                dependencies = []

                [dependency-groups]
                dev = ["pytest; sys_platform == 'win32'", "ruff; python_version >= '4'"]
                """),
        ]), PythonTools(pytest: false, ruff: false)),
        (DetectorFixture("python ignores requirements with unsupported markers", files: [
            ("requirements.txt", "pytest; extra == \"test\"\nruff; unknown_marker == \"yes\"\n"),
        ]), PythonTools(pytest: false, ruff: false)),
        (DetectorFixture("python bare runner ignores dependency groups for tool availability", files: [
            ("pyproject.toml", """
                [project]
                name = "lib"
                dependencies = []

                [dependency-groups]
                dev = ["pytest", "ruff"]
                """),
        ]), PythonTools(pytest: false, ruff: false)),
        (DetectorFixture("python UV runner ignores non default dependency groups for tool availability, step 1 of 2", touched: ["uv.lock"], files: [
            ("pyproject.toml", """
                [project]
                name = "lib"
                dependencies = []

                [dependency-groups]
                lint = ["ruff"]
                test = ["pytest"]
                """),
        ]), PythonTools(pytest: false, ruff: false)),
        (DetectorFixture("python UV runner ignores non default dependency groups for tool availability, step 2 of 2", touched: ["uv.lock"], files: [
            ("pyproject.toml", """
                [project]
                name = "lib"
                dependencies = []

                [dependency-groups]
                lint = ["ruff"]
                test = ["pytest"]

                [tool.uv]
                default-groups = ["lint", "test"]
                """),
        ]), PythonTools(pytest: true, ruff: true)),
        (DetectorFixture("python UV runner includes implicit dev dependency group for tool availability", touched: ["uv.lock"], files: [
            ("pyproject.toml", """
                [project]
                name = "lib"
                dependencies = []

                [dependency-groups]
                dev = ["pytest", "ruff"]
                """),
        ]), PythonTools(pytest: true, ruff: true)),
        (DetectorFixture("python UV runner uses project python version for markers", touched: ["uv.lock"], files: [
            (".python-version", "3.12\n"),
            ("pyproject.toml", """
                [project]
                name = "lib"
                dependencies = []

                [dependency-groups]
                dev = ["pytest; python_version >= '3.14'", "ruff; python_version == '3.12'"]
                """),
        ]), PythonTools(pytest: false, ruff: true)),
        (DetectorFixture("python UV partial version does not satisfy full version markers", touched: ["uv.lock"], files: [
            (".python-version", "3.12\n"),
            ("pyproject.toml", """
                [project]
                name = "lib"
                dependencies = []

                [dependency-groups]
                dev = ["pytest; python_full_version < '3.12.1'", "ruff; python_version == '3.12'"]
                """),
        ]), PythonTools(pytest: false, ruff: true)),
        (DetectorFixture("python bare runner ignores optional extras for tool availability", files: [
            ("pyproject.toml", """
                [project]
                name = "lib"
                dependencies = []

                [project.optional-dependencies]
                dev = ["pytest", "ruff"]
                """),
        ]), PythonTools(pytest: false, ruff: false)),
        (DetectorFixture("python UV runner ignores optional extras for tool availability", touched: ["uv.lock"], files: [
            ("pyproject.toml", """
                [project]
                name = "lib"
                dependencies = []

                [project.optional-dependencies]
                dev = ["pytest", "ruff"]
                """),
        ]), PythonTools(pytest: false, ruff: false)),
        (DetectorFixture("python ignores build system requirements for tool availability", files: [
            ("pyproject.toml", """
                [project]
                name = "lib"
                dependencies = []

                [build-system]
                requires = ["setuptools", "pytest", "ruff"]
                build-backend = "setuptools.build_meta"
                """),
        ]), PythonTools(pytest: false, ruff: false)),
        (DetectorFixture("python ignores tool config without a dependency", files: [
            ("pyproject.toml", """
                [project]
                name = "lib"
                dependencies = []

                [tool.pytest.ini_options]
                testpaths = ["tests"]

                [tool.ruff]
                line-length = 120
                """),
        ]), PythonTools(pytest: false, ruff: false)),
        (DetectorFixture("python reads poetry dependency tables", touched: ["poetry.lock"], files: [
            ("pyproject.toml", """
                [tool.poetry]
                name = "lib"

                [tool.poetry.group.test.dependencies]
                pytest = "^8"

                [tool.poetry.dev-dependencies]
                ruff = "^0.8"
                """),
        ]), PythonTools(pytest: true, ruff: true)),
        (DetectorFixture("python ignores poetry dependencies excluded by native python constraint", touched: ["poetry.lock"], files: [
            ("pyproject.toml", """
                [tool.poetry]
                name = "lib"

                [tool.poetry.dependencies]
                pytest = { version = "^8", python = "<3.1" }
                ruff = { version = "^0.8", python = ">=3.1" }
                """),
        ]), PythonTools(pytest: false, ruff: true)),
        (DetectorFixture("bare python ignores poetry dependency tables", files: [
            ("pyproject.toml", """
                [tool.poetry]
                name = "lib"

                [tool.poetry.group.test.dependencies]
                pytest = "^8"

                [tool.poetry.dev-dependencies]
                ruff = "^0.8"
                """),
        ]), PythonTools(pytest: false, ruff: false)),
        (DetectorFixture("python ignores optional poetry groups for tool availability", touched: ["poetry.lock"], files: [
            ("pyproject.toml", """
                [tool.poetry]
                name = "lib"

                [tool.poetry.group.test]
                optional = true

                [tool.poetry.group.test.dependencies]
                pytest = "^8"

                [tool.poetry.group.lint]
                optional = true

                [tool.poetry.group.lint.dependencies]
                ruff = "^0.8"
                """),
        ]), PythonTools(pytest: false, ruff: false)),
        (DetectorFixture("python ignores unrelated project arrays when detecting tools", files: [
            ("pyproject.toml", """
                [project]
                name = "lib"
                dependencies = []
                keywords = ["pytest", "ruff"]
                """),
        ]), PythonTools(pytest: false, ruff: false)),
        (DetectorFixture("python ignores commented out tool mentions", files: [
            ("pyproject.toml", """
                [project]
                name = "lib"
                dependencies = []
                # pytest = "^8"
                # ruff was removed from this project
                """),
        ]), PythonTools(pytest: false, ruff: false)),
        (DetectorFixture("python ignores tool mentions in unrelated metadata", files: [
            ("pyproject.toml", """
                [project]
                name = "lib"
                description = "Works without pytest or ruff"
                dependencies = []
                """),
        ]), PythonTools(pytest: false, ruff: false)),
    ]

    static let pythonPytestCases: [(DetectorFixture, Bool)] = [
        (DetectorFixture("python ignores pyproject dependencies excluded by environment markers", files: [
            ("pyproject.toml", """
                [project]
                name = "lib"
                dependencies = ["pytest; sys_platform == 'win32'"]
                """),
        ]), false),
        (DetectorFixture("python ignores poetry dependencies excluded by environment markers", touched: ["poetry.lock"], files: [
            ("pyproject.toml", """
                [project]
                name = "lib"
                dependencies = []

                [tool.poetry.dependencies]
                pytest = { version = "^8", markers = "sys_platform == 'win32'" }
                """),
        ]), false),
    ]

    static let dotnetRunProjectCases: [(DetectorFixture, String?)] = [
        (DetectorFixture("dotnet finds an executable project at the root", files: [
            ("App.csproj", "<Project><PropertyGroup><OutputType>Exe</OutputType></PropertyGroup></Project>"),
        ]), "App.csproj"),
        (DetectorFixture("dotnet recognizes web SDK projects as executable", files: [
            ("App.csproj", #"<Project Sdk="Microsoft.NET.Sdk.Web"></Project>"#),
        ]), "App.csproj"),
        // A root .sln with no runnable project at the worktree root: only a
        // project under a subdirectory whose OutputType is actually executable
        // counts, not a library alongside it.
        // Detection reads the solution's own project references rather than
        // walking the worktree, so an unreferenced project on disk doesn't
        // count and a large monorepo isn't scanned end to end.
        (DetectorFixture("dotnet finds an executable project under the solution layout, step 1 of 3", directories: ["src/App.Lib"], files: [
            ("src/App.Lib/App.Lib.csproj", "<Project><PropertyGroup><OutputType>Library</OutputType></PropertyGroup></Project>"),
            ("App.sln", """
                Microsoft Visual Studio Solution File, Format Version 12.00
                Project("{FAE04EC0-301F-11D3-BF4B-00C04F79EFBC}") = "App.Lib", "src\\App.Lib\\App.Lib.csproj", "{11111111-1111-1111-1111-111111111111}"
                EndProject
                """),
        ]), nil),
        (DetectorFixture("dotnet finds an executable project under the solution layout, step 2 of 3", directories: ["src/App.Lib", "src/App.Cli"], files: [
            ("src/App.Lib/App.Lib.csproj", "<Project><PropertyGroup><OutputType>Library</OutputType></PropertyGroup></Project>"),
            ("src/App.Cli/App.Cli.csproj", "<Project><PropertyGroup><OutputType>Exe</OutputType></PropertyGroup></Project>"),
            ("App.sln", """
                Microsoft Visual Studio Solution File, Format Version 12.00
                Project("{FAE04EC0-301F-11D3-BF4B-00C04F79EFBC}") = "App.Lib", "src\\App.Lib\\App.Lib.csproj", "{11111111-1111-1111-1111-111111111111}"
                EndProject
                Project("{FAE04EC0-301F-11D3-BF4B-00C04F79EFBC}") = "App.Cli", "src\\App.Cli\\App.Cli.csproj", "{22222222-2222-2222-2222-222222222222}"
                EndProject
                """),
        ]), "src/App.Cli/App.Cli.csproj"),
        // A project that exists on disk but isn't referenced by the
        // solution must not be discovered by scanning the tree for it.
        (DetectorFixture("dotnet finds an executable project under the solution layout, step 3 of 3", directories: ["src/App.Lib", "src/App.Cli", "unreferenced"], files: [
            ("src/App.Lib/App.Lib.csproj", "<Project><PropertyGroup><OutputType>Library</OutputType></PropertyGroup></Project>"),
            ("src/App.Cli/App.Cli.csproj", "<Project><PropertyGroup><OutputType>Exe</OutputType></PropertyGroup></Project>"),
            ("App.sln", """
                Microsoft Visual Studio Solution File, Format Version 12.00
                Project("{FAE04EC0-301F-11D3-BF4B-00C04F79EFBC}") = "App.Lib", "src\\App.Lib\\App.Lib.csproj", "{11111111-1111-1111-1111-111111111111}"
                EndProject
                Project("{FAE04EC0-301F-11D3-BF4B-00C04F79EFBC}") = "App.Cli", "src\\App.Cli\\App.Cli.csproj", "{22222222-2222-2222-2222-222222222222}"
                EndProject
                """),
            ("unreferenced/Stray.csproj", "<Project><PropertyGroup><OutputType>Exe</OutputType></PropertyGroup></Project>"),
        ]), "src/App.Cli/App.Cli.csproj"),
        (DetectorFixture("dotnet leaves multiple executable projects unchecked", files: [
            ("One.csproj", "<OutputType>Exe</OutputType>"),
            ("Two.csproj", "<OutputType>WinExe</OutputType>"),
        ]), nil),
        (DetectorFixture("dotnet aggregates executable projects from all root solutions", directories: ["src/One", "src/Two"], files: [
            ("src/One/One.csproj", "<OutputType>Exe</OutputType>"),
            ("src/Two/Two.csproj", "<OutputType>Exe</OutputType>"),
            ("One.sln", """
                Microsoft Visual Studio Solution File, Format Version 12.00
                Project("{FAE04EC0-301F-11D3-BF4B-00C04F79EFBC}") = "One", "src\\One\\One.csproj", "{11111111-1111-1111-1111-111111111111}"
                EndProject
                """),
            ("Two.sln", """
                Microsoft Visual Studio Solution File, Format Version 12.00
                Project("{FAE04EC0-301F-11D3-BF4B-00C04F79EFBC}") = "Two", "src\\Two\\Two.csproj", "{22222222-2222-2222-2222-222222222222}"
                EndProject
                """),
        ]), nil),
    ]

    static let flutterSDKCases: [(DetectorFixture, Bool)] = [
        (DetectorFixture("flutter reads pubspec for the SDK, step 1 of 2", files: [
            ("pubspec.yaml", "name: app\ndependencies:\n  flutter:\n    sdk: flutter\n"),
        ]), true),
        (DetectorFixture("flutter reads pubspec for the SDK, step 2 of 2", files: [
            ("pubspec.yaml", "name: tool\ndependencies:\n  args: ^2.0.0\n"),
        ]), false),
        // A word-mention of Flutter — in a description, or a `flutter_lints`
        // dev dependency — is not the same as depending on the Flutter SDK.
        (DetectorFixture("flutter does not fire on a word mention or lints package", files: [
            ("pubspec.yaml", "name: tool\ndescription: A CLI used by Flutter clients.\ndependencies:\n  args: ^2.0.0\ndev_dependencies:\n  flutter_lints: ^3.0.0\n"),
        ]), false),
        (DetectorFixture("flutter recognizes flow style and a comment between flutter and SDK, step 1 of 2", files: [
            ("pubspec.yaml", "name: app\ndependencies:\n  flutter: { sdk: flutter }\n"),
        ]), true),
        (DetectorFixture("flutter recognizes flow style and a comment between flutter and SDK, step 2 of 2", files: [
            ("pubspec.yaml", "name: app\ndependencies:\n  flutter:\n    # pinned to the stable channel\n    sdk: flutter\n"),
        ]), true),
        (DetectorFixture("flutter accepts quoted SDK scalars, step 1 of 2", files: [
            ("pubspec.yaml", "name: app\ndependencies:\n  flutter:\n    sdk: \"flutter\"\n"),
        ]), true),
        (DetectorFixture("flutter accepts quoted SDK scalars, step 2 of 2", files: [
            ("pubspec.yaml", "name: app\ndependencies:\n  flutter: { sdk: 'flutter' }\n"),
        ]), true),
        // A fully inline dependencies block: "flutter" is never a line's own
        // key because the whole map lives on one line.
        (DetectorFixture("flutter recognizes a fully inline dependencies block", files: [
            ("pubspec.yaml", "name: app\ndependencies: { flutter: { sdk: flutter } }\n"),
        ]), true),
        (DetectorFixture("flutter recognizes multiline flow dependencies block", files: [
            ("pubspec.yaml", """
                name: app
                dependencies: {
                  flutter: { sdk: flutter }
                }
                """),
        ]), true),
        // The inline-flow fallback must not fire on a mention left inside a
        // comment for a Dart-only package.
        (DetectorFixture("flutter inline fallback ignores comments", files: [
            ("pubspec.yaml", "name: tool\n# flutter: { sdk: flutter }\ndependencies:\n  args: ^2.0.0\n"),
        ]), false),
        (DetectorFixture("flutter inline fallback is limited to dependencies", files: [
            ("pubspec.yaml", "name: tool\ndescription: \"flutter: { sdk: flutter }\"\ndependencies:\n  args: ^2.0.0\n"),
        ]), false),
    ]

    static let phoenixCases: [(DetectorFixture, Bool)] = [
        (DetectorFixture("elixir reads mix for phoenix, step 1 of 2", files: [
            ("mix.exs", "defp deps do\n  [{:phoenix, \"~> 1.7\"}]\nend\n"),
        ]), true),
        (DetectorFixture("elixir reads mix for phoenix, step 2 of 2", files: [
            ("mix.exs", "defp deps do\n  []\nend\n"),
        ]), false),
        (DetectorFixture("elixir ignores a commented out phoenix dependency", files: [
            ("mix.exs", "defp deps do\n  [\n    # {:phoenix, \"~> 1.7\"}\n  ]\nend\n"),
        ]), false),
        // A word mention inside a string literal — a package description, say —
        // is not a dependency declaration.
        (DetectorFixture("elixir ignores a phoenix mention inside a string literal", files: [
            ("mix.exs", "def project do\n  [description: \"Utilities for :phoenix integrations\"]\nend\ndefp deps do\n  []\nend\n"),
        ]), false),
        (DetectorFixture("elixir ignores a phoenix tuple inside a string literal", files: [
            ("mix.exs", #"""
                def project do
                  [description: ~s/Example tuple {:phoenix, "~> 1.7"}/]
                end
                defp deps do
                  []
                end
                """#),
        ]), false),
        // `:phoenix_pubsub` and `:phoenix_live_view` share a prefix with
        // `:phoenix` but are not the Phoenix web framework itself.
        (DetectorFixture("elixir does not treat phoenix prefixed packages as phoenix", files: [
            ("mix.exs", "defp deps do\n  [{:phoenix_pubsub, \"~> 2.1\"}, {:phoenix_live_view, \"~> 0.20\"}]\nend\n"),
        ]), false),
    ]

    static let zigBuildStepCases: [(DetectorFixture, Set<String>)] = [
        (DetectorFixture("zig records declared build steps", files: [
            ("build.zig", """
                pub fn build(b: *std.Build) void {
                    _ = b.step("test", "Run unit tests");
                    _ = b.step("run", "Run the app");
                }
                """),
        ]), ["test", "run"]),
        (DetectorFixture("zig ignores commented out build steps", files: [
            ("build.zig", """
                pub fn build(b: *std.Build) void {
                    // _ = b.step("test", "Run unit tests");
                    _ = b.step("run", "Run the app");
                }
                """),
        ]), ["run"]),
        (DetectorFixture("zig ignores build steps inside strings", files: [
            ("build.zig", """
                pub fn build(b: *std.Build) void {
                    const help = ".step(\\"test\\", \\"example\\")";
                    _ = b.step("run", "Run the app");
                }
                """),
        ]), ["run"]),
        (DetectorFixture("zig ignores build steps inside multiline strings", files: [
            ("build.zig", """
                pub fn build(b: *std.Build) void {
                    const help =
                        \\\\.step("test", "example")
                    ;
                    _ = b.step("run", "Run the app");
                }
                """),
        ]), ["run"]),
    ]

    static let denoTaskCases: [(DetectorFixture, Set<String>?)] = [
        (DetectorFixture("deno reads declared task names, step 1 of 2", files: [
            ("deno.json", #"{"tasks":{"dev":"deno run --watch main.ts"}}"#),
        ]), ["dev"]),
        (DetectorFixture("deno reads declared task names, step 2 of 2", files: [
            ("deno.json", #"{"tasks":{"build":"deno compile main.ts"}}"#),
        ]), ["build"]),
        (DetectorFixture("deno parses JSONC comments and trailing commas", files: [
            ("deno.jsonc", """
                // project config
                {
                  "tasks": {
                    "dev": "deno run --watch main.ts", // dev server
                  },
                }
                """),
        ]), ["dev"]),
        (DetectorFixture("deno with genuinely malformed config leaves tasks unknown", files: [
            ("deno.jsonc", "{ this is not json at all"),
        ]), nil),
    ]
}
