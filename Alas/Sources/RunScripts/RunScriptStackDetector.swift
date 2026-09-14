import Foundation

struct RunScriptStackDetection: Identifiable, Equatable, Sendable {
    let stack: RunScriptStack
    let context: RunScriptStackContext

    var id: RunScriptStack { stack }
}

/// Creation-time stack detection from marker files at the worktree root.
/// Reads one directory listing plus, when present, a few small manifests.
/// Results follow `RunScriptStack.allCases` order so the picker is stable.
enum RunScriptStackDetector {
    // swiftlint:disable:next function_body_length cyclomatic_complexity
    static func detect(worktreeRoot: URL, fileManager: FileManager = .default) -> [RunScriptStackDetection] {
        guard let names = try? fileManager.contentsOfDirectory(atPath: worktreeRoot.path) else { return [] }
        let entries = Set(names)
        func path(_ name: String) -> String { worktreeRoot.appendingPathComponent(name).path }
        func isRegularFile(_ name: String) -> Bool {
            var isDirectory: ObjCBool = false
            return fileManager.fileExists(atPath: path(name), isDirectory: &isDirectory) && !isDirectory.boolValue
        }
        func isDirectory(_ name: String) -> Bool {
            var isDirectory: ObjCBool = false
            return fileManager.fileExists(atPath: path(name), isDirectory: &isDirectory) && isDirectory.boolValue
        }
        func has(_ candidates: String...) -> Bool {
            candidates.contains { entries.contains($0) }
        }
        func contents(_ name: String) -> String? {
            guard entries.contains(name), let data = fileManager.contents(atPath: path(name)) else { return nil }
            return String(decoding: data, as: UTF8.self)
        }

        let pythonRunner: PythonRunner = entries.contains("uv.lock") ? .uv
            : entries.contains("poetry.lock") ? .poetry
            : .bare
        let hasRequirements = entries.contains("requirements.txt")
        let hasRails = isRegularFile("bin/rails")
        let hasArtisan = entries.contains("artisan")
        let hasDjangoManage = entries.contains("manage.py")
        let hasSpec = isDirectory("spec")
        let hasRubocop = has(".rubocop.yml")

        var detections: [RunScriptStackDetection] = []
        func add(_ stack: RunScriptStack, _ context: RunScriptStackContext = .init()) {
            detections.append(.init(stack: stack, context: context))
        }

        for stack in RunScriptStack.allCases {
            switch stack {
            case .javascript:
                guard has("package.json") else { continue }
                let manifest = PackageManifest(url: worktreeRoot.appendingPathComponent("package.json"))
                let packageManager: JavaScriptPackageManager
                if entries.contains("pnpm-lock.yaml") {
                    packageManager = .pnpm
                } else if entries.contains("yarn.lock") {
                    packageManager = .yarn
                } else if has("bun.lock", "bun.lockb") {
                    packageManager = .bun
                } else {
                    packageManager = manifest?.packageManager ?? .npm
                }
                add(stack, .init(packageManager: packageManager, packageScripts: manifest?.scripts))
            case .python:
                // Django owns the Python build; only offer generic Python
                // when there is no manage.py, the same way Rails/Ruby and
                // Laravel/PHP defer to their framework-specific stack.
                guard has("pyproject.toml"), !hasDjangoManage else { continue }
                add(stack, .init(pythonRunner: pythonRunner, hasRequirementsFile: hasRequirements))
            case .django:
                guard hasDjangoManage else { continue }
                add(stack, .init(pythonRunner: pythonRunner, hasRequirementsFile: hasRequirements))
            case .gradle:
                guard has("gradlew", "build.gradle", "build.gradle.kts", "settings.gradle", "settings.gradle.kts") else { continue }
                add(stack, .init(hasWrapper: entries.contains("gradlew")))
            case .maven:
                guard has("pom.xml") else { continue }
                add(stack, .init(hasWrapper: entries.contains("mvnw")))
            case .kotlin:
                // module.yaml/project.yaml is shared by legacy Amper and the
                // Kotlin toolchain that replaced it; the wrapper's own name
                // is what tells a not-yet-migrated repo from a migrated one.
                guard has("module.yaml", "project.yaml") else { continue }
                let wrapper: KotlinToolchainWrapper
                if isRegularFile("amper") {
                    wrapper = .amper
                } else if isRegularFile("kotlin") {
                    wrapper = .kotlin
                } else {
                    wrapper = .system
                }
                add(stack, .init(kotlinWrapper: wrapper))
            case .dotnet:
                guard names.contains(where: { $0.hasSuffix(".sln") || $0.hasSuffix(".csproj") || $0.hasSuffix(".fsproj") }) else { continue }
                add(stack)
            case .go:
                guard has("go.mod") else { continue }
                add(stack)
            case .cargo:
                guard has("Cargo.toml") else { continue }
                add(stack)
            case .rails:
                guard hasRails else { continue }
                add(stack, .init(hasSpecDirectory: hasSpec, hasRubocopConfig: hasRubocop))
            case .ruby:
                // Rails owns the Ruby build; only offer plain Bundler otherwise.
                guard has("Gemfile"), !hasRails else { continue }
                add(stack, .init(hasSpecDirectory: hasSpec, hasRubocopConfig: hasRubocop))
            case .laravel:
                guard hasArtisan else { continue }
                add(stack)
            case .php:
                guard has("composer.json"), !hasArtisan else { continue }
                add(stack)
            case .swiftPackage:
                guard has("Package.swift") else { continue }
                add(stack)
            case .xcode:
                let workspaces = names.filter { $0.hasSuffix(".xcworkspace") }.sorted()
                let projects = names.filter { $0.hasSuffix(".xcodeproj") }.sorted()
                guard let container = workspaces.first ?? projects.first else { continue }
                add(stack, .init(xcodeContainer: container))
            case .cmake:
                guard has("CMakeLists.txt") else { continue }
                add(stack)
            case .make:
                // CMake generates its own Makefile; only offer plain Make when
                // nothing else owns the build.
                guard has("Makefile", "makefile", "GNUmakefile"), !has("CMakeLists.txt") else { continue }
                add(stack)
            case .flutter:
                guard let pubspec = contents("pubspec.yaml") else { continue }
                add(stack, .init(usesFlutter: pubspecDeclaresFlutterSDK(pubspec)))
            case .elixir:
                guard let mix = contents("mix.exs") else { continue }
                add(stack, .init(usesPhoenix: mixDeclaresPhoenixDependency(mix)))
            case .deno:
                guard has("deno.json", "deno.jsonc") else { continue }
                add(stack)
            case .zig:
                guard has("build.zig") else { continue }
                add(stack)
            case .bazel:
                guard has("MODULE.bazel", "WORKSPACE", "WORKSPACE.bazel") else { continue }
                add(stack)
            case .compose:
                guard has("compose.yaml", "compose.yml", "docker-compose.yaml", "docker-compose.yml") else { continue }
                add(stack)
            }
        }
        return detections
    }

