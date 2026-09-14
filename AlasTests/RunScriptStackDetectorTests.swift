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

    @Test func gradleWrapperIsRecorded() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try touch("gradlew", "settings.gradle.kts", in: root)
        #expect(detect(root)[.gradle]?.hasWrapper == true)
    }

    @Test func gradleWithoutWrapperUsesSystemTool() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try touch("build.gradle", in: root)
        #expect(detect(root)[.gradle]?.hasWrapper == false)
    }

    @Test func gradleRecordsOnlyDeclaredTasks() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try write(
            "build.gradle.kts",
            """
            tasks.register("hello")
            // tasks.register("test")
            """,
            in: root
        )

        #expect(detect(root)[.gradle]?.gradleTasks == ["hello"])
    }

    @Test func gradleIgnoresTaskSyntaxInsideStringLiterals() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try write("build.gradle", #"def docs = 'tasks.register("test")'"#, in: root)

        #expect(detect(root)[.gradle]?.gradleTasks == [])
    }

    @Test func gradleIgnoresTaskSyntaxInsideSlashyStringLiterals() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try write("build.gradle", #"def docs = /tasks.register("test")/"#, in: root)

        #expect(detect(root)[.gradle]?.gradleTasks == [])

        try write("build.gradle", #"def docs = $/tasks.register("check")/$"#, in: root)
        #expect(detect(root)[.gradle]?.gradleTasks == [])
    }

    @Test func gradleRecordsTasksSuppliedByTheJavaPlugin() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try write("build.gradle", "plugins { id \"java\" }\n", in: root)

        #expect(detect(root)[.gradle]?.gradleTasks == ["assemble", "check", "clean", "test"])
    }

    @Test func gradleRecordsTasksSuppliedByLegacyAppliedJavaPlugin() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try write("build.gradle", "apply plugin: 'java'\n", in: root)

        #expect(detect(root)[.gradle]?.gradleTasks == ["assemble", "check", "clean", "test"])
    }

    @Test func gradleRecordsTasksSuppliedByTheGroovyPlugin() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try write("build.gradle", "plugins { id 'groovy' }\n", in: root)

        #expect(detect(root)[.gradle]?.gradleTasks == ["assemble", "check", "clean", "test"])
    }

    @Test func gradleRecordsTasksSuppliedByKotlinDSLPluginAccessors() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        try write("build.gradle.kts", "plugins { java }\n", in: root)
        #expect(detect(root)[.gradle]?.gradleTasks == ["assemble", "check", "clean", "test"])

        try write("build.gradle.kts", "plugins { application }\n", in: root)
        #expect(detect(root)[.gradle]?.gradleTasks == ["assemble", "check", "clean", "test"])

        try write("build.gradle.kts", "plugins { `java-library` }\n", in: root)
        #expect(detect(root)[.gradle]?.gradleTasks == ["assemble", "check", "clean", "test"])
    }

    @Test func gradleIgnoresPluginsDeclaredOnlyInSettings() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try write("settings.gradle", "pluginManagement { plugins { id 'java' } }\n", in: root)

        #expect(detect(root)[.gradle]?.gradleTasks == [])
    }

    @Test func gradleIgnoresPluginSyntaxInsideStringLiterals() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try write("build.gradle", #"def documentation = "id 'java'""#, in: root)

        #expect(detect(root)[.gradle]?.gradleTasks == [])

        try write("build.gradle", #"def documentation = 'id "java"'"#, in: root)
        #expect(detect(root)[.gradle]?.gradleTasks == [])
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

    @Test func cargoDetectsManifest() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try touch("Cargo.toml", in: root)
        #expect(detect(root)[.cargo]?.hasRunnableTarget == false)
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

    /// `cargo run` refuses to guess between multiple binaries unless
    /// `default-run` resolves the ambiguity.
    @Test func cargoLeavesMultipleBinariesUncheckedWithoutADefaultRun() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try write("Cargo.toml", "[package]\nname = \"lib\"\n", in: root)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("src/bin"), withIntermediateDirectories: true)
        try touch("src/bin/one.rs", "src/bin/two.rs", in: root)
        #expect(detect(root)[.cargo]?.hasRunnableTarget == false)

        try write("Cargo.toml", "[package]\nname = \"lib\"\ndefault-run = \"one\"\n", in: root)
        #expect(detect(root)[.cargo]?.hasRunnableTarget == true)
    }

    @Test func cargoDefaultRunMustBeDeclaredByThePackageTable() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try write(
            "Cargo.toml",
            """
            [package]
            name = "lib"

            [package.metadata.alas]
            default-run = "one"
            """,
            in: root
        )
        try FileManager.default.createDirectory(at: root.appendingPathComponent("src/bin"), withIntermediateDirectories: true)
        try touch("src/bin/one.rs", "src/bin/two.rs", in: root)

        #expect(detect(root)[.cargo]?.hasRunnableTarget == false)
    }

    @Test func cargoDoesNotDoubleCountAnExplicitRootMainBinary() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try write(
            "Cargo.toml",
            "[package]\nname = \"tool\"\n\n[[bin]]\nname = \"tool\"\npath = \"src/main.rs\"\n",
            in: root
        )
        try FileManager.default.createDirectory(at: root.appendingPathComponent("src"), withIntermediateDirectories: true)
        try touch("src/main.rs", in: root)

        #expect(detect(root)[.cargo]?.hasRunnableTarget == true)
    }

    @Test func cargoCountsDirectoryFormBinTargets() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try write("Cargo.toml", "[package]\nname = \"tool\"\n", in: root)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("src"), withIntermediateDirectories: true)
        try touch("src/main.rs", in: root)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("src/bin/helper"), withIntermediateDirectories: true)
        try touch("src/bin/helper/main.rs", in: root)

        #expect(detect(root)[.cargo]?.hasRunnableTarget == false)

        try write("Cargo.toml", "[package]\nname = \"tool\"\ndefault-run = \"tool\"\n", in: root)
        #expect(detect(root)[.cargo]?.hasRunnableTarget == true)
    }

    @Test func cargoHonorsDisabledAutomaticBinaryTargets() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try write("Cargo.toml", "[package]\nname = \"tool\"\nautobins = false\n", in: root)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("src"), withIntermediateDirectories: true)
        try touch("src/main.rs", in: root)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("src/bin/helper"), withIntermediateDirectories: true)
        try touch("src/bin/helper/main.rs", in: root)

        #expect(detect(root)[.cargo]?.hasRunnableTarget == false)

        try write("Cargo.toml", "[package]\nname = \"tool\"\nautobins = false\n\n[[bin]]\nname = \"tool\"\npath = \"src/main.rs\"\n", in: root)
        #expect(detect(root)[.cargo]?.hasRunnableTarget == true)
    }

    @Test func cargoLeavesFeatureGatedBinariesUnchecked() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try write(
            "Cargo.toml",
            """
            [package]
            name = "tool"

            [[bin]]
            name = "tool"
            path = "src/main.rs"
            required-features = ["cli"]
            """,
            in: root
        )
        try FileManager.default.createDirectory(at: root.appendingPathComponent("src"), withIntermediateDirectories: true)
        try touch("src/main.rs", in: root)

        #expect(detect(root)[.cargo]?.hasRunnableTarget == false)
    }

    @Test func cargoDefaultRunMustNotSelectFeatureGatedBinary() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try write(
            "Cargo.toml",
            """
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
            """,
            in: root
        )
        try FileManager.default.createDirectory(at: root.appendingPathComponent("src/bin"), withIntermediateDirectories: true)
        try touch("src/bin/gated.rs", "src/bin/plain.rs", in: root)

        #expect(detect(root)[.cargo]?.hasRunnableTarget == false)
    }

    @Test func cargoAllowsRequiredFeaturesEnabledByDefault() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try write(
            "Cargo.toml",
            """
            [package]
            name = "tool"

            [features]
            default = ["cli"]
            cli = []

            [[bin]]
            name = "tool"
            path = "src/main.rs"
            required-features = ["cli"]
            """,
            in: root
        )
        try FileManager.default.createDirectory(at: root.appendingPathComponent("src"), withIntermediateDirectories: true)
        try touch("src/main.rs", in: root)

        #expect(detect(root)[.cargo]?.hasRunnableTarget == true)
    }

    @Test func cargoDoesNotTreatDefaultOptionalDependenciesAsPackageFeatures() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try write(
            "Cargo.toml",
            """
            [package]
            name = "tool"

            [features]
            default = ["dep:cli"]
            cli = []

            [[bin]]
            name = "tool"
            path = "src/main.rs"
            required-features = ["cli"]
            """,
            in: root
        )
        try FileManager.default.createDirectory(at: root.appendingPathComponent("src"), withIntermediateDirectories: true)
        try touch("src/main.rs", in: root)

        #expect(detect(root)[.cargo]?.hasRunnableTarget == false)
    }

    @Test func cargoParsesSingleQuotedRequiredFeatures() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try write(
            "Cargo.toml",
            """
            [package]
            name = "tool"

            [[bin]]
            name = "tool"
            path = "src/main.rs"
            required-features = ['cli']
            """,
            in: root
        )
        try FileManager.default.createDirectory(at: root.appendingPathComponent("src"), withIntermediateDirectories: true)
        try touch("src/main.rs", in: root)

        #expect(detect(root)[.cargo]?.hasRunnableTarget == false)
    }

    @Test func cargoParsesSingleQuotedBinNamesBeforeCheckingFeatures() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try write(
            "Cargo.toml",
            """
            [package]
            name = "tool"

            [[bin]]
            name = 'tool'
            path = "src/main.rs"
            required-features = ['cli']
            """,
            in: root
        )
        try FileManager.default.createDirectory(at: root.appendingPathComponent("src"), withIntermediateDirectories: true)
        try touch("src/main.rs", in: root)

        #expect(detect(root)[.cargo]?.hasRunnableTarget == false)
    }

    @Test func cargoIgnoresBinTablesInsideMultilineStrings() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try write(
            "Cargo.toml",
            """
            [package]
            name = "library"

            [package.metadata.docs]
            example = '''
            [[bin]]
            name = "fake"
            '''
            """,
            in: root
        )

        #expect(detect(root)[.cargo]?.hasRunnableTarget == false)
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

    @Test func plainMakefileDetectsMake() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try touch("GNUmakefile", in: root)
        #expect(detect(root)[.make]?.hasMakeTestTarget == false)
        #expect(detect(root)[.make]?.hasMakeCleanTarget == false)
    }

    @Test func makefileReadsItsDeclaredTargets() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try write("Makefile", "all:\n\techo build\n\ntest: all\n\techo test\n", in: root)
        #expect(detect(root)[.make]?.hasMakeTestTarget == true)
        #expect(detect(root)[.make]?.hasMakeCleanTarget == false)

        try write("Makefile", "CFLAGS := -O2\n\nclean:\n\trm -rf build\n", in: root)
        #expect(detect(root)[.make]?.hasMakeTestTarget == false)
        #expect(detect(root)[.make]?.hasMakeCleanTarget == true)

        try write("Makefile", "all test clean:\n\techo combined\n", in: root)
        #expect(detect(root)[.make]?.hasMakeTestTarget == true)
        #expect(detect(root)[.make]?.hasMakeCleanTarget == true)
    }

    /// A column-zero comment like "# test: disabled" must not read as a
    /// rule for "test" just because it splits into that token before a colon.
    @Test func makefileIgnoresCommentLines() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try write("Makefile", "# test: disabled\n\nall:\n\techo build\n", in: root)
        #expect(detect(root)[.make]?.hasMakeTestTarget == false)

        try write("Makefile", "test: build ## runs the test suite\n\techo test\n", in: root)
        #expect(detect(root)[.make]?.hasMakeTestTarget == true)
    }

    @Test func swiftPackageDetectsManifest() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try write("Package.swift", "let package = Package(name: \"Lib\", targets: [.target(name: \"Lib\")])", in: root)
        #expect(detect(root)[.swiftPackage]?.hasRunnableTarget == false)

        try write(
            "Package.swift",
            "let package = Package(name: \"Tool\", targets: [.executableTarget(name: \"Tool\")])",
            in: root
        )
        #expect(detect(root)[.swiftPackage]?.hasRunnableTarget == true)
    }

    /// `swift run` with no argument only resolves when there's exactly one
    /// executable to pick; with two, it exits requiring a name.
    @Test func swiftPackageLeavesMultipleExecutablesUnchecked() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try write(
            "Package.swift",
            "let package = Package(targets: [.executableTarget(name: \"A\"), .executableTarget(name: \"B\")])",
            in: root
        )
        #expect(detect(root)[.swiftPackage]?.hasRunnableTarget == false)
    }

    /// A commented-out `.executableTarget` is Swift source, not a real
    /// target — Package.swift's `//` comments apply the same as anywhere
    /// else.
    @Test func swiftPackageIgnoresACommentedOutExecutableTarget() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try write(
            "Package.swift",
            "let package = Package(targets: [\n  .target(name: \"Lib\"),\n  // .executableTarget(name: \"Removed\"),\n])",
            in: root
        )
        #expect(detect(root)[.swiftPackage]?.hasRunnableTarget == false)
    }

    @Test func swiftPackageIgnoresExecutableTargetsInInactiveOSBranches() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try write(
            "Package.swift",
            """
            let package = Package(targets: [
            #if os(Linux)
                .executableTarget(name: "LinuxTool"),
            #endif
                .target(name: "Lib"),
            ])
            """,
            in: root
        )

        #expect(detect(root)[.swiftPackage]?.hasRunnableTarget == false)
    }

    @Test func swiftPackageIgnoresExecutableTargetsInInactiveCompoundOSBranches() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try write(
            "Package.swift",
            """
            let package = Package(targets: [
            #if os(Linux) && swift(>=5.9)
                .executableTarget(name: "LinuxTool"),
            #endif
                .target(name: "Lib"),
            ])
            """,
            in: root
        )

        #expect(detect(root)[.swiftPackage]?.hasRunnableTarget == false)
    }

    @Test func swiftPackageIgnoresExecutableTargetsInParenthesizedInactiveOSBranches() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try write(
            "Package.swift",
            """
            let package = Package(targets: [
            #if (os(Linux))
                .executableTarget(name: "LinuxTool"),
            #endif
                .target(name: "Lib"),
            ])
            """,
            in: root
        )

        #expect(detect(root)[.swiftPackage]?.hasRunnableTarget == false)
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

    @Test func swiftPackageIgnoresExecutableTargetsInFalseBranches() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try write(
            "Package.swift",
            """
            let package = Package(targets: [
            #if false
                .executableTarget(name: "NeverTool"),
            #else
                .target(name: "Lib"),
            #endif
            ])
            """,
            in: root
        )

        #expect(detect(root)[.swiftPackage]?.hasRunnableTarget == false)
    }

    @Test func swiftPackageRecognizesCompactConditionalDirectives() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try write(
            "Package.swift",
            """
            #if(os(macOS))
            let package = Package(targets: [
                .target(name: "Lib"),
            ])
            #else
            let package = Package(targets: [
                .executableTarget(name: "OtherTool"),
            ])
            #endif
            """,
            in: root
        )

        #expect(detect(root)[.swiftPackage]?.hasRunnableTarget == false)
    }

    @Test func swiftPackageLeavesRunUncheckedForUnresolvedConditions() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try write(
            "Package.swift",
            """
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
            """,
            in: root
        )

        #expect(detect(root)[.swiftPackage]?.hasRunnableTarget == false)
    }

    @Test func swiftPackageLeavesRunUncheckedForUnavailableImports() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try write(
            "Package.swift",
            """
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
            """,
            in: root
        )

        #expect(detect(root)[.swiftPackage]?.hasRunnableTarget == false)
    }

    @Test func swiftPackageUsesManifestToolsVersionForSwiftConditions() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try write(
            "Package.swift",
            """
            // swift-tools-version: 6.0
            import PackageDescription
            #if swift(<6.0)
            let targets: [Target] = [.executableTarget(name: "Tool")]
            #else
            let targets: [Target] = [.target(name: "Lib")]
            #endif
            let package = Package(name: "Lib", targets: targets)
            """,
            in: root
        )

        #expect(detect(root)[.swiftPackage]?.hasRunnableTarget == false)
    }

    @Test func swiftPackageLeavesRunUncheckedForUnknownConditions() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try write(
            "Package.swift",
            """
            import PackageDescription
            #if DEBUG
            let targets: [Target] = [.executableTarget(name: "Tool")]
            #else
            let targets: [Target] = [.target(name: "Lib")]
            #endif
            let package = Package(name: "Lib", targets: targets)
            """,
            in: root
        )

        #expect(detect(root)[.swiftPackage]?.hasRunnableTarget == false)
    }

    @Test func swiftPackageIgnoresExecutableTargetsInsideStringLiterals() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try write(
            "Package.swift",
            #"""
            let docs = """
            .executableTarget(name: "Fake")
            """
            let package = Package(targets: [
                .target(name: "Lib"),
            ])
            """#,
            in: root
        )

        #expect(detect(root)[.swiftPackage]?.hasRunnableTarget == false)
    }

    @Test func swiftPackageRecognizesTheOlderExecutableProductForm() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try write(
            "Package.swift",
            "products: [.executable(name: \"Tool\", targets: [\"Tool\"])], targets: [.target(name: \"Tool\", type: .executable)]",
            in: root
        )
        #expect(detect(root)[.swiftPackage]?.hasRunnableTarget == true)
    }

    @Test func swiftPackageRecognizesAnExecutableProductWithARegularTarget() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try write(
            "Package.swift",
            "products: [.executable(name: \"Tool\", targets: [\"Tool\"])], targets: [.target(name: \"Tool\")]",
            in: root
        )

        #expect(detect(root)[.swiftPackage]?.hasRunnableTarget == true)
    }

    @Test func swiftPackageLeavesMixedExecutableDeclarationsUnchecked() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try write("Package.swift", "products: [.executable(name: \"Tool\", targets: [\"Tool\"])], targets: [.executableTarget(name: \"Other\")]", in: root)
        #expect(detect(root)[.swiftPackage]?.hasRunnableTarget == false)
    }

    @Test func swiftPackageDeduplicatesExecutableProductsFromTheirTargets() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try write(
            "Package.swift",
            "products: [.executable(name: \"app\", targets: [\"App\"])], targets: [.executableTarget(name: \"App\")]",
            in: root
        )
        #expect(detect(root)[.swiftPackage]?.hasRunnableTarget == true)
    }

    @Test func xcodePrefersWorkspaceOverProject() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root.appendingPathComponent("App.xcodeproj"), withIntermediateDirectories: true)
        #expect(detect(root)[.xcode]?.xcodeContainer == "App.xcodeproj")

        try FileManager.default.createDirectory(at: root.appendingPathComponent("App.xcworkspace"), withIntermediateDirectories: true)
        #expect(detect(root)[.xcode]?.xcodeContainer == "App.xcworkspace")
    }

    @Test func goDetectsModule() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try touch("go.mod", in: root)
        #expect(detect(root)[.go]?.goRunTarget == nil)
    }

    @Test func goPrefersARootMainPackage() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try touch("go.mod", in: root)
        try write("lib.go", "package mylib\n\nfunc DoThing() {}\n", in: root)
        #expect(detect(root)[.go]?.goRunTarget == nil)

        try write("main.go", "package main\n\nfunc main() {}\n", in: root)
        #expect(detect(root)[.go]?.goRunTarget == ".")
    }

    @Test func goIgnoresMainFilesExcludedFromTheCurrentHost() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try touch("go.mod", in: root)
        try write("main_linux.go", "package main\n\nfunc main() {}\n", in: root)
        #expect(detect(root)[.go]?.goRunTarget == nil)

        try write("main.go", "//go:build linux\n\npackage main\n\nfunc main() {}\n", in: root)
        #expect(detect(root)[.go]?.goRunTarget == nil)

        try write("main.go", "// +build linux\n\npackage main\n\nfunc main() {}\n", in: root)
        #expect(detect(root)[.go]?.goRunTarget == nil)
    }

    @Test func goOnlyUsesTrailingFilenameBuildConstraints() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try touch("go.mod", in: root)
        try write("main_linux_helper.go", "package main\n\nfunc main() {}\n", in: root)

        #expect(detect(root)[.go]?.goRunTarget == ".")
    }

    @Test func goReadsTheActualPackageClause() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try touch("go.mod", in: root)
        try write(
            "main.go",
            """
            /*
            package main
            */
            package library

            const text = `
            package main
            `
            """,
            in: root
        )

        #expect(detect(root)[.go]?.goRunTarget == nil)
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

    @Test func goUsesSatisfiedReleaseBuildTags() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try touch("go.mod", in: root)
        try write("main.go", "//go:build !go1.20\n\npackage main\n\nfunc main() {}\n", in: root)

        #expect(detect(root)[.go]?.goRunTarget == nil)
    }

    @Test func goDoesNotAssumeNewestReleaseBuildTagsAreEnabled() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try touch("go.mod", in: root)
        try write("main.go", "//go:build go1.999\n\npackage main\n\nfunc main() {}\n", in: root)

        #expect(detect(root)[.go]?.goRunTarget == nil)
    }

    @Test func goDerivesNewestReleaseTagsFromTheInstalledToolchain() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try touch("go.mod", in: root)
        try write("main.go", "//go:build !go1.25\n\npackage main\n\nfunc main() {}\n", in: root)

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
            goToolchainMinorVersion: { resolvedRoot in
                resolvedRoots.append(resolvedRoot)
                return resolvedRoot == root ? 26 : 1
            }
        ).map { ($0.stack, $0.context) })

        #expect(resolvedRoots == [root])
        #expect(stacks[.go]?.goRunTarget == ".")
    }

    @Test func goTreatsTheStandardCompilerTagAsEnabled() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try touch("go.mod", in: root)
        try write("main.go", "//go:build !gc\n\npackage main\n\nfunc main() {}\n", in: root)

        #expect(detect(root)[.go]?.goRunTarget == nil)
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

    @Test func goRequiresAMainFunctionBeforePreselectingRun() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try touch("go.mod", in: root)
        try write("main.go", "package main\n\nfunc helper() {}\n", in: root)
        #expect(detect(root)[.go]?.goRunTarget == nil)

        try write("main.go", "package main\n\nfunc main() {}\n", in: root)
        #expect(detect(root)[.go]?.goRunTarget == ".")
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
        try FileManager.default.createDirectory(at: root.appendingPathComponent("spec"), withIntermediateDirectories: true)
        let stacks = detect(root)
        #expect(stacks[.ruby] == nil)
        #expect(stacks[.rails]?.hasSpecDirectory == true)
        #expect(stacks[.rails]?.hasRubocopConfig == true)
    }

    @Test func rubyRecordsDeclaredRakeTestTask() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try write("Gemfile", "source \"https://rubygems.org\"\ngem \"rake\"\n", in: root)
        #expect(detect(root)[.ruby]?.hasRakeTestTask == false)

        try write("Rakefile", "# task :test\n", in: root)
        #expect(detect(root)[.ruby]?.hasRakeTestTask == false)

        try write("Rakefile", "namespace :foo do\n  task :test\nend\n", in: root)
        #expect(detect(root)[.ruby]?.hasRakeTestTask == false)

        try write("Rakefile", "namespace :foo do\n  if true\n  end\n  task :test\nend\n", in: root)
        #expect(detect(root)[.ruby]?.hasRakeTestTask == false)

        try write("Rakefile", "namespace(:foo) {\n  task :test\n}\n", in: root)
        #expect(detect(root)[.ruby]?.hasRakeTestTask == false)

        try write("Rakefile", "docs = <<~TEXT\n  task :test\nTEXT\n", in: root)
        #expect(detect(root)[.ruby]?.hasRakeTestTask == false)

        try write("Rakefile", "task :test do\n  ruby \"test/all_test.rb\"\nend\n", in: root)
        #expect(detect(root)[.ruby]?.hasRakeTestTask == true)

        try write("Rakefile", "task test: :prepare do\n  ruby \"test/all_test.rb\"\nend\n", in: root)
        #expect(detect(root)[.ruby]?.hasRakeTestTask == true)
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

    /// A runtime-only library that never mentions pytest or ruff most likely
    /// doesn't have either installed; confirming pytest/ruff use requires
    /// finding a real mention in pyproject.toml.
    @Test func pythonOnlyChecksToolsPyprojectActuallyMentions() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try write("pyproject.toml", "[project]\nname = \"lib\"\ndependencies = []\n", in: root)
        #expect(detect(root)[.python]?.hasPytest == false)
        #expect(detect(root)[.python]?.hasRuff == false)

        try write(
            "pyproject.toml",
            "[project]\nname = \"lib\"\ndependencies = [\"pytest\", \"ruff\"]\n",
            in: root
        )
        #expect(detect(root)[.python]?.hasPytest == true)
        #expect(detect(root)[.python]?.hasRuff == true)
    }

    @Test func pythonBareRunnerIgnoresDependencyGroupsForToolAvailability() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try write(
            "pyproject.toml",
            """
            [project]
            name = "lib"
            dependencies = []

            [dependency-groups]
            dev = ["pytest", "ruff"]
            """,
            in: root
        )

        #expect(detect(root)[.python]?.hasPytest == false)
        #expect(detect(root)[.python]?.hasRuff == false)
    }

    @Test func pythonBareRunnerIgnoresOptionalExtrasForToolAvailability() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try write(
            "pyproject.toml",
            """
            [project]
            name = "lib"
            dependencies = []

            [project.optional-dependencies]
            dev = ["pytest", "ruff"]
            """,
            in: root
        )

        #expect(detect(root)[.python]?.hasPytest == false)
        #expect(detect(root)[.python]?.hasRuff == false)
    }

    @Test func pythonUVRunnerIgnoresOptionalExtrasForToolAvailability() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try touch("uv.lock", in: root)
        try write(
            "pyproject.toml",
            """
            [project]
            name = "lib"
            dependencies = []

            [project.optional-dependencies]
            dev = ["pytest", "ruff"]
            """,
            in: root
        )

        #expect(detect(root)[.python]?.hasPytest == false)
        #expect(detect(root)[.python]?.hasRuff == false)
    }

    @Test func pythonIgnoresBuildSystemRequirementsForToolAvailability() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try write(
            "pyproject.toml",
            """
            [project]
            name = "lib"
            dependencies = []

            [build-system]
            requires = ["setuptools", "pytest", "ruff"]
            build-backend = "setuptools.build_meta"
            """,
            in: root
        )

        #expect(detect(root)[.python]?.hasPytest == false)
        #expect(detect(root)[.python]?.hasRuff == false)
    }

    @Test func pythonReadsPoetryDependencyTables() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try touch("poetry.lock", in: root)
        try write(
            "pyproject.toml",
            """
            [tool.poetry]
            name = "lib"

            [tool.poetry.group.test.dependencies]
            pytest = "^8"

            [tool.poetry.dev-dependencies]
            ruff = "^0.8"
            """,
            in: root
        )

        #expect(detect(root)[.python]?.hasPytest == true)
        #expect(detect(root)[.python]?.hasRuff == true)
    }

    @Test func pythonIgnoresUnrelatedProjectArraysWhenDetectingTools() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try write(
            "pyproject.toml",
            """
            [project]
            name = "lib"
            dependencies = []
            keywords = ["pytest", "ruff"]
            """,
            in: root
        )

        #expect(detect(root)[.python]?.hasPytest == false)
        #expect(detect(root)[.python]?.hasRuff == false)
    }

    @Test func pythonIgnoresCommentedOutToolMentions() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try write(
            "pyproject.toml",
            """
            [project]
            name = "lib"
            dependencies = []
            # pytest = "^8"
            # ruff was removed from this project
            """,
            in: root
        )
        #expect(detect(root)[.python]?.hasPytest == false)
        #expect(detect(root)[.python]?.hasRuff == false)
    }

    @Test func pythonIgnoresToolMentionsInUnrelatedMetadata() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try write(
            "pyproject.toml",
            """
            [project]
            name = "lib"
            description = "Works without pytest or ruff"
            dependencies = []
            """,
            in: root
        )

        #expect(detect(root)[.python]?.hasPytest == false)
        #expect(detect(root)[.python]?.hasRuff == false)
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

        try write("composer.json", #"{"scripts":{"test":"vendor/bin/phpunit"}}"#, in: root)
        #expect(detect(root)[.php]?.hasPHPUnit == true)
    }

    @Test func dotnetDetectsSolutionOrProjectFiles() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try touch("App.csproj", in: root)
        #expect(detect(root)[.dotnet] != nil)
    }

    @Test func dotnetFindsAnExecutableProjectAtTheRoot() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try write("App.csproj", "<Project><PropertyGroup><OutputType>Exe</OutputType></PropertyGroup></Project>", in: root)
        #expect(detect(root)[.dotnet]?.dotnetRunProject == "App.csproj")
    }

    @Test func dotnetRecognizesWebSDKProjectsAsExecutable() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try write("App.csproj", #"<Project Sdk="Microsoft.NET.Sdk.Web"></Project>"#, in: root)

        #expect(detect(root)[.dotnet]?.dotnetRunProject == "App.csproj")
    }

    /// A root .sln with no runnable project at the worktree root: only a
    /// project under a subdirectory whose OutputType is actually executable
    /// counts, not a library alongside it.
    /// Detection reads the solution's own project references rather than
    /// walking the worktree, so an unreferenced project on disk doesn't
    /// count and a large monorepo isn't scanned end to end.
    @Test func dotnetFindsAnExecutableProjectUnderTheSolutionLayout() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("src/App.Lib"), withIntermediateDirectories: true
        )
        try write(
            "src/App.Lib/App.Lib.csproj",
            "<Project><PropertyGroup><OutputType>Library</OutputType></PropertyGroup></Project>",
            in: root
        )
        try write(
            "App.sln",
            """
            Microsoft Visual Studio Solution File, Format Version 12.00
            Project("{FAE04EC0-301F-11D3-BF4B-00C04F79EFBC}") = "App.Lib", "src\\App.Lib\\App.Lib.csproj", "{11111111-1111-1111-1111-111111111111}"
            EndProject
            """,
            in: root
        )
        #expect(detect(root)[.dotnet]?.dotnetRunProject == nil)

        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("src/App.Cli"), withIntermediateDirectories: true
        )
        try write(
            "src/App.Cli/App.Cli.csproj",
            "<Project><PropertyGroup><OutputType>Exe</OutputType></PropertyGroup></Project>",
            in: root
        )
        try write(
            "App.sln",
            """
            Microsoft Visual Studio Solution File, Format Version 12.00
            Project("{FAE04EC0-301F-11D3-BF4B-00C04F79EFBC}") = "App.Lib", "src\\App.Lib\\App.Lib.csproj", "{11111111-1111-1111-1111-111111111111}"
            EndProject
            Project("{FAE04EC0-301F-11D3-BF4B-00C04F79EFBC}") = "App.Cli", "src\\App.Cli\\App.Cli.csproj", "{22222222-2222-2222-2222-222222222222}"
            EndProject
            """,
            in: root
        )
        #expect(detect(root)[.dotnet]?.dotnetRunProject == "src/App.Cli/App.Cli.csproj")

        // A project that exists on disk but isn't referenced by the
        // solution must not be discovered by scanning the tree for it.
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("unreferenced"), withIntermediateDirectories: true
        )
        try write(
            "unreferenced/Stray.csproj",
            "<Project><PropertyGroup><OutputType>Exe</OutputType></PropertyGroup></Project>",
            in: root
        )
        #expect(detect(root)[.dotnet]?.dotnetRunProject == "src/App.Cli/App.Cli.csproj")
    }

    @Test func dotnetLeavesMultipleExecutableProjectsUnchecked() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try write("One.csproj", "<OutputType>Exe</OutputType>", in: root)
        try write("Two.csproj", "<OutputType>WinExe</OutputType>", in: root)
        #expect(detect(root)[.dotnet]?.dotnetRunProject == nil)
    }

    @Test func dotnetAggregatesExecutableProjectsFromAllRootSolutions() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("src/One"), withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("src/Two"), withIntermediateDirectories: true
        )
        try write("src/One/One.csproj", "<OutputType>Exe</OutputType>", in: root)
        try write("src/Two/Two.csproj", "<OutputType>Exe</OutputType>", in: root)
        try write(
            "One.sln",
            """
            Microsoft Visual Studio Solution File, Format Version 12.00
            Project("{FAE04EC0-301F-11D3-BF4B-00C04F79EFBC}") = "One", "src\\One\\One.csproj", "{11111111-1111-1111-1111-111111111111}"
            EndProject
            """,
            in: root
        )
        try write(
            "Two.sln",
            """
            Microsoft Visual Studio Solution File, Format Version 12.00
            Project("{FAE04EC0-301F-11D3-BF4B-00C04F79EFBC}") = "Two", "src\\Two\\Two.csproj", "{22222222-2222-2222-2222-222222222222}"
            EndProject
            """,
            in: root
        )

        #expect(detect(root)[.dotnet]?.dotnetRunProject == nil)
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

    @Test func flutterReadsPubspecForTheSDK() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try write("pubspec.yaml", "name: app\ndependencies:\n  flutter:\n    sdk: flutter\n", in: root)
        #expect(detect(root)[.flutter]?.usesFlutter == true)
        try write("pubspec.yaml", "name: tool\ndependencies:\n  args: ^2.0.0\n", in: root)
        #expect(detect(root)[.flutter]?.usesFlutter == false)
    }

    /// A word-mention of Flutter — in a description, or a `flutter_lints`
    /// dev dependency — is not the same as depending on the Flutter SDK.
    @Test func flutterDoesNotFireOnAWordMentionOrLintsPackage() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try write(
            "pubspec.yaml",
            "name: tool\ndescription: A CLI used by Flutter clients.\ndependencies:\n  args: ^2.0.0\ndev_dependencies:\n  flutter_lints: ^3.0.0\n",
            in: root
        )
        #expect(detect(root)[.flutter]?.usesFlutter == false)
    }

    @Test func flutterRecognizesFlowStyleAndACommentBetweenFlutterAndSDK() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try write("pubspec.yaml", "name: app\ndependencies:\n  flutter: { sdk: flutter }\n", in: root)
        #expect(detect(root)[.flutter]?.usesFlutter == true)

        try write(
            "pubspec.yaml",
            "name: app\ndependencies:\n  flutter:\n    # pinned to the stable channel\n    sdk: flutter\n",
            in: root
        )
        #expect(detect(root)[.flutter]?.usesFlutter == true)
    }

    @Test func flutterAcceptsQuotedSDKScalars() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try write("pubspec.yaml", "name: app\ndependencies:\n  flutter:\n    sdk: \"flutter\"\n", in: root)
        #expect(detect(root)[.flutter]?.usesFlutter == true)

        try write("pubspec.yaml", "name: app\ndependencies:\n  flutter: { sdk: 'flutter' }\n", in: root)
        #expect(detect(root)[.flutter]?.usesFlutter == true)
    }

    /// A fully inline dependencies block: "flutter" is never a line's own
    /// key because the whole map lives on one line.
    @Test func flutterRecognizesAFullyInlineDependenciesBlock() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try write("pubspec.yaml", "name: app\ndependencies: { flutter: { sdk: flutter } }\n", in: root)
        #expect(detect(root)[.flutter]?.usesFlutter == true)
    }

    @Test func flutterRecognizesMultilineFlowDependenciesBlock() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try write(
            "pubspec.yaml",
            """
            name: app
            dependencies: {
              flutter: { sdk: flutter }
            }
            """,
            in: root
        )
        #expect(detect(root)[.flutter]?.usesFlutter == true)
    }

    /// The inline-flow fallback must not fire on a mention left inside a
    /// comment for a Dart-only package.
    @Test func flutterInlineFallbackIgnoresComments() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try write(
            "pubspec.yaml",
            "name: tool\n# flutter: { sdk: flutter }\ndependencies:\n  args: ^2.0.0\n",
            in: root
        )
        #expect(detect(root)[.flutter]?.usesFlutter == false)
    }

    @Test func flutterInlineFallbackIsLimitedToDependencies() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try write(
            "pubspec.yaml",
            "name: tool\ndescription: \"flutter: { sdk: flutter }\"\ndependencies:\n  args: ^2.0.0\n",
            in: root
        )
        #expect(detect(root)[.flutter]?.usesFlutter == false)
    }

    @Test func elixirReadsMixForPhoenix() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try write("mix.exs", "defp deps do\n  [{:phoenix, \"~> 1.7\"}]\nend\n", in: root)
        #expect(detect(root)[.elixir]?.usesPhoenix == true)
        try write("mix.exs", "defp deps do\n  []\nend\n", in: root)
        #expect(detect(root)[.elixir]?.usesPhoenix == false)
    }

    @Test func elixirIgnoresACommentedOutPhoenixDependency() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try write("mix.exs", "defp deps do\n  [\n    # {:phoenix, \"~> 1.7\"}\n  ]\nend\n", in: root)
        #expect(detect(root)[.elixir]?.usesPhoenix == false)
    }

    /// A word mention inside a string literal — a package description, say —
    /// is not a dependency declaration.
    @Test func elixirIgnoresAPhoenixMentionInsideAStringLiteral() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try write(
            "mix.exs",
            "def project do\n  [description: \"Utilities for :phoenix integrations\"]\nend\ndefp deps do\n  []\nend\n",
            in: root
        )
        #expect(detect(root)[.elixir]?.usesPhoenix == false)
    }

    @Test func elixirIgnoresAPhoenixTupleInsideAStringLiteral() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try write(
            "mix.exs",
            #"""
            def project do
              [description: ~s/Example tuple {:phoenix, "~> 1.7"}/]
            end
            defp deps do
              []
            end
            """#,
            in: root
        )
        #expect(detect(root)[.elixir]?.usesPhoenix == false)
    }

    /// `:phoenix_pubsub` and `:phoenix_live_view` share a prefix with
    /// `:phoenix` but are not the Phoenix web framework itself.
    @Test func elixirDoesNotTreatPhoenixPrefixedPackagesAsPhoenix() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try write(
            "mix.exs",
            "defp deps do\n  [{:phoenix_pubsub, \"~> 2.1\"}, {:phoenix_live_view, \"~> 0.20\"}]\nend\n",
            in: root
        )
        #expect(detect(root)[.elixir]?.usesPhoenix == false)
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

    @Test func zigRecordsDeclaredBuildSteps() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try write(
            "build.zig",
            """
            pub fn build(b: *std.Build) void {
                _ = b.step("test", "Run unit tests");
                _ = b.step("run", "Run the app");
            }
            """,
            in: root
        )

        #expect(detect(root)[.zig]?.zigBuildSteps == ["test", "run"])
    }

    @Test func zigIgnoresCommentedOutBuildSteps() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try write(
            "build.zig",
            """
            pub fn build(b: *std.Build) void {
                // _ = b.step("test", "Run unit tests");
                _ = b.step("run", "Run the app");
            }
            """,
            in: root
        )

        #expect(detect(root)[.zig]?.zigBuildSteps == ["run"])
    }

    @Test func zigIgnoresBuildStepsInsideStrings() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try write(
            "build.zig",
            """
            pub fn build(b: *std.Build) void {
                const help = ".step(\\"test\\", \\"example\\")";
                _ = b.step("run", "Run the app");
            }
            """,
            in: root
        )

        #expect(detect(root)[.zig]?.zigBuildSteps == ["run"])
    }

    @Test func zigIgnoresBuildStepsInsideMultilineStrings() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try write(
            "build.zig",
            """
            pub fn build(b: *std.Build) void {
                const help =
                    \\\\.step("test", "example")
                ;
                _ = b.step("run", "Run the app");
            }
            """,
            in: root
        )

        #expect(detect(root)[.zig]?.zigBuildSteps == ["run"])
    }

    @Test func denoReadsDeclaredTaskNames() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try write("deno.json", #"{"tasks":{"dev":"deno run --watch main.ts"}}"#, in: root)
        #expect(detect(root)[.deno]?.denoTasks == ["dev"])

        try write("deno.json", #"{"tasks":{"build":"deno compile main.ts"}}"#, in: root)
        #expect(detect(root)[.deno]?.denoTasks == ["build"])
    }

    @Test func denoParsesJSONCCommentsAndTrailingCommas() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try write(
            "deno.jsonc",
            """
            // project config
            {
              "tasks": {
                "dev": "deno run --watch main.ts", // dev server
              },
            }
            """,
            in: root
        )
        #expect(detect(root)[.deno]?.denoTasks == ["dev"])
    }

    @Test func denoWithGenuinelyMalformedConfigLeavesTasksUnknown() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try write("deno.jsonc", "{ this is not json at all", in: root)
        #expect(detect(root)[.deno]?.denoTasks == nil)
    }
}
