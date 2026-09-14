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
        #expect(detect(root)[.cargo] != nil)
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
        #expect(detect(root)[.make] != nil)
    }

    @Test func swiftPackageDetectsManifest() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try touch("Package.swift", in: root)
        #expect(detect(root)[.swiftPackage] != nil)
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
        #expect(detect(root)[.go] != nil)
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

    @Test func laravelHidesPlainComposer() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try touch("composer.json", in: root)
        #expect(detect(root)[.php] != nil)
        try touch("artisan", in: root)
        #expect(detect(root)[.php] == nil)
        #expect(detect(root)[.laravel] != nil)
    }

    @Test func dotnetDetectsSolutionOrProjectFiles() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try touch("App.csproj", in: root)
        #expect(detect(root)[.dotnet] != nil)
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
}
