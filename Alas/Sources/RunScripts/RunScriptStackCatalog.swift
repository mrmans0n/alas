import Foundation

/// Build-tool families Alas can bootstrap a bundle of run scripts for.
/// Order is rough ecosystem popularity; it is also the order the picker
/// lists undetected stacks in and the order detections are reported in.
enum RunScriptStack: String, CaseIterable, Identifiable, Sendable, Hashable {
    case javascript, python, django, gradle, maven, kotlin, dotnet, go, cargo
    case rails, ruby, laravel, php, swiftPackage, xcode, cmake, make
    case flutter, elixir, deno, zig, bazel, compose

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .javascript:   "JavaScript / TypeScript"
        case .python:       "Python"
        case .django:       "Django"
        case .gradle:       "Gradle"
        case .maven:        "Maven"
        case .kotlin:       "Kotlin toolchain"
        case .dotnet:       ".NET"
        case .go:           "Go"
        case .cargo:        "Cargo"
        case .rails:        "Rails"
        case .ruby:         "Ruby (Bundler)"
        case .laravel:      "Laravel"
        case .php:          "PHP (Composer)"
        case .swiftPackage: "Swift Package"
        case .xcode:        "Xcode"
        case .cmake:        "CMake"
        case .make:         "Make"
        case .flutter:      "Flutter / Dart"
        case .elixir:       "Elixir (Mix)"
        case .deno:         "Deno"
        case .zig:          "Zig"
        case .bazel:        "Bazel"
        case .compose:      "Docker Compose"
        }
    }

    /// Kebab-case identifier used to namespace bundle filenames per stack
    /// (`cargo-build.sh`), so two stacks never collide on a shared action id.
    var fileSlug: String {
        switch self {
        case .swiftPackage: "swift-package"
        default:            rawValue
        }
    }
}

enum JavaScriptPackageManager: String, Sendable, Hashable, CaseIterable {
    case npm, pnpm, yarn, bun
}

enum PythonRunner: String, Sendable, Hashable, CaseIterable {
    case bare, uv, poetry
}

/// `module.yaml`/`project.yaml` is shared by legacy Amper and the Kotlin
/// toolchain that replaced it, so a wrapper file's own name is the only way
/// to tell which CLI a still-unmigrated repository actually has installed.
enum KotlinToolchainWrapper: Sendable, Hashable {
    /// `./amper` wrapper present — the repository has not migrated yet.
    case amper
    /// `./kotlin` wrapper present.
    case kotlin
    /// No project-local wrapper; fall back to the system `kotlin` command,
    /// the tool JetBrains ships going forward.
    case system
}

