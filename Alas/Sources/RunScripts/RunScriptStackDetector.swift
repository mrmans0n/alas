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
                let pyproject = stripHashComments(contents("pyproject.toml") ?? "")
                add(stack, .init(
                    pythonRunner: pythonRunner,
                    hasRequirementsFile: hasRequirements,
                    hasPytest: pyproject.contains("pytest"),
                    hasRuff: pyproject.contains("ruff")
                ))
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
                add(stack, .init(dotnetRunProject: dotnetExecutableProjectPath(rootEntries: names, worktreeRoot: worktreeRoot, fileManager: fileManager)))
            case .go:
                guard has("go.mod") else { continue }
                add(stack, .init(goRunTarget: goRunnableTarget(rootEntries: names, worktreeRoot: worktreeRoot, fileManager: fileManager)))
            case .cargo:
                guard has("Cargo.toml") else { continue }
                add(stack, .init(hasRunnableTarget: cargoHasUnambiguousBinary(
                    cargoToml: contents("Cargo.toml") ?? "",
                    hasRootMain: isRegularFile("src/main.rs"),
                    binTargetPaths: cargoBinTargetPaths(worktreeRoot: worktreeRoot, fileManager: fileManager)
                )))
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
                add(stack, .init(hasRunnableTarget: swiftPackageHasUnambiguousExecutable(contents("Package.swift") ?? "")))
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
                guard let makefileName = ["Makefile", "makefile", "GNUmakefile"].first(where: { entries.contains($0) }),
                      !has("CMakeLists.txt")
                else { continue }
                let makefile = contents(makefileName) ?? ""
                add(stack, .init(
                    hasMakeTestTarget: makefileDeclaresTarget(makefile, target: "test"),
                    hasMakeCleanTarget: makefileDeclaresTarget(makefile, target: "clean")
                ))
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
        if rootEntries.contains(where: {
            $0.hasSuffix(".go") && goSourceIsRunnableOnCurrentHost(named: $0, contents: fileText($0))
        }) {
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
            if files.contains(where: {
                $0.hasSuffix(".go") && goSourceIsRunnableOnCurrentHost(named: $0, contents: fileText("\(subdir)/\($0)"))
            }) {
                return "./\(subdir)"
            }
        }
        return nil
    }

    /// Whether `cargo run` has exactly one binary to pick, or an explicit
    /// `default-run` to resolve the ambiguity. Cargo refuses to guess when a
    /// package declares more than one bin target and none is designated.
    private static func cargoHasUnambiguousBinary(cargoToml: String, hasRootMain: Bool, binTargetPaths: Set<String>) -> Bool {
        var binaryPaths = Set<String>()
        if hasRootMain { binaryPaths.insert("src/main.rs") }
        binaryPaths.formUnion(binTargetPaths)

        for declaredBin in cargoDeclaredBins(cargoToml) {
            if let path = declaredBin.path {
                binaryPaths.insert(path)
            } else if binTargetPaths.contains("src/bin/\(declaredBin.name).rs") {
                binaryPaths.insert("src/bin/\(declaredBin.name).rs")
            } else if binTargetPaths.contains("src/bin/\(declaredBin.name)/main.rs") {
                binaryPaths.insert("src/bin/\(declaredBin.name)/main.rs")
            } else if hasRootMain, cargoPackageName(cargoToml) == declaredBin.name {
                binaryPaths.insert("src/main.rs")
            } else {
                // A declared target without an inferred source path still is
                // a distinct binary target from Cargo's perspective.
                binaryPaths.insert("declared:\(declaredBin.name)")
            }
        }

        guard !binaryPaths.isEmpty else { return false }
        guard binaryPaths.count == 1 else {
            return cargoToml.range(of: #"(?m)^\s*default-run\s*="#, options: .regularExpression) != nil
        }
        return true
    }

    private static func cargoBinTargetPaths(worktreeRoot: URL, fileManager: FileManager) -> Set<String> {
        let binRoot = worktreeRoot.appendingPathComponent("src/bin")
        guard let entries = try? fileManager.contentsOfDirectory(atPath: binRoot.path) else { return [] }
        var paths = Set<String>()
        for entry in entries {
            if entry.hasSuffix(".rs") {
                paths.insert("src/bin/\(entry)")
                continue
            }
            var isDirectory: ObjCBool = false
            let mainPath = binRoot.appendingPathComponent(entry).appendingPathComponent("main.rs")
            if fileManager.fileExists(atPath: mainPath.deletingLastPathComponent().path, isDirectory: &isDirectory),
               isDirectory.boolValue,
               fileManager.fileExists(atPath: mainPath.path)
            {
                paths.insert("src/bin/\(entry)/main.rs")
            }
        }
        return paths
    }

    private static func cargoDeclaredBins(_ cargoToml: String) -> [(name: String, path: String?)] {
        guard let blockRegex = try? NSRegularExpression(
            pattern: #"(?ms)^\s*\[\[bin\]\]\s*(.*?)(?=^\s*\[\[bin\]\]|\z)"#
        ), let nameRegex = try? NSRegularExpression(pattern: #"(?m)^\s*name\s*=\s*\"([^\"]+)\""#),
           let pathRegex = try? NSRegularExpression(pattern: #"(?m)^\s*path\s*=\s*\"([^\"]+)\""#)
        else { return [] }
        let fullRange = NSRange(cargoToml.startIndex..., in: cargoToml)
        return blockRegex.matches(in: cargoToml, range: fullRange).compactMap { block in
            guard let blockRange = Range(block.range(at: 1), in: cargoToml) else { return nil }
            let text = String(cargoToml[blockRange])
            let range = NSRange(text.startIndex..., in: text)
            guard let nameMatch = nameRegex.firstMatch(in: text, range: range),
                  let nameRange = Range(nameMatch.range(at: 1), in: text)
            else { return nil }
            let path = pathRegex.firstMatch(in: text, range: range).flatMap { match in
                Range(match.range(at: 1), in: text).map { String(text[$0]) }
            }
            return (String(text[nameRange]), path)
        }
    }

    private static func cargoPackageName(_ cargoToml: String) -> String? {
        guard let regex = try? NSRegularExpression(
            pattern: #"(?ms)^\s*\[package\]\s*(.*?)(?=^\s*\[|\z)"#
        ), let nameRegex = try? NSRegularExpression(pattern: #"(?m)^\s*name\s*=\s*\"([^\"]+)\""#)
        else { return nil }
        let fullRange = NSRange(cargoToml.startIndex..., in: cargoToml)
        guard let packageMatch = regex.firstMatch(in: cargoToml, range: fullRange),
              let packageRange = Range(packageMatch.range(at: 1), in: cargoToml)
        else { return nil }
        let package = String(cargoToml[packageRange])
        let packageNSRange = NSRange(package.startIndex..., in: package)
        guard let nameMatch = nameRegex.firstMatch(in: package, range: packageNSRange),
              let nameRange = Range(nameMatch.range(at: 1), in: package)
        else { return nil }
        return String(package[nameRange])
    }

    /// The path (relative to the worktree root) of a project file declaring
    /// `<OutputType>Exe</OutputType>` (or `WinExe`), so `dotnet run --project
    /// <path>` has something to run. Bare `dotnet run` only resolves a
    /// project from the current directory, so a root `.sln` whose actual
    /// projects live in subdirectories needs this to find one at all.
    private static func dotnetExecutableProjectPath(
        rootEntries: [String], worktreeRoot: URL, fileManager: FileManager
    ) -> String? {
        // Unlike the shared `contents(_:)` closure, project paths here can be
        // nested (a solution's projects usually live in subdirectories), so
        // read directly rather than gating on the root-level entries set.
        func fileText(_ relativePath: String) -> String? {
            guard let data = fileManager.contents(atPath: worktreeRoot.appendingPathComponent(relativePath).path) else { return nil }
            return String(decoding: data, as: UTF8.self)
        }
        // Read candidate project paths from solution metadata rather than
        // walking the whole worktree — on a large monorepo a recursive scan
        // runs synchronously on the main actor and would be visibly slow.
        let candidates: [String]
        if let solutionName = rootEntries.first(where: { $0.hasSuffix(".sln") }) {
            candidates = dotnetProjectPaths(fromSolution: fileText(solutionName) ?? "")
        } else {
            candidates = rootEntries.filter { $0.hasSuffix(".csproj") || $0.hasSuffix(".fsproj") }
        }
        let executableProjects = candidates.sorted().filter { path in
            guard let text = fileText(path),
                  text.range(of: #"<OutputType>\s*(Exe|WinExe)\s*</OutputType>"#, options: [.regularExpression, .caseInsensitive]) != nil
            else { return false }
            return true
        }
        return executableProjects.count == 1 ? executableProjects[0] : nil
    }

    /// Extracts each referenced project's relative path from a .sln file's
    /// `Project("{type}") = "Name", "path\to\Project.csproj", "{guid}"`
    /// lines, normalizing the Windows-style backslashes .sln files use.
    private static func dotnetProjectPaths(fromSolution solutionText: String) -> [String] {
        guard let regex = try? NSRegularExpression(
            pattern: #"^Project\("[^"]*"\)\s*=\s*"[^"]*",\s*"([^"]+)""#, options: [.anchorsMatchLines]
        ) else { return [] }
        let range = NSRange(solutionText.startIndex..., in: solutionText)
        return regex.matches(in: solutionText, range: range).compactMap { match in
            guard let pathRange = Range(match.range(at: 1), in: solutionText) else { return nil }
            let path = solutionText[pathRange].replacingOccurrences(of: "\\", with: "/")
            return (path.hasSuffix(".csproj") || path.hasSuffix(".fsproj")) ? path : nil
        }
    }

    /// Whether Package.swift declares exactly one executable, the only case
    /// bare `swift run` (no product name) can resolve on its own.
    private static func swiftPackageHasUnambiguousExecutable(_ manifest: String) -> Bool {
        // A commented-out `.executableTarget` must not count — Package.swift
        // is Swift source, so `//`/`/* */` comments are as valid here as
        // anywhere else.
        let uncommented = stripCStyleComments(manifest)
        let executableProducts = swiftExecutableProducts(in: uncommented)
        let executableTargetNames = swiftExecutableTargetNames(in: uncommented)
        let legacyTargetNames = swiftLegacyExecutableTargetNames(in: uncommented)
        if !executableProducts.isEmpty {
            let productTargets = Set(executableProducts.flatMap(\.targets))
            let extraExecutableTargets = executableTargetNames.subtracting(productTargets)
            let extraLegacyTargets = legacyTargetNames.subtracting(productTargets)
            return executableProducts.count + extraExecutableTargets.count + extraLegacyTargets.count == 1
        }
        if !executableTargetNames.isEmpty { return executableTargetNames.count == 1 }
        // Older manifests declare an executable product via `type:
        // .executable` on a plain `.target` without a dedicated
        // .executableTarget entry; a single one is unambiguous the same way.
        return legacyTargetNames.count == 1
    }

    private static func swiftExecutableProducts(in manifest: String) -> [(name: String, targets: Set<String>)] {
        guard let regex = try? NSRegularExpression(
            pattern: #"(?s)\.executable\s*\(\s*name:\s*"([^"]+)"(.*?)(?=\)\s*[,;\]])"#
        ), let targetsRegex = try? NSRegularExpression(pattern: #"targets:\s*\[([^\]]*)\]"#),
           let targetNameRegex = try? NSRegularExpression(pattern: #""([^"]+)""#)
        else { return [] }
        let fullRange = NSRange(manifest.startIndex..., in: manifest)
        return regex.matches(in: manifest, range: fullRange).compactMap { match in
            guard let nameRange = Range(match.range(at: 1), in: manifest),
                  let bodyRange = Range(match.range(at: 2), in: manifest)
            else { return nil }
            let body = String(manifest[bodyRange])
            let bodyNSRange = NSRange(body.startIndex..., in: body)
            let targets = targetsRegex.firstMatch(in: body, range: bodyNSRange).flatMap { targetsMatch -> Set<String>? in
                guard let listRange = Range(targetsMatch.range(at: 1), in: body) else { return nil }
                let list = String(body[listRange])
                let listNSRange = NSRange(list.startIndex..., in: list)
                return Set(targetNameRegex.matches(in: list, range: listNSRange).compactMap { targetMatch in
                    Range(targetMatch.range(at: 1), in: list).map { String(list[$0]) }
                })
            } ?? []
            return (String(manifest[nameRange]), targets)
        }
    }

    private static func swiftExecutableTargetNames(in manifest: String) -> Set<String> {
        swiftDeclarationNames(matching: #"\.executableTarget\s*\(\s*name:\s*"([^"]+)""#, in: manifest)
    }

    private static func swiftLegacyExecutableTargetNames(in manifest: String) -> Set<String> {
        swiftDeclarationNames(matching: #"\.target\s*\(\s*name:\s*"([^"]+)".*?type:\s*\.executable\b"#, in: manifest)
    }

    private static func swiftDeclarationNames(matching pattern: String, in manifest: String) -> Set<String> {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.dotMatchesLineSeparators]) else { return [] }
        let fullRange = NSRange(manifest.startIndex..., in: manifest)
        return Set(regex.matches(in: manifest, range: fullRange).compactMap { match in
            Range(match.range(at: 1), in: manifest).map { String(manifest[$0]) }
        })
    }

    private static func goSourceIsRunnableOnCurrentHost(named name: String, contents: String?) -> Bool {
        guard name.hasSuffix(".go"), !name.hasSuffix("_test.go"),
              let contents, goFileDeclaresPackageMain(contents),
              goFilenameSupportsCurrentHost(name), goBuildConstraintAllowsCurrentHost(contents)
        else { return false }
        return true
    }

    private static func goFilenameSupportsCurrentHost(_ name: String) -> Bool {
        let base = String(name.dropLast(3))
        let suffixes = base.split(separator: "_").dropFirst()
        let operatingSystems: Set<Substring> = ["aix", "android", "darwin", "dragonfly", "freebsd", "illumos", "ios", "js", "linux", "netbsd", "openbsd", "plan9", "solaris", "wasip1", "windows"]
        let architectures: Set<Substring> = ["386", "amd64", "arm", "arm64", "loong64", "mips", "mips64", "mips64le", "mipsle", "ppc64", "ppc64le", "riscv64", "s390x", "wasm"]
        return suffixes.allSatisfy { suffix in
            (!operatingSystems.contains(suffix) || suffix == "darwin")
                && (!architectures.contains(suffix) || suffix == currentGoArchitecture)
        }
    }

    private static var currentGoArchitecture: Substring {
#if arch(arm64)
        "arm64"
#elseif arch(x86_64)
        "amd64"
#else
        ""
#endif
    }

    private static func goBuildConstraintAllowsCurrentHost(_ contents: String) -> Bool {
        guard let directive = contents.components(separatedBy: .newlines).first(where: { $0.hasPrefix("//go:build ") }) else {
            return true
        }
        let expression = String(directive.dropFirst("//go:build ".count))
        let tokens = expression.matches(of: /&&|\|\||!|\(|\)|[A-Za-z0-9_.]+/).map(\.output)
        guard tokens.joined() == expression.filter({ !$0.isWhitespace }) else { return false }
        var index = 0
        let enabledTags: Set<Substring> = ["darwin", "unix", currentGoArchitecture, "cgo"]
        func parsePrimary() -> Bool? {
            guard index < tokens.count else { return nil }
            if tokens[index] == "!" {
                index += 1
                return parsePrimary().map(!)
            }
            if tokens[index] == "(" {
                index += 1
                guard let value = parseOr(), index < tokens.count, tokens[index] == ")" else { return nil }
                index += 1
                return value
            }
            let tag = tokens[index]
            index += 1
            return enabledTags.contains(tag)
        }
        func parseAnd() -> Bool? {
            guard var value = parsePrimary() else { return nil }
            while index < tokens.count, tokens[index] == "&&" {
                index += 1
                guard let right = parsePrimary() else { return nil }
                value = value && right
            }
            return value
        }
        func parseOr() -> Bool? {
            guard var value = parseAnd() else { return nil }
            while index < tokens.count, tokens[index] == "||" {
                index += 1
                guard let right = parseAnd() else { return nil }
                value = value || right
            }
            return value
        }
        guard let result = parseOr(), index == tokens.count else { return false }
        return result
    }

    private static func countOccurrences(of pattern: String, in text: String) -> Int {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return 0 }
        return regex.numberOfMatches(in: text, range: NSRange(text.startIndex..., in: text))
    }

    /// Whether a Makefile declares a rule for `target` — a target line looks
    /// like `name:` or `name: deps`, unindented (an indented line is a
    /// recipe, not a rule) and not a variable assignment.
    private static func makefileDeclaresTarget(_ makefile: String, target: String) -> Bool {
        for rawLine in makefile.components(separatedBy: .newlines) {
            guard !rawLine.hasPrefix("\t"), !rawLine.hasPrefix(" ") else { continue }
            // Drop a "#" comment before parsing, so "# test: disabled" isn't
            // read as a rule for "test".
            let line = rawLine.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false)[0]
            guard let colonIndex = line.firstIndex(of: ":") else { continue }
            let beforeColon = line[line.startIndex..<colonIndex]
            guard !beforeColon.contains("=") else { continue }
            let names = beforeColon.split(separator: " ").map { $0.trimmingCharacters(in: .whitespaces) }
            if names.contains(target) { return true }
        }
        return false
    }

    /// Strips `//` and `/* */` comments, respecting string literals so a URL
    /// like `"http://example.com"` isn't mistaken for one. Shared by JSONC
    /// (deno.jsonc) and Swift source (Package.swift), whose comment syntax
    /// happens to match.
    private static func stripCStyleComments(_ text: String) -> String {
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
        return stripped
    }

    /// Strips comments and drops trailing commas so `JSONSerialization`
    /// accepts a JSONC document like deno.jsonc.
    private static func parseJSONC(_ text: String) -> [String: Any]? {
        let withoutTrailingCommas = stripCStyleComments(text).replacingOccurrences(
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

    private static func stripHashComments(_ text: String) -> String {
        text.components(separatedBy: .newlines).map(stripLineComment).joined(separator: "\n")
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
