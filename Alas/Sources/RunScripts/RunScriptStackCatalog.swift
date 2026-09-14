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
}

enum JavaScriptPackageManager: String, Sendable, Hashable, CaseIterable {
    case npm, pnpm, yarn, bun
}

enum PythonRunner: String, Sendable, Hashable, CaseIterable {
    case bare, uv, poetry
}

/// What creation-time detection learned about a stack. The defaults describe
/// an undetected stack: system tools, no lockfile, every action worth offering.
struct RunScriptStackContext: Equatable, Sendable {
    /// A project-local wrapper (`gradlew`, `mvnw`, `kotlin`) was found.
    var hasWrapper = false
    var packageManager = JavaScriptPackageManager.npm
    /// `scripts` keys from package.json. Nil when no package.json was read,
    /// which offers every action rather than none.
    var packageScripts: Set<String>?
    var pythonRunner = PythonRunner.bare
    /// `App.xcodeproj` or `App.xcworkspace` found at the worktree root.
    var xcodeContainer: String?
    /// `spec/` exists, so RSpec is the Ruby test runner.
    var hasSpecDirectory = false
    var hasRubocopConfig = false
    var hasRequirementsFile = false
    /// pubspec.yaml depends on the Flutter SDK rather than plain Dart.
    var usesFlutter = true
    /// mix.exs depends on Phoenix, so there is a dev server to run.
    var usesPhoenix = true

    init(
        hasWrapper: Bool = false,
        packageManager: JavaScriptPackageManager = .npm,
        packageScripts: Set<String>? = nil,
        pythonRunner: PythonRunner = .bare,
        xcodeContainer: String? = nil,
        hasSpecDirectory: Bool = false,
        hasRubocopConfig: Bool = false,
        hasRequirementsFile: Bool = false,
        usesFlutter: Bool = true,
        usesPhoenix: Bool = true
    ) {
        self.hasWrapper = hasWrapper
        self.packageManager = packageManager
        self.packageScripts = packageScripts
        self.pythonRunner = pythonRunner
        self.xcodeContainer = xcodeContainer
        self.hasSpecDirectory = hasSpecDirectory
        self.hasRubocopConfig = hasRubocopConfig
        self.hasRequirementsFile = hasRequirementsFile
        self.usesFlutter = usesFlutter
        self.usesPhoenix = usesPhoenix
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
                .init("test", "Test", "\(run)pytest"),
                .init("lint", "Lint", "\(run)ruff check ."),
            ]
        case .django:
            let (install, run) = pythonCommands(context)
            let python = context.pythonRunner == .bare ? "python3" : "python"
            let manage = "\(run)\(python) manage.py"
            return [
                .init("install", "Install", install, checked: context.pythonRunner != .bare || context.hasRequirementsFile),
                .init("dev", "Dev server", "\(manage) runserver", onExit: .keep, endpoint: "http://localhost:8000"),
                .init("migrate", "Migrate", "\(manage) migrate"),
                .init("test", "Test", "\(manage) test"),
            ]
        case .gradle:
            let gradle = context.hasWrapper ? "./gradlew" : "gradle"
            return [
                .init("build", "Build", "\(gradle) assemble"),
                .init("test", "Test", "\(gradle) test"),
                .init("check", "Check", "\(gradle) check"),
                .init("clean", "Clean", "\(gradle) clean"),
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
            let kotlin = context.hasWrapper ? "./kotlin" : "kotlin"
            return [
                .init("build", "Build", "\(kotlin) build"),
                .init("test", "Test", "\(kotlin) test"),
                .init("check", "Check", "\(kotlin) check"),
                .init("run", "Run", "\(kotlin) run", onExit: .keep),
                .init("clean", "Clean", "\(kotlin) clean"),
            ]
        case .dotnet:
            return [
                .init("restore", "Restore", "dotnet restore"),
                .init("build", "Build", "dotnet build"),
                .init("test", "Test", "dotnet test"),
                .init("run", "Run", "dotnet run", onExit: .keep),
            ]
        case .go:
            return [
                .init("build", "Build", "go build ./..."),
                .init("test", "Test", "go test ./..."),
                .init("vet", "Vet", "go vet ./..."),
                .init("run", "Run", "go run .", onExit: .keep),
            ]
        case .cargo:
            return [
                .init("build", "Build", "cargo build"),
                .init("test", "Test", "cargo test"),
                .init("clippy", "Clippy", "cargo clippy --all-targets -- -D warnings"),
                .init("format-check", "Format check", "cargo fmt --all --check"),
                .init("run", "Run", "cargo run", onExit: .keep),
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
                .init("test", "Test", test),
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
                .init("test", "Test", "vendor/bin/phpunit"),
            ]
        case .swiftPackage:
            return [
                .init("build", "Build", "swift build"),
                .init("test", "Test", "swift test"),
                .init("run", "Run", "swift run", onExit: .keep),
            ]
        case .xcode:
            let container = context.xcodeContainer ?? "App.xcodeproj"
            let flag = container.hasSuffix(".xcworkspace") ? "-workspace" : "-project"
            let scheme = (container as NSString).deletingPathExtension
            let note = context.xcodeContainer == nil
                ? "# Set the project (or workspace) and scheme for this repository."
                : "# Adjust the scheme if it differs from the project name."
            let target = "\(flag) \(container) -scheme \(AppState.shellQuote(scheme)) -destination 'platform=macOS'"
            return [
                .init("build", "Build", "\(note)\nxcodebuild \(target) build"),
                .init("test", "Test", "\(note)\nxcodebuild \(target) test"),
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
                .init("test", "Test", "make test"),
                .init("clean", "Clean", "make clean"),
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
            return [
                .init("dev", "Dev server", "\(devServerHint)\ndeno task dev", onExit: .keep),
                .init("test", "Test", "deno test"),
                .init("lint", "Lint", "deno lint"),
                .init("format-check", "Format check", "deno fmt --check"),
            ]
        case .zig:
            return [
                .init("build", "Build", "zig build"),
                .init("test", "Test", "zig build test"),
                .init("run", "Run", "zig build run", onExit: .keep),
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
            context.hasRequirementsFile
                ? ("python3 -m pip install -r requirements.txt", "")
                : ("python3 -m pip install -e .", "")
        }
    }
}