/// What creation-time detection learned about a stack. The defaults describe
/// an undetected stack: system tools, no lockfile, every action worth offering.
struct RunScriptStackContext: Equatable, Sendable {
    /// A project-local wrapper (`gradlew`, `mvnw`) was found.
    var hasWrapper = false
    /// Gradle task names confirmed from the build files. Nil means no build
    /// file could be read; optional tasks stay unchecked.
    var gradleTasks: Set<String>?
    var kotlinWrapper = KotlinToolchainWrapper.system
    var packageManager = JavaScriptPackageManager.npm
    /// `scripts` keys from package.json. Nil when no package.json was read,
    /// which offers every action rather than none.
    var packageScripts: Set<String>?
    var pythonRunner = PythonRunner.bare
    /// `App.xcodeproj` or `App.xcworkspace` found at the worktree root.
    var xcodeContainer: String?
    /// `spec/` exists, so RSpec is the Ruby test runner.
    var hasSpecDirectory = false
    /// Gemfile/Rakefile confirm that `bundle exec rake test` has a target.
    var hasRakeTestTask = false
    var hasRubocopConfig = false
    var hasRequirementsFile = false
    /// pyproject.toml exists, so the default bare-Python install command can
    /// install the project itself with `python3 -m pip install -e .`.
    var hasPyprojectFile = false
    /// Whether pyproject.toml mentions pytest/ruff anywhere — a dependency
    /// line, an optional-dependency group, or a `[tool.pytest]`/`[tool.ruff]`
    /// config section. A runtime-only library that never mentions either
    /// tool most likely doesn't have it installed.
    var hasPytest = false
    var hasRuff = false
    /// composer.json declares PHPUnit or a local vendor/bin/phpunit exists.
    var hasPHPUnit = false
    /// Composer's configured PHPUnit proxy path, relative to the worktree.
    var phpUnitBinaryPath = "vendor/bin/phpunit"
    /// pubspec.yaml depends on the Flutter SDK rather than plain Dart.
    var usesFlutter = true
    /// mix.exs depends on Phoenix, so there is a dev server to run.
    var usesPhoenix = true
    /// `tasks` keys from deno.json/deno.jsonc. Nil when the file couldn't be
    /// read or parsed, which — unlike package.json — leaves "Dev server"
    /// unchecked rather than assuming a task exists: `deno task dev` has no
    /// generic fallback the way `npm test` does.
    var denoTasks: Set<String>?
    /// User-declared `zig build <step>` names from build.zig. Nil when
    /// build.zig could not be read, which leaves optional steps unchecked.
    var zigBuildSteps: Set<String>?
    /// Shared by Cargo and Swift Package: whether the repository has an
    /// actual runnable target (a `[[bin]]`/`src/bin`, an executable
    /// product). Defaults to false — "Run" fails outright against a
    /// library-only manifest, so it's opt-in rather than assumed.
    var hasRunnableTarget = false
    /// Swift Package manifests need at least one `.testTarget` before
    /// `swift test` can succeed; library-only packages exit with
    /// "no tests found".
    var hasSwiftTestTarget = false
    /// The path argument for `go run` that actually contains `package main`
    /// — "." for a root-level main package, "./cmd/<name>" for the first
    /// command found under the cmd/ convention. Nil when neither is
    /// confirmed: a root library with a `cmd/` subpackage is not itself
    /// runnable, so `go run .` would fail even though a command exists.
    var goRunTarget: String?
    /// The project path (relative to the worktree root) whose OutputType is
    /// confirmed executable, for `dotnet run --project <path>`. Nil means no
    /// executable project was found — bare `dotnet run` resolves from the
    /// current directory alone, so a root .sln with projects in
    /// subdirectories otherwise has nothing to run.
    var dotnetRunProject: String?
    /// A single root solution or project file for `dotnet restore/build/test`.
    /// Nil means the generic command can run from the root, unless
    /// `dotnetCommandsChecked` is false because multiple root containers make
    /// the CLI ambiguous.
    var dotnetBuildTarget: String?
    var dotnetCommandsChecked = true
    /// Whether the Makefile declares a `test` rule of its own.
    var hasMakeTestTarget = false
    /// Whether the Makefile declares a `clean` rule of its own.
    var hasMakeCleanTarget = false

    init(
        hasWrapper: Bool = false,
        gradleTasks: Set<String>? = nil,
        kotlinWrapper: KotlinToolchainWrapper = .system,
        packageManager: JavaScriptPackageManager = .npm,
        packageScripts: Set<String>? = nil,
        pythonRunner: PythonRunner = .bare,
        xcodeContainer: String? = nil,
        hasSpecDirectory: Bool = false,
        hasRakeTestTask: Bool = false,
        hasRubocopConfig: Bool = false,
        hasRequirementsFile: Bool = false,
        hasPyprojectFile: Bool = false,
        hasPytest: Bool = false,
        hasRuff: Bool = false,
        hasPHPUnit: Bool = false,
        phpUnitBinaryPath: String = "vendor/bin/phpunit",
        usesFlutter: Bool = true,
        usesPhoenix: Bool = true,
        denoTasks: Set<String>? = nil,
        zigBuildSteps: Set<String>? = nil,
        hasRunnableTarget: Bool = false,
        hasSwiftTestTarget: Bool = false,
        goRunTarget: String? = nil,
        dotnetRunProject: String? = nil,
        dotnetBuildTarget: String? = nil,
        dotnetCommandsChecked: Bool = true,
        hasMakeTestTarget: Bool = false,
        hasMakeCleanTarget: Bool = false
    ) {
        self.hasWrapper = hasWrapper
        self.gradleTasks = gradleTasks
        self.kotlinWrapper = kotlinWrapper
        self.packageManager = packageManager
        self.packageScripts = packageScripts
        self.pythonRunner = pythonRunner
        self.xcodeContainer = xcodeContainer
        self.hasSpecDirectory = hasSpecDirectory
        self.hasRakeTestTask = hasRakeTestTask
        self.hasRubocopConfig = hasRubocopConfig
        self.hasRequirementsFile = hasRequirementsFile
        self.hasPyprojectFile = hasPyprojectFile
        self.hasPytest = hasPytest
        self.hasRuff = hasRuff
        self.hasPHPUnit = hasPHPUnit
        self.phpUnitBinaryPath = phpUnitBinaryPath
        self.usesFlutter = usesFlutter
        self.usesPhoenix = usesPhoenix
        self.denoTasks = denoTasks
        self.zigBuildSteps = zigBuildSteps
        self.dotnetRunProject = dotnetRunProject
        self.dotnetBuildTarget = dotnetBuildTarget
        self.dotnetCommandsChecked = dotnetCommandsChecked
        self.hasMakeTestTarget = hasMakeTestTarget
        self.hasMakeCleanTarget = hasMakeCleanTarget
        self.hasRunnableTarget = hasRunnableTarget
        self.hasSwiftTestTarget = hasSwiftTestTarget
        self.goRunTarget = goRunTarget
    }
}

