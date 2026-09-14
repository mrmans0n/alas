import Foundation
import Testing
@testable import Alas

struct RunScriptStackCatalogTests {
    private func actions(_ stack: RunScriptStack, _ context: RunScriptStackContext = .init()) -> [String: RunScriptStackAction] {
        Dictionary(uniqueKeysWithValues: RunScriptStackCatalog.actions(for: stack, context: context).map { ($0.id, $0) })
    }

    @Test(arguments: RunScriptStack.allCases)
    func everyStackOffersDistinctRunnableActions(stack: RunScriptStack) throws {
        let actions = RunScriptStackCatalog.actions(for: stack)
        #expect(!actions.isEmpty)
        #expect(Set(actions.map(\.id)).count == actions.count)
        #expect(Set(actions.map(\.displayName)).count == actions.count)
        if stack != .gradle {
            #expect(actions.contains { $0.isCheckedByDefault })
        }
        for action in actions {
            #expect(!action.body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            let contents = RunScriptTemplate.contents(
                name: action.displayName, onExit: action.onExit, body: action.body, endpoint: action.endpoint
            )
            let meta = RunScriptMetadata.parse(fileName: RunScriptTemplate.fileName(for: action.displayName), contents: contents)
            #expect(meta.displayName == action.displayName)
            #expect(meta.onExit == action.onExit)
            #expect(meta.cwd == nil)
            if let endpoint = action.endpoint {
                #expect(meta.endpoint?.absoluteString == endpoint)
                #expect(action.onExit == .keep, "\(stack) \(action.id) serves an endpoint but closes its pane")
            } else {
                #expect(meta.endpoint == nil, "\(stack) \(action.id) must not declare an endpoint by accident")
            }
            #expect(contents.contains("set -euo pipefail\n"))
            let syntaxOK = try zshSyntaxIsValid(contents)
            #expect(syntaxOK, "\(stack) \(action.id) failed zsh -n")
        }
    }

    @Test func gradlePrefersWrapper() {
        #expect(actions(.gradle, .init(hasWrapper: true))["build"]?.body == "./gradlew assemble")
        #expect(actions(.gradle)["build"]?.body == "gradle assemble")
        #expect(actions(.gradle)["test"]?.body == "gradle test")
    }

    @Test func gradleTasksAreUncheckedUnlessDeclared() {
        #expect(actions(.gradle)["build"]?.isCheckedByDefault == false)
        #expect(actions(.gradle)["test"]?.isCheckedByDefault == false)
        #expect(actions(.gradle)["check"]?.isCheckedByDefault == false)
        #expect(actions(.gradle)["clean"]?.isCheckedByDefault == false)
        #expect(actions(.gradle, .init(gradleTasks: ["assemble", "test"]))["build"]?.isCheckedByDefault == true)
        #expect(actions(.gradle, .init(gradleTasks: ["assemble", "test"]))["test"]?.isCheckedByDefault == true)
    }

    @Test func mavenPrefersWrapperAndRunsBatchMode() {
        #expect(actions(.maven, .init(hasWrapper: true))["test"]?.body == "./mvnw -B test")
        #expect(actions(.maven)["build"]?.body == "mvn -B -DskipTests package")
    }

    @Test func kotlinToolchainPicksWrapperByWhatIsActuallyInstalled() {
        #expect(actions(.kotlin, .init(kotlinWrapper: .kotlin))["build"]?.body == "./kotlin build")
        #expect(actions(.kotlin, .init(kotlinWrapper: .amper))["build"]?.body == "./amper build")
        #expect(actions(.kotlin)["run"]?.body == "kotlin run")
    }

    @Test func cargoClippyDeniesWarnings() {
        #expect(actions(.cargo)["clippy"]?.body == "cargo clippy --all-targets -- -D warnings")
        #expect(actions(.cargo)["format-check"]?.body == "cargo fmt --all --check")
    }

    @Test func javascriptUsesDetectedPackageManager() {
        #expect(actions(.javascript, .init(packageManager: .pnpm))["build"]?.body == "pnpm run build")
        #expect(actions(.javascript, .init(packageManager: .bun))["test"]?.body == "bun run test")
        #expect(actions(.javascript)["install"]?.body == "npm install")
        #expect(actions(.javascript, .init(packageManager: .yarn))["install"]?.body == "yarn install")
    }

    @Test func javascriptDevHintsAtEndpointWithoutDeclaringOne() {
        let dev = actions(.javascript, .init(packageManager: .pnpm))["dev"]
        #expect(dev?.body.hasSuffix("pnpm run dev") == true)
        #expect(dev?.body.contains("alas-url") == true)
    }

    @Test func javascriptChecksOnlyScriptsThePackageDeclares() {
        let known = actions(.javascript, .init(packageScripts: ["build", "lint"]))
        #expect(known["install"]?.isCheckedByDefault == true)
        #expect(known["build"]?.isCheckedByDefault == true)
        #expect(known["lint"]?.isCheckedByDefault == true)
        #expect(known["test"]?.isCheckedByDefault == false)
        #expect(known["dev"]?.isCheckedByDefault == false)

        let unchecked = actions(.javascript).values.filter { !$0.isCheckedByDefault }
        #expect(unchecked.isEmpty)
    }

    @Test func cmakeConfiguresBuildsAndTestsInBuildDirectory() {
        let cmake = actions(.cmake)
        #expect(cmake["configure"]?.body == "cmake -S . -B build -DCMAKE_BUILD_TYPE=Debug")
        #expect(cmake["build"]?.body == "cmake --build build")
        #expect(cmake["test"]?.body == "ctest --test-dir build --output-on-failure")
    }

    @Test func xcodeUsesDetectedContainerAndScheme() {
        let workspace = actions(.xcode, .init(xcodeContainer: "Alas.xcworkspace"))["build"]?.body ?? ""
        #expect(workspace.contains("-workspace Alas.xcworkspace -scheme Alas"))
        let testAction = actions(.xcode, .init(xcodeContainer: "Alas.xcodeproj"))["test"]
        let project = testAction?.body ?? ""
        #expect(project.contains("-project Alas.xcodeproj -scheme Alas"))
        // No destination is hard-coded on the actual xcodebuild invocation:
        // the container name alone doesn't say whether the scheme even
        // supports macOS. The hint comment is allowed to mention the flag.
        let commandLine = testAction.map(NewRunScriptDialog.commandPreview(for:)) ?? ""
        #expect(!commandLine.contains("-destination"))
        #expect(project.contains("Add -destination if this scheme needs one"))
        let fallback = actions(.xcode)["build"]?.body ?? ""
        #expect(fallback.contains("-project App.xcodeproj -scheme App"))
    }

    @Test func xcodeQuotesAContainerNameWithSpaces() {
        let build = actions(.xcode, .init(xcodeContainer: "My App.xcodeproj"))["build"]?.body ?? ""
        #expect(build.contains("-project 'My App.xcodeproj' -scheme 'My App'"))
    }

    @Test func stackFileSlugsAreFilenameSafe() {
        #expect(RunScriptStack.swiftPackage.fileSlug == "swift-package")
        #expect(RunScriptStack.cargo.fileSlug == "cargo")
        for stack in RunScriptStack.allCases {
            #expect(!stack.fileSlug.contains(" "))
        }
    }

    @Test func pythonUsesDetectedRunner() {
        #expect(actions(.python, .init(pythonRunner: .uv))["test"]?.body == "uv run pytest")
        #expect(actions(.python, .init(pythonRunner: .uv))["install"]?.body == "uv sync")
        #expect(actions(.python, .init(pythonRunner: .poetry))["lint"]?.body == "poetry run ruff check .")
        #expect(actions(.python, .init(pythonRunner: .poetry))["install"]?.body == "poetry install")
        #expect(actions(.python)["test"]?.body == "pytest")
    }

    @Test func goAndSwiftPackageCoverWholeModule() {
        #expect(actions(.go)["test"]?.body == "go test ./...")
        #expect(actions(.swiftPackage)["test"]?.body == "swift test")
        #expect(actions(.make)["build"]?.body == "make")
    }

    /// `swift test` exits with "no tests found" for packages with only
    /// library/executable targets, so Test should only be preselected once the
    /// detector confirms a test target exists.
    @Test func swiftPackageTestIsUncheckedWithoutAConfirmedTestTarget() {
        #expect(actions(.swiftPackage)["test"]?.isCheckedByDefault == false)
        #expect(actions(.swiftPackage, .init(hasSwiftTestTarget: true))["test"]?.isCheckedByDefault == true)
    }

    /// "Run" fails outright against a library-only manifest, so it only
    /// defaults to checked once a runnable target is actually confirmed.
    @Test func runIsUncheckedWithoutAConfirmedRunnableTarget() {
        #expect(actions(.cargo)["run"]?.isCheckedByDefault == false)
        #expect(actions(.cargo, .init(hasRunnableTarget: true))["run"]?.isCheckedByDefault == true)
        #expect(actions(.swiftPackage)["run"]?.isCheckedByDefault == false)
        #expect(actions(.swiftPackage, .init(hasRunnableTarget: true))["run"]?.isCheckedByDefault == true)
    }

    /// Go's Run points at whatever command was actually confirmed, not
    /// blindly at the module root — "go run ." fails for a root library
    /// whose only command lives under cmd/.
    @Test func goRunPointsAtTheConfirmedCommandPath() {
        #expect(actions(.go)["run"]?.body == "go run .")
        #expect(actions(.go)["run"]?.isCheckedByDefault == false)
        #expect(actions(.go, .init(goRunTarget: "."))["run"]?.body == "go run .")
        #expect(actions(.go, .init(goRunTarget: "."))["run"]?.isCheckedByDefault == true)
        #expect(actions(.go, .init(goRunTarget: "./cmd/tool"))["run"]?.body == "go run ./cmd/tool")
        #expect(actions(.go, .init(goRunTarget: "./cmd/tool"))["run"]?.isCheckedByDefault == true)
        #expect(actions(.go, .init(goRunTarget: "./cmd/$(touch$IFS/tmp/pwn)"))["run"]?.body == "go run './cmd/$(touch$IFS/tmp/pwn)'")
    }

    @Test func dotnetRunUsesTheDetectedExecutableProject() {
        #expect(actions(.dotnet)["run"]?.body == "dotnet run")
        #expect(actions(.dotnet)["run"]?.isCheckedByDefault == false)
        let withProject = actions(.dotnet, .init(dotnetRunProject: "src/App.Cli/App.Cli.csproj"))["run"]
        #expect(withProject?.body == "dotnet run --project src/App.Cli/App.Cli.csproj")
        #expect(withProject?.isCheckedByDefault == true)
    }

    @Test func dotnetBuildActionsTargetTheDetectedSolution() {
        let solution = actions(.dotnet, .init(dotnetBuildTarget: "App.sln"))
        #expect(solution["restore"]?.body == "dotnet restore App.sln")
        #expect(solution["build"]?.body == "dotnet build App.sln")
        #expect(solution["test"]?.body == "dotnet test App.sln")
        #expect(solution["restore"]?.isCheckedByDefault == true)

        let ambiguous = actions(.dotnet, .init(dotnetCommandsChecked: false))
        #expect(ambiguous["restore"]?.body == "dotnet restore")
        #expect(ambiguous["restore"]?.isCheckedByDefault == false)
        #expect(ambiguous["build"]?.isCheckedByDefault == false)
        #expect(ambiguous["test"]?.isCheckedByDefault == false)
    }

    @Test func makeTestAndCleanAreOnlyCheckedWhenDeclared() {
        #expect(actions(.make)["build"]?.isCheckedByDefault == true)
        #expect(actions(.make)["test"]?.isCheckedByDefault == false)
        #expect(actions(.make)["clean"]?.isCheckedByDefault == false)
        #expect(actions(.make, .init(hasMakeTestTarget: true))["test"]?.isCheckedByDefault == true)
        #expect(actions(.make, .init(hasMakeCleanTarget: true))["clean"]?.isCheckedByDefault == true)
    }

    @Test func pythonTestAndLintAreOnlyCheckedWhenPyprojectMentionsThem() {
        #expect(actions(.python)["install"]?.isCheckedByDefault == true)
        #expect(actions(.python)["test"]?.isCheckedByDefault == false)
        #expect(actions(.python)["lint"]?.isCheckedByDefault == false)
        #expect(actions(.python, .init(hasPytest: true))["test"]?.isCheckedByDefault == true)
        #expect(actions(.python, .init(hasRuff: true))["lint"]?.isCheckedByDefault == true)
    }

    @Test func barePythonInstallsPyprojectWhenCheckedToolsComeFromPyproject() {
        let requirementsOnly = actions(.python, .init(hasRequirementsFile: true, hasPyprojectFile: true))
        #expect(requirementsOnly["install"]?.body == "python3 -m pip install -r requirements.txt")

        let withPytest = actions(.python, .init(hasRequirementsFile: true, hasPyprojectFile: true, hasPytest: true))
        #expect(withPytest["install"]?.body == "python3 -m pip install -e .")

        let withRuff = actions(.python, .init(hasRequirementsFile: true, hasPyprojectFile: true, hasRuff: true))
        #expect(withRuff["install"]?.body == "python3 -m pip install -e .")
    }

    @Test func oneShotCommandsCloseAndServersKeepThePane() {
        #expect(actions(.cargo)["build"]?.onExit == .close)
        #expect(actions(.cargo)["run"]?.onExit == .keep)
        #expect(actions(.javascript)["dev"]?.onExit == .keep)
        #expect(actions(.javascript)["install"]?.onExit == .close)
        #expect(actions(.compose)["up"]?.onExit == .keep)
        #expect(actions(.compose)["down"]?.onExit == .close)
    }

    @Test func railsDeclaresItsPortAndPicksTheTestRunner() {
        let rails = actions(.rails)
        #expect(rails["dev"]?.body == "bin/rails server")
        #expect(rails["dev"]?.endpoint == "http://localhost:3000")
        #expect(rails["test"]?.body == "bin/rails test")
        #expect(rails["lint"]?.isCheckedByDefault == false)
        let rspec = actions(.rails, .init(hasSpecDirectory: true, hasRubocopConfig: true))
        #expect(rspec["test"]?.body == "bundle exec rspec")
        #expect(rspec["lint"]?.isCheckedByDefault == true)
    }

    @Test func plainRubyFallsBackToRake() {
        #expect(actions(.ruby)["test"]?.body == "bundle exec rake test")
        #expect(actions(.ruby)["test"]?.isCheckedByDefault == false)
        #expect(actions(.ruby, .init(hasSpecDirectory: true))["test"]?.body == "bundle exec rspec")
        #expect(actions(.ruby, .init(hasSpecDirectory: true))["test"]?.isCheckedByDefault == true)
        #expect(actions(.ruby, .init(hasRakeTestTask: true))["test"]?.isCheckedByDefault == true)
    }

    @Test func djangoRunsManageThroughTheProjectRunner() {
        let bare = actions(.django)
        #expect(bare["dev"]?.body == "python3 manage.py runserver")
        #expect(bare["dev"]?.endpoint == "http://localhost:8000")
        #expect(bare["install"]?.body == "python3 -m pip install -e .")
        #expect(bare["install"]?.isCheckedByDefault == false)
        let requirements = actions(.django, .init(hasRequirementsFile: true))
        #expect(requirements["install"]?.body == "python3 -m pip install -r requirements.txt")
        #expect(requirements["install"]?.isCheckedByDefault == true)
        let pyproject = actions(.django, .init(hasPyprojectFile: true))
        #expect(pyproject["install"]?.body == "python3 -m pip install -e .")
        #expect(pyproject["install"]?.isCheckedByDefault == true)
        let uv = actions(.django, .init(pythonRunner: .uv))
        #expect(uv["migrate"]?.body == "uv run python manage.py migrate")
        #expect(uv["install"]?.isCheckedByDefault == true)
    }

    @Test func laravelAndPhpUseComposer() {
        #expect(actions(.laravel)["dev"]?.body == "php artisan serve")
        #expect(actions(.laravel)["dev"]?.endpoint == "http://localhost:8000")
        #expect(actions(.php)["test"]?.body == "vendor/bin/phpunit")
        #expect(actions(.php)["test"]?.isCheckedByDefault == false)
        #expect(actions(.php, .init(hasPHPUnit: true))["test"]?.isCheckedByDefault == true)
        #expect(actions(.php, .init(hasPHPUnit: true, phpUnitBinaryPath: "bin/phpunit"))["test"]?.body == "bin/phpunit")
        #expect(actions(.php, .init(hasPHPUnit: true, phpUnitBinaryPath: "custom bin/phpunit"))["test"]?.body == "'custom bin/phpunit'")
    }

    @Test func flutterFallsBackToDartAndDropsRun() {
        #expect(actions(.flutter)["run"]?.body == "flutter run")
        let dart = actions(.flutter, .init(usesFlutter: false))
        #expect(dart["test"]?.body == "dart test")
        #expect(dart["run"] == nil)
    }

    @Test func elixirOffersPhoenixServerOnlyWhenPresent() {
        #expect(actions(.elixir)["dev"]?.body == "mix phx.server")
        #expect(actions(.elixir)["dev"]?.endpoint == "http://localhost:4000")
        #expect(actions(.elixir, .init(usesPhoenix: false))["dev"] == nil)
    }

    @Test func remainingStacksUseTheirCanonicalCommands() {
        #expect(actions(.dotnet)["test"]?.body == "dotnet test")
        #expect(actions(.deno)["lint"]?.body == "deno lint")
        #expect(actions(.zig)["test"]?.body == "zig build test")
        #expect(actions(.bazel)["build"]?.body == "bazel build //...")
        #expect(actions(.compose)["up"]?.body == "docker compose up")
    }

    @Test func zigOptionalStepsAreUncheckedUnlessDeclared() {
        #expect(actions(.zig)["build"]?.isCheckedByDefault == true)
        #expect(actions(.zig)["test"]?.isCheckedByDefault == false)
        #expect(actions(.zig)["run"]?.isCheckedByDefault == false)
        #expect(actions(.zig, .init(zigBuildSteps: ["test"]))["test"]?.isCheckedByDefault == true)
        #expect(actions(.zig, .init(zigBuildSteps: ["run"]))["run"]?.isCheckedByDefault == true)
    }

    /// "deno task dev" only works if deno.json actually declares that task;
    /// unlike npm's built-in commands, Deno has no generic fallback.
    @Test func denoDevIsOnlyCheckedWhenTheTaskIsDeclared() {
        #expect(actions(.deno)["dev"]?.isCheckedByDefault == false)
        #expect(actions(.deno, .init(denoTasks: []))["dev"]?.isCheckedByDefault == false)
        #expect(actions(.deno, .init(denoTasks: ["dev"]))["dev"]?.isCheckedByDefault == true)
        #expect(actions(.deno)["test"]?.isCheckedByDefault == true)
    }

    private func zshSyntaxIsValid(_ contents: String) throws -> Bool {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).sh")
        try Data(contents.utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-n", url.path]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        return process.terminationStatus == 0
    }
}