    /// A `dependencies:` entry that pins the Flutter SDK, e.g.
    /// ```yaml
    /// dependencies:
    ///   flutter:
    ///     sdk: flutter
    /// ```
    /// A bare substring check would also fire on a Dart-only package whose
    /// description mentions Flutter, or a `flutter_lints` dev dependency.
    private static func pubspecDeclaresFlutterSDK(_ pubspec: String) -> Bool {
        pubspec.range(
            of: #"(?m)^\s*flutter:\s*\r?\n\s*sdk:\s*flutter\s*$"#,
            options: .regularExpression
        ) != nil
    }

    /// A `{:phoenix, ...}` dependency atom in mix.exs's deps list. A bare
    /// substring check on ":phoenix" also matches unrelated packages that
    /// share the prefix, like `:phoenix_pubsub` or `:phoenix_live_view`.
    private static func mixDeclaresPhoenixDependency(_ mix: String) -> Bool {
        mix.range(of: #":phoenix(?![A-Za-z0-9_])"#, options: .regularExpression) != nil
    }

    /// The parts of package.json creation cares about. A manifest that fails
    /// to parse yields nil so callers fall back to "offer everything".
    private struct PackageManifest {
        let scripts: Set<String>
        let packageManager: JavaScriptPackageManager?

        init?(url: URL) {
            guard let data = try? Data(contentsOf: url),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { return nil }
            self.scripts = Set((object["scripts"] as? [String: Any])?.keys.map { $0 } ?? [])
            let declared = (object["packageManager"] as? String)?
                .split(separator: "@", maxSplits: 1)
                .first
                .map(String.init)
            self.packageManager = declared.flatMap(JavaScriptPackageManager.init(rawValue:))
        }
    }
}
