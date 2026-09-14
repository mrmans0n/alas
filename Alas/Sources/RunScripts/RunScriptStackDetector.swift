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
                add(stack, .init(goRunTarget: goRunnableTarget(rootEntries: names, worktreeRoot: worktreeRoot, fileManager: fileManager)))
            case .cargo:
                guard has("Cargo.toml") else { continue }
                let hasBinary = isRegularFile("src/main.rs") || isDirectory("src/bin")
                    || (contents("Cargo.toml")?.contains("[[bin]]") ?? false)
                add(stack, .init(hasRunnableTarget: hasBinary))
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
                let manifest = contents("Package.swift") ?? ""
                let hasExecutable = manifest.contains(".executableTarget")
                    || manifest.range(of: #"type:\s*\.executable"#, options: .regularExpression) != nil
                add(stack, .init(hasRunnableTarget: hasExecutable))
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
                let denoTasks = (contents("deno.json") ?? contents("deno.jsonc")).flatMap { text -> Set<String>? in
                    guard let object = parseJSONC(text) else { return nil }
                    return Set((object["tasks"] as? [String: Any])?.keys.map { $0 } ?? [])
                }
                add(stack, .init(denoTasks: denoTasks))
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

    /// A `dependencies:` entry that pins the Flutter SDK, in either the
    /// common block form:
    /// ```yaml
    /// dependencies:
    ///   flutter:
    ///     sdk: flutter
    /// ```
    /// or flow form (`flutter: { sdk: flutter }`), tolerating a comment
    /// between the two lines. A bare substring check would also fire on a
    /// Dart-only package whose description mentions Flutter, or a
    /// `flutter_lints` dev dependency.
    private static func pubspecDeclaresFlutterSDK(_ pubspec: String) -> Bool {
        let lines = pubspec.components(separatedBy: .newlines)
        for (index, rawLine) in lines.enumerated() {
            guard let mapping = yamlMappingLine(stripLineComment(rawLine)), mapping.key == "flutter" else { continue }
            if let value = mapping.value {
                // Flow form: the "sdk: flutter" pair lives on the same line.
                // The scalar may be quoted ("flutter" or 'flutter').
                if value.range(of: #"sdk:\s*['"]?flutter['"]?\b"#, options: .regularExpression) != nil { return true }
                continue // A non-flow, non-empty value can't be the SDK form.
            }
            // Block form: scan the nested lines for "sdk: flutter", skipping
            // blank lines and comments, stopping once indentation returns to
            // this level or shallower.
            for candidate in lines[(index + 1)...] {
                let stripped = stripLineComment(candidate)
                if stripped.trimmingCharacters(in: .whitespaces).isEmpty { continue }
                guard let child = yamlMappingLine(stripped), child.indent > mapping.indent else { break }
                if child.key == "sdk", let value = child.value, unquoteYAMLScalar(value.trimmingCharacters(in: .whitespaces)) == "flutter" {
                    return true
                }
            }
        }
        // Fallback for a fully flow-style dependencies block, e.g.
        // `dependencies: { flutter: { sdk: flutter } }`, where "flutter" is
        // never a line's own key because the whole map is inline. Comments
        // are stripped first so a mention inside one, e.g.
        // `# flutter: { sdk: flutter }`, doesn't count.
        let commentsStripped = lines.map(stripLineComment).joined(separator: "\n")
        return commentsStripped.range(
            of: #"flutter\s*:\s*\{\s*sdk\s*:\s*['"]?flutter['"]?\s*\}"#,
            options: .regularExpression
        ) != nil
    }

    /// A `{:phoenix, ...}` dependency atom in mix.exs's deps list. A bare
    /// substring check on ":phoenix" also matches unrelated packages that
    /// share the prefix, like `:phoenix_pubsub` or `:phoenix_live_view`, and
    /// would fire on a dependency left commented out.
    private static func mixDeclaresPhoenixDependency(_ mix: String) -> Bool {
        let stripped = mix.components(separatedBy: .newlines).map(stripLineComment).joined(separator: "\n")
        // Anchor to the actual dependency-tuple shape `{:phoenix, ...}` rather
        // than any occurrence of the atom: a bare ":phoenix" also matches
        // inside an unrelated string literal, e.g. a package description.
        return stripped.range(of: #"\{\s*:phoenix\s*,"#, options: .regularExpression) != nil
    }

    /// Whether a Go source file declares `package main`, the marker that
    /// distinguishes a runnable command from a library package.
    private static func goFileDeclaresPackageMain(_ contents: String?) -> Bool {
        guard let contents else { return false }
        return contents.range(of: #"(?m)^\s*package\s+main\s*$"#, options: .regularExpression) != nil
    }

    /// The path argument for `go run` that actually contains `package main`:
    /// "." for a root-level main package, or "./cmd/<name>" for the first
    /// command found under the cmd/ convention (Go's `run` compiles and runs
    /// exactly the named main package — a `cmd/` subpackage does not make
    /// the module root itself runnable). Nil when neither is confirmed.
    private static func goRunnableTarget(rootEntries: [String], worktreeRoot: URL, fileManager: FileManager) -> String? {
        func fileText(_ relativePath: String) -> String? {
            guard let data = fileManager.contents(atPath: worktreeRoot.appendingPathComponent(relativePath).path) else { return nil }
            return String(decoding: data, as: UTF8.self)
        }
        if rootEntries.contains(where: { $0.hasSuffix(".go") && goFileDeclaresPackageMain(fileText($0)) }) {
            return "."
        }
        guard let cmdEntries = try? fileManager.contentsOfDirectory(
            atPath: worktreeRoot.appendingPathComponent("cmd").path
        ) else { return nil }
        for name in cmdEntries.sorted() {
            let subdir = "cmd/\(name)"
            var isDirectory: ObjCBool = false
            guard fileManager.fileExists(atPath: worktreeRoot.appendingPathComponent(subdir).path, isDirectory: &isDirectory),
                  isDirectory.boolValue,
                  let files = try? fileManager.contentsOfDirectory(atPath: worktreeRoot.appendingPathComponent(subdir).path)
            else { continue }
            if files.contains(where: { $0.hasSuffix(".go") && goFileDeclaresPackageMain(fileText("\(subdir)/\($0)")) }) {
                return "./\(subdir)"
            }
        }
        return nil
    }

    /// Strips `//` and `/* */` comments from JSONC, respecting string
    /// literals so a URL like `"http://example.com"` isn't mistaken for one,
    /// then drops trailing commas so `JSONSerialization` accepts the result.
    private static func parseJSONC(_ text: String) -> [String: Any]? {
        var stripped = ""
        stripped.reserveCapacity(text.count)
        var inString = false
        var isEscaped = false
        var index = text.startIndex
        while index < text.endIndex {
            let char = text[index]
            if inString {
                stripped.append(char)
                if isEscaped {
                    isEscaped = false
                } else if char == "\\" {
                    isEscaped = true
                } else if char == "\"" {
                    inString = false
                }
                index = text.index(after: index)
                continue
            }
            if char == "\"" {
                inString = true
                stripped.append(char)
                index = text.index(after: index)
                continue
            }
            if char == "/", text.index(after: index) < text.endIndex {
                let next = text.index(after: index)
                if text[next] == "/" {
                    while index < text.endIndex, text[index] != "\n" { index = text.index(after: index) }
                    continue
                }
                if text[next] == "*" {
                    index = text.index(after: next)
                    while index < text.endIndex {
                        let isCloseStar = text[index] == "*" && text.index(after: index) < text.endIndex
                            && text[text.index(after: index)] == "/"
                        index = text.index(after: index)
                        if isCloseStar {
                            index = text.index(after: index)
                            break
                        }
                    }
                    continue
                }
            }
            stripped.append(char)
            index = text.index(after: index)
        }
        let withoutTrailingCommas = stripped.replacingOccurrences(
            of: #",(\s*[}\]])"#, with: "$1", options: .regularExpression
        )
        guard let data = withoutTrailingCommas.data(using: .utf8) else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }

    /// Everything before an unquoted `#`. Shared by pubspec.yaml (YAML) and
    /// mix.exs (Elixir), whose comment syntax happens to match.
    private static func stripLineComment(_ line: some StringProtocol) -> String {
        guard let hashIndex = line.firstIndex(of: "#") else { return String(line) }
        let before = line[line.startIndex..<hashIndex]
        guard before.filter({ $0 == "\"" }).count.isMultiple(of: 2) else { return String(line) }
        return String(before)
    }

    /// A minimal `key: value` YAML mapping line: leading indentation width,
    /// the key, and the trimmed value (nil when the line only opens a nested
    /// block, as a bare `flutter:` does).
    private static func yamlMappingLine(_ line: some StringProtocol) -> (indent: Int, key: String, value: String?)? {
        let indent = line.prefix { $0 == " " }.count
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard let colonIndex = trimmed.firstIndex(of: ":") else { return nil }
        let key = trimmed[trimmed.startIndex..<colonIndex].trimmingCharacters(in: .whitespaces)
        guard !key.isEmpty else { return nil }
        let value = trimmed[trimmed.index(after: colonIndex)...].trimmingCharacters(in: .whitespaces)
        return (indent, key, value.isEmpty ? nil : value)
    }

    /// Strips a matching pair of surrounding quotes from a YAML scalar, so
    /// `sdk: "flutter"` and `sdk: 'flutter'` compare equal to `sdk: flutter`.
    private static func unquoteYAMLScalar(_ value: String) -> String {
        guard value.count >= 2, let first = value.first, let last = value.last,
              first == last, first == "\"" || first == "'"
        else { return value }
        return String(value.dropFirst().dropLast())
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