/// One script a stack template can write. `body` is everything after the
/// header and `set -euo pipefail`; decisions like wrapper-vs-system tool are
/// baked in here so the file reads like something written by hand.
///
/// One-shot commands close their pane on exit and rely on the finish
/// notification and failure inbox; long-running ones (servers, `run`) keep it.
struct RunScriptStackAction: Identifiable, Equatable, Sendable {
    let id: String
    let displayName: String
    let body: String
    let isCheckedByDefault: Bool
    let onExit: RunScriptOnExit
    /// Declared as `# alas-url:` when the server's default port is known.
    let endpoint: String?

    init(
        _ id: String,
        _ displayName: String,
        _ body: String,
        checked: Bool = true,
        onExit: RunScriptOnExit = .close,
        endpoint: String? = nil
    ) {
        self.id = id
        self.displayName = displayName
        self.body = body
        self.isCheckedByDefault = checked
        self.onExit = onExit
        self.endpoint = endpoint
    }
}

enum RunScriptStackCatalog {
    private static let devServerHint =
        "# Add a header line like \"# alas-url: http://localhost:3000\" so Alas can open the server."

    // swiftlint:disable:next function_body_length cyclomatic_complexity
    static func actions(for stack: RunScriptStack, context: RunScriptStackContext = .init()) -> [RunScriptStackAction] {
        switch stack {
        case .javascript:
            let pm = context.packageManager.rawValue
            func declares(_ script: String) -> Bool {
                context.packageScripts?.contains(script) ?? true
            }
            return [
                .init("install", "Install", "\(pm) install"),
                .init("dev", "Dev server", "\(devServerHint)\n\(pm) run dev", checked: declares("dev"), onExit: .keep),
                .init("build", "Build", "\(pm) run build", checked: declares("build")),
                .init("test", "Test", "\(pm) run test", checked: declares("test")),
                .init("lint", "Lint", "\(pm) run lint", checked: declares("lint")),
            ]
        case .python:
            let (install, run) = pythonCommands(context)
            return [
                .init("install", "Install", install),
                .init("test", "Test", "\(run)pytest", checked: context.hasPytest),
                .init("lint", "Lint", "\(run)ruff check .", checked: context.hasRuff),
            ]
        case .django:
            let (install, run) = pythonCommands(context)
            let python = context.pythonRunner == .bare ? "python3" : "python"
            let manage = "\(run)\(python) manage.py"
            return [
                .init("install", "Install", install, checked: context.pythonRunner != .bare || context.hasRequirementsFile || context.hasPyprojectFile),
                .init("dev", "Dev server", "\(manage) runserver", onExit: .keep, endpoint: "http://localhost:8000"),
                .init("migrate", "Migrate", "\(manage) migrate"),
                .init("test", "Test", "\(manage) test"),
            ]
        case .gradle:
            let gradle = context.hasWrapper ? "./gradlew" : "gradle"
            return [
                .init("build", "Build", "\(gradle) assemble", checked: context.gradleTasks?.contains("assemble") ?? false),
                .init("test", "Test", "\(gradle) test", checked: context.gradleTasks?.contains("test") ?? false),
                .init("check", "Check", "\(gradle) check", checked: context.gradleTasks?.contains("check") ?? false),
                .init("clean", "Clean", "\(gradle) clean", checked: context.gradleTasks?.contains("clean") ?? false),
            ]
        case .maven:
            let mvn = context.hasWrapper ? "./mvnw" : "mvn"
            return [
                .init("build", "Build", "\(mvn) -B -DskipTests package"),
                .init("test", "Test", "\(mvn) -B test"),
                .init("verify", "Verify", "\(mvn) -B verify"),
                .init("clean", "Clean", "\(mvn) -B clean"),
            ]
        case .kotlin:
            let kotlin: String
            switch context.kotlinWrapper {
            case .amper:  kotlin = "./amper"
            case .kotlin: kotlin = "./kotlin"
            case .system: kotlin = "kotlin"
            }
            return [
                .init("build", "Build", "\(kotlin) build"),
                .init("test", "Test", "\(kotlin) test"),
                .init("check", "Check", "\(kotlin) check"),
                .init("run", "Run", "\(kotlin) run", onExit: .keep),
                .init("clean", "Clean", "\(kotlin) clean"),
            ]
        case .dotnet:
            let runCommand = context.dotnetRunProject
                .map { "dotnet run --project \(AppState.shellQuote($0))" } ?? "dotnet run"
            let buildTarget = context.dotnetBuildTarget.map { " \(AppState.shellQuote($0))" } ?? ""
            return [
                .init("restore", "Restore", "dotnet restore\(buildTarget)", checked: context.dotnetCommandsChecked),
                .init("build", "Build", "dotnet build\(buildTarget)", checked: context.dotnetCommandsChecked),
                .init("test", "Test", "dotnet test\(buildTarget)", checked: context.dotnetCommandsChecked),
                .init("run", "Run", runCommand, checked: context.dotnetRunProject != nil, onExit: .keep),
            ]
        case .go:
            return [
                .init("build", "Build", "go build ./..."),
                .init("test", "Test", "go test ./..."),
                .init("vet", "Vet", "go vet ./..."),
                .init(
                    "run", "Run", "go run \(AppState.shellQuote(context.goRunTarget ?? "."))",
                    checked: context.goRunTarget != nil, onExit: .keep
                ),
            ]
        case .cargo:
            return [
                .init("build", "Build", "cargo build"),
                .init("test", "Test", "cargo test"),
                .init("clippy", "Clippy", "cargo clippy --all-targets -- -D warnings"),
                .init("format-check", "Format check", "cargo fmt --all --check"),
                .init("run", "Run", "cargo run", checked: context.hasRunnableTarget, onExit: .keep),
                .init("clean", "Clean", "cargo clean"),
            ]
        case .rails:
            let test = context.hasSpecDirectory ? "bundle exec rspec" : "bin/rails test"
            return [
                .init("install", "Install", "bundle install"),
                .init("dev", "Dev server", "bin/rails server", onExit: .keep, endpoint: "http://localhost:3000"),
                .init("migrate", "Migrate", "bin/rails db:migrate"),
                .init("test", "Test", test),
                .init("lint", "Lint", "bundle exec rubocop", checked: context.hasRubocopConfig),
            ]
        case .ruby:
            let test = context.hasSpecDirectory ? "bundle exec rspec" : "bundle exec rake test"
            return [
                .init("install", "Install", "bundle install"),
                .init("test", "Test", test, checked: context.hasSpecDirectory || context.hasRakeTestTask),
                .init("lint", "Lint", "bundle exec rubocop", checked: context.hasRubocopConfig),
            ]
        case .laravel:
            return [
                .init("install", "Install", "composer install"),
                .init("dev", "Dev server", "php artisan serve", onExit: .keep, endpoint: "http://localhost:8000"),
                .init("migrate", "Migrate", "php artisan migrate"),
                .init("test", "Test", "php artisan test"),
            ]
        case .php:
            return [
                .init("install", "Install", "composer install"),
                .init("test", "Test", AppState.shellQuote(context.phpUnitBinaryPath), checked: context.hasPHPUnit),
            ]
        case .swiftPackage:
            return [
                .init("build", "Build", "swift build"),
                .init("test", "Test", "swift test", checked: context.hasSwiftTestTarget),
                .init("run", "Run", "swift run", checked: context.hasRunnableTarget, onExit: .keep),
            ]
        case .xcode:
            let container = context.xcodeContainer ?? "App.xcodeproj"
            let flag = container.hasSuffix(".xcworkspace") ? "-workspace" : "-project"
            let scheme = (container as NSString).deletingPathExtension
            let note = context.xcodeContainer == nil
                ? "# Set the project (or workspace) and scheme for this repository."
                : "# Adjust the scheme if it differs from the project name."
            // The container name alone doesn't say which platform the scheme
            // targets, so a hard-coded macOS destination would break an
            // iOS/watchOS/tvOS/visionOS-only scheme. Leave it to xcodebuild's
            // own default and let the user pin a destination if they need one.
            let destinationNote =
                "# Add -destination if this scheme needs one, e.g. -destination 'platform=macOS' or 'generic/platform=iOS Simulator'."
            let target = "\(flag) \(AppState.shellQuote(container)) -scheme \(AppState.shellQuote(scheme))"
            return [
                .init("build", "Build", "\(note)\n\(destinationNote)\nxcodebuild \(target) build"),
                .init("test", "Test", "\(note)\n\(destinationNote)\nxcodebuild \(target) test"),
            ]
        case .cmake:
            return [
                .init("configure", "Configure", "cmake -S . -B build -DCMAKE_BUILD_TYPE=Debug"),
                .init("build", "Build", "cmake --build build"),
                .init("test", "Test", "ctest --test-dir build --output-on-failure"),
                .init("clean", "Clean", "cmake --build build --target clean"),
            ]
        case .make:
            return [
                .init("build", "Build", "make"),
                .init("test", "Test", "make test", checked: context.hasMakeTestTarget),
                .init("clean", "Clean", "make clean", checked: context.hasMakeCleanTarget),
            ]
        case .flutter:
            let tool = context.usesFlutter ? "flutter" : "dart"
            var actions: [RunScriptStackAction] = [
                .init("get", "Get packages", "\(tool) pub get"),
                .init("analyze", "Analyze", "\(tool) analyze"),
                .init("test", "Test", "\(tool) test"),
            ]
            if context.usesFlutter {
                actions.append(.init("run", "Run", "flutter run", onExit: .keep))
            }
            return actions
        case .elixir:
            var actions: [RunScriptStackAction] = [
                .init("deps", "Get dependencies", "mix deps.get"),
                .init("compile", "Compile", "mix compile"),
                .init("test", "Test", "mix test"),
                .init("format-check", "Format check", "mix format --check-formatted"),
            ]
            if context.usesPhoenix {
                actions.insert(
                    .init("dev", "Dev server", "mix phx.server", onExit: .keep, endpoint: "http://localhost:4000"),
                    at: 1
                )
            }
            return actions
        case .deno:
            // Unlike the rest of Deno's actions, "dev" runs a user-defined
            // task rather than a built-in subcommand, so it only exists if
            // deno.json actually declares one.
            return [
                .init(
                    "dev", "Dev server", "\(devServerHint)\ndeno task dev",
                    checked: context.denoTasks?.contains("dev") ?? false, onExit: .keep
                ),
                .init("test", "Test", "deno test"),
                .init("lint", "Lint", "deno lint"),
                .init("format-check", "Format check", "deno fmt --check"),
            ]
        case .zig:
            return [
                .init("build", "Build", "zig build"),
                .init("test", "Test", "zig build test", checked: context.zigBuildSteps?.contains("test") ?? false),
                .init("run", "Run", "zig build run", checked: context.zigBuildSteps?.contains("run") ?? false, onExit: .keep),
            ]
        case .bazel:
            return [
                .init("build", "Build", "bazel build //..."),
                .init("test", "Test", "bazel test //..."),
            ]
        case .compose:
            return [
                .init("up", "Up", "docker compose up", onExit: .keep),
                .init("build", "Build", "docker compose build"),
                .init("down", "Down", "docker compose down"),
            ]
        }
    }

    /// (install command, prefix for running a tool inside the project env).
    private static func pythonCommands(_ context: RunScriptStackContext) -> (install: String, run: String) {
        switch context.pythonRunner {
        case .uv:     ("uv sync", "uv run ")
        case .poetry: ("poetry install", "poetry run ")
        case .bare:
            context.hasPyprojectFile && (context.hasPytest || context.hasRuff)
                ? ("python3 -m pip install -e .", "")
                : context.hasRequirementsFile
                ? ("python3 -m pip install -r requirements.txt", "")
                : ("python3 -m pip install -e .", "")
        }
    }
}
