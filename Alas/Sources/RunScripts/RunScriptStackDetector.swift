import Foundation

struct RunScriptStackDetection: Identifiable, Equatable, Sendable {
    let stack: RunScriptStack
    let context: RunScriptStackContext

    var id: RunScriptStack { stack }
}

struct GoToolchainEnvironment: Equatable, Sendable {
    var minorVersion: Int?
    var operatingSystem = Self.hostOperatingSystem
    var architecture = Self.hostArchitecture
    var architectureFeatures: Set<String>
    var buildTags: Set<String> = []
    var cgoEnabled = false

    static var hostOperatingSystem: String {
        "darwin"
    }

    static var hostArchitecture: String {
        #if arch(arm64)
        "arm64"
        #elseif arch(x86_64)
        "amd64"
        #else
        ""
        #endif
    }
}

/// Creation-time stack detection from marker files at the worktree root.
/// Reads one directory listing plus, when present, a few small manifests.
/// Results follow `RunScriptStack.allCases` order so the picker is stable.
enum RunScriptStackDetector {
    // swiftlint:disable:next function_body_length cyclomatic_complexity
    static func detect(
        worktreeRoot: URL,
        fileManager: FileManager = .default,
        goToolchainEnvironment: (URL) -> GoToolchainEnvironment? = currentGoToolchainEnvironment
    ) -> [RunScriptStackDetection] {
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
        let bundleHasRSpec = rubyBundleDeclaresAnyGem(
            named: ["rspec", "rspec-rails"],
            rootEntries: names,
            worktreeRoot: worktreeRoot,
            fileManager: fileManager
        )
        let hasSpec = isDirectory("spec") && bundleHasRSpec
        let hasRubocop = has(".rubocop.yml") && rubyBundleDeclaresGem(
            named: "rubocop",
            rootEntries: names,
            worktreeRoot: worktreeRoot,
            fileManager: fileManager
        )

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
                guard (has("pyproject.toml") || hasRequirements), !hasDjangoManage else { continue }
                let pyproject = contents("pyproject.toml") ?? ""
                let dependencyGroups = pythonRunner == .uv ? uvDefaultDependencyGroups(pyproject) : []
                add(stack, .init(
                    pythonRunner: pythonRunner,
                    hasRequirementsFile: hasRequirements,
                    hasPyprojectFile: has("pyproject.toml"),
                    hasPytest: pyprojectDeclaresPythonTool(
                        pyproject,
                        tool: "pytest",
                        includeOptionalDependencies: false,
                        dependencyGroups: dependencyGroups
                    ),
                    hasRuff: pyprojectDeclaresPythonTool(
                        pyproject,
                        tool: "ruff",
                        includeOptionalDependencies: false,
                        dependencyGroups: dependencyGroups
                    )
                ))
            case .django:
                guard hasDjangoManage else { continue }
                add(stack, .init(
                    pythonRunner: pythonRunner,
                    hasRequirementsFile: hasRequirements,
                    hasPyprojectFile: has("pyproject.toml")
                ))
            case .gradle:
                guard has("gradlew", "build.gradle", "build.gradle.kts", "settings.gradle", "settings.gradle.kts") else { continue }
                let buildFiles = ["build.gradle", "build.gradle.kts"]
                    .compactMap { contents($0) }
                add(stack, .init(hasWrapper: entries.contains("gradlew"), gradleTasks: gradleDeclaredTasks(buildFiles.joined(separator: "\n"))))
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
                let buildTarget = dotnetRootBuildTarget(rootEntries: names)
                add(stack, .init(
                    dotnetRunProject: dotnetExecutableProjectPath(rootEntries: names, worktreeRoot: worktreeRoot, fileManager: fileManager),
                    dotnetBuildTarget: buildTarget.target,
                    dotnetCommandsChecked: buildTarget.isUnambiguous
                ))
            case .go:
                guard has("go.mod") else { continue }
                let toolchainEnvironment = goToolchainEnvironment(worktreeRoot) ?? defaultGoToolchainEnvironment
                add(stack, .init(goRunTarget: goRunnableTarget(
                    rootEntries: names,
                    worktreeRoot: worktreeRoot,
                    fileManager: fileManager,
                    toolchainEnvironment: toolchainEnvironment
                )))
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
                add(stack, .init(
                    hasSpecDirectory: hasSpec,
                    hasRakeTestTask: gemfileDeclaresGem(contents("Gemfile") ?? "", gem: "rake")
                        && rakefileDeclaresTask(contents("Rakefile") ?? contents("rakefile") ?? "", task: "test"),
                    hasRubocopConfig: hasRubocop
                ))
            case .laravel:
                guard hasArtisan else { continue }
                add(stack)
            case .php:
                guard has("composer.json"), !hasArtisan else { continue }
                let composer = composerInfo(contents("composer.json") ?? "")
                let phpUnitBinaryPath = "\(composer.binDirectory)/phpunit"
                add(stack, .init(
                    hasPHPUnit: composer.declaresPHPUnit || isRegularFile(phpUnitBinaryPath),
                    phpUnitBinaryPath: phpUnitBinaryPath
                ))
            case .swiftPackage:
                guard has("Package.swift") else { continue }
                let manifest = contents("Package.swift") ?? ""
                add(stack, .init(
                    hasRunnableTarget: swiftPackageHasUnambiguousExecutable(manifest),
                    hasSwiftTestTarget: swiftPackageHasTestTarget(manifest)
                ))
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
                guard let buildZig = contents("build.zig") else { continue }
                add(stack, .init(zigBuildSteps: zigBuildSteps(buildZig)))
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
            guard let dependencies = yamlMappingLine(stripLineComment(rawLine)), dependencies.key == "dependencies" else { continue }
            if let value = dependencies.value {
                // Fully flow-style dependencies map:
                // `dependencies: { flutter: { sdk: flutter } }`.
                let flowValue = yamlFlowValue(startingWith: value, continuingWith: lines.dropFirst(index + 1))
                return flowValue.range(
                    of: #"flutter\s*:\s*\{\s*sdk\s*:\s*['"]?flutter['"]?\s*\}"#,
                    options: .regularExpression
                ) != nil
            }
            // Block form: find a nested `flutter:` dependency, then scan its
            // nested lines for `sdk: flutter`, skipping blank lines and
            // comments.
            for candidateIndex in lines.indices.dropFirst(index + 1) {
                let candidate = lines[candidateIndex]
                let stripped = stripLineComment(candidate)
                if stripped.trimmingCharacters(in: .whitespaces).isEmpty { continue }
                guard let dependency = yamlMappingLine(stripped), dependency.indent > dependencies.indent else { break }
                guard dependency.key == "flutter" else { continue }
                if let value = dependency.value {
                    return value.range(of: #"sdk:\s*['"]?flutter['"]?\b"#, options: .regularExpression) != nil
                }
                for nested in lines.indices.dropFirst(candidateIndex + 1).map({ lines[$0] }) {
                    let nestedStripped = stripLineComment(nested)
                    if nestedStripped.trimmingCharacters(in: .whitespaces).isEmpty { continue }
                    guard let child = yamlMappingLine(nestedStripped), child.indent > dependency.indent else { break }
                    if child.key == "sdk", let value = child.value, unquoteYAMLScalar(value.trimmingCharacters(in: .whitespaces)) == "flutter" {
                        return true
                    }
                }
            }
            return false
        }
        return false
    }

    /// A `{:phoenix, ...}` dependency atom in mix.exs's deps list. A bare
    /// substring check on ":phoenix" also matches unrelated packages that
    /// share the prefix, like `:phoenix_pubsub` or `:phoenix_live_view`, and
    /// would fire on a dependency left commented out.
    private static func mixDeclaresPhoenixDependency(_ mix: String) -> Bool {
        guard let dependencyText = mixDependencyListBody(mix) else { return false }
        let strippedComments = dependencyText.components(separatedBy: .newlines).map(stripLineComment).joined(separator: "\n")
        let stripped = stripElixirStringLiterals(strippedComments)
        // Anchor to the actual dependency-tuple shape `{:phoenix, ...}` rather
        // than any occurrence of the atom: a bare ":phoenix" also matches
        // inside an unrelated string literal, e.g. a package description.
        return stripped.range(of: #"\{\s*:phoenix\s*,"#, options: .regularExpression) != nil
    }

    private static func mixDependencyListBody(_ mix: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: #"(?ms)^\s*defp?\s+deps\s+do\s*(.*?)(?=^\s*end\b)"#) else { return nil }
        let range = NSRange(mix.startIndex..., in: mix)
        guard let match = regex.firstMatch(in: mix, range: range),
              let bodyRange = Range(match.range(at: 1), in: mix)
        else { return nil }
        return String(mix[bodyRange])
    }

    /// Whether a Go source file declares `package main`, the marker that
    /// distinguishes a runnable command from a library package.
    private static func goFileDeclaresPackageMain(_ contents: String?) -> Bool {
        guard let contents else { return false }
        let stripped = stripGoCommentsAndStrings(contents)
        guard let regex = try? NSRegularExpression(pattern: #"(?m)^\s*package\s+([A-Za-z_][A-Za-z0-9_]*)\b"#) else { return false }
        let range = NSRange(stripped.startIndex..., in: stripped)
        guard let match = regex.firstMatch(in: stripped, range: range),
              let packageRange = Range(match.range(at: 1), in: stripped)
        else { return false }
        guard stripped[packageRange] == "main" else { return false }
        return stripped.range(of: #"(?m)^\s*func\s+main\s*\(\s*\)"#, options: .regularExpression) != nil
    }

    private static func stripGoCommentsAndStrings(_ text: String) -> String {
        var stripped = ""
        stripped.reserveCapacity(text.count)
        var inLineComment = false
        var inBlockComment = false
        var inInterpretedString = false
        var inRawString = false
        var isEscaped = false
        var index = text.startIndex
        while index < text.endIndex {
            let char = text[index]
            let next = text.index(after: index)
            let nextChar = next < text.endIndex ? text[next] : nil

            if inLineComment {
                if char == "\n" {
                    inLineComment = false
                    stripped.append(char)
                } else {
                    stripped.append(" ")
                }
                index = next
                continue
            }
            if inBlockComment {
                if char == "\n" {
                    stripped.append(char)
                } else {
                    stripped.append(" ")
                }
                if char == "*", nextChar == "/" {
                    stripped.append(" ")
                    index = text.index(after: next)
                    inBlockComment = false
                } else {
                    index = next
                }
                continue
            }
            if inInterpretedString {
                stripped.append(char == "\n" ? "\n" : " ")
                if isEscaped {
                    isEscaped = false
                } else if char == "\\" {
                    isEscaped = true
                } else if char == "\"" {
                    inInterpretedString = false
                }
                index = next
                continue
            }
            if inRawString {
                stripped.append(char == "\n" ? "\n" : " ")
                if char == "`" {
                    inRawString = false
                }
                index = next
                continue
            }

            if char == "/", nextChar == "/" {
                stripped.append(" ")
                stripped.append(" ")
                index = text.index(after: next)
                inLineComment = true
                continue
            }
            if char == "/", nextChar == "*" {
                stripped.append(" ")
                stripped.append(" ")
                index = text.index(after: next)
                inBlockComment = true
                continue
            }
            if char == "\"" {
                stripped.append(" ")
                inInterpretedString = true
                index = next
                continue
            }
            if char == "`" {
                stripped.append(" ")
                inRawString = true
                index = next
                continue
            }
            stripped.append(char)
            index = next
        }
        return stripped
    }

    /// The path argument for `go run` that actually contains `package main`:
    /// "." for a root-level main package, or "./cmd/<name>" for the first
    /// command found under the cmd/ convention (Go's `run` compiles and runs
    /// exactly the named main package — a `cmd/` subpackage does not make
    /// the module root itself runnable). Nil when neither is confirmed.
    private static func goRunnableTarget(
        rootEntries: [String],
        worktreeRoot: URL,
        fileManager: FileManager,
        toolchainEnvironment: GoToolchainEnvironment
    ) -> String? {
        func fileText(_ relativePath: String) -> String? {
            guard let data = fileManager.contents(atPath: worktreeRoot.appendingPathComponent(relativePath).path) else { return nil }
            return String(decoding: data, as: UTF8.self)
        }
        if rootEntries.contains(where: {
            $0.hasSuffix(".go") && goSourceIsRunnableOnCurrentHost(
                named: $0,
                contents: fileText($0),
                toolchainEnvironment: toolchainEnvironment
            )
        }) {
            return "."
        }
        guard let cmdEntries = try? fileManager.contentsOfDirectory(
            atPath: worktreeRoot.appendingPathComponent("cmd").path
        ) else { return nil }
        var commandTargets: [String] = []
        for name in cmdEntries.sorted() {
            let subdir = "cmd/\(name)"
            var isDirectory: ObjCBool = false
            guard fileManager.fileExists(atPath: worktreeRoot.appendingPathComponent(subdir).path, isDirectory: &isDirectory),
                  isDirectory.boolValue,
                  let files = try? fileManager.contentsOfDirectory(atPath: worktreeRoot.appendingPathComponent(subdir).path)
            else { continue }
            if files.contains(where: {
                $0.hasSuffix(".go") && goSourceIsRunnableOnCurrentHost(
                    named: $0,
                    contents: fileText("\(subdir)/\($0)"),
                    toolchainEnvironment: toolchainEnvironment
                )
            }) {
                commandTargets.append("./\(subdir)")
            }
        }
        return commandTargets.count == 1 ? commandTargets[0] : nil
    }

    /// Whether `cargo run` has exactly one binary to pick, or an explicit
    /// `default-run` to resolve the ambiguity. Cargo refuses to guess when a
    /// package declares more than one bin target and none is designated.
    private static func cargoHasUnambiguousBinary(cargoToml: String, hasRootMain: Bool, binTargetPaths: Set<String>) -> Bool {
        let structuralToml = stripTomlMultilineStrings(cargoToml)
        var binaries: [String: Bool] = [:]
        func addBinary(name: String?, runnableByDefault: Bool) {
            guard let name, !name.isEmpty else { return }
            binaries[name] = runnableByDefault
        }
        let automaticBinariesEnabled = cargoPackageBool(structuralToml, key: "autobins") ?? true
        if automaticBinariesEnabled {
            if hasRootMain {
                addBinary(name: cargoPackageName(structuralToml), runnableByDefault: true)
            }
            for path in binTargetPaths {
                addBinary(name: cargoBinName(fromPath: path), runnableByDefault: true)
            }
        }

        let defaultFeatures = cargoDefaultFeatures(structuralToml)
        for declaredBin in cargoDeclaredBins(structuralToml) {
            binaries[declaredBin.name] = declaredBin.requiredFeatures.isSubset(of: defaultFeatures)
        }

        guard !binaries.isEmpty else { return false }
        if let defaultRun = cargoPackageString(structuralToml, key: "default-run") {
            return binaries[defaultRun] == true
        }
        return binaries.count == 1 && binaries.values.first == true
    }

    private static func cargoBinName(fromPath path: String) -> String? {
        guard path.hasPrefix("src/bin/") else { return nil }
        let suffix = String(path.dropFirst("src/bin/".count))
        if suffix.hasSuffix(".rs"), !suffix.contains("/") {
            return String(suffix.dropLast(".rs".count))
        }
        if suffix.hasSuffix("/main.rs") {
            return suffix.components(separatedBy: "/").first
        }
        return nil
    }

    private static func stripTomlMultilineStrings(_ text: String) -> String {
        var stripped = ""
        stripped.reserveCapacity(text.count)
        var index = text.startIndex
        while index < text.endIndex {
            if text[index...].hasPrefix("'''") || text[index...].hasPrefix("\"\"\"") {
                let delimiter = String(text[index...].prefix(3))
                for _ in 0..<3 { stripped.append(" ") }
                index = text.index(index, offsetBy: 3)
                while index < text.endIndex {
                    if text[index...].hasPrefix(delimiter) {
                        for _ in 0..<3 { stripped.append(" ") }
                        index = text.index(index, offsetBy: 3)
                        break
                    }
                    stripped.append(text[index] == "\n" ? "\n" : " ")
                    index = text.index(after: index)
                }
                continue
            }
            stripped.append(text[index])
            index = text.index(after: index)
        }
        return stripped
    }

    private static func stripZigMultilineStrings(_ text: String) -> String {
        text.components(separatedBy: .newlines)
            .map { line in
                line.trimmingCharacters(in: .whitespaces).hasPrefix("\\\\")
                    ? String(repeating: " ", count: line.count)
                    : line
            }
            .joined(separator: "\n")
    }

    private static func zigBuildSteps(_ buildZig: String) -> Set<String> {
        guard let regex = try? NSRegularExpression(pattern: #"\.step\s*\(\s*\"([^\"]+)\""#) else { return [] }
        let stripped = stripZigMultilineStrings(stripCStyleComments(buildZig))
        let stringRanges = cStringLiteralRanges(stripped)
        let range = NSRange(stripped.startIndex..., in: stripped)
        return Set(regex.matches(in: stripped, range: range).compactMap { match in
            guard !stringRanges.contains(where: { NSLocationInRange(match.range.location, $0) }) else { return nil }
            return Range(match.range(at: 1), in: stripped).map { String(stripped[$0]) }
        })
    }

    private static func gradleDeclaredTasks(_ gradleBuild: String) -> Set<String> {
        let stripped = stripCStyleComments(gradleBuild)
        let stringRanges = gradleStringLiteralRanges(stripped)
        let patterns = [
            #"tasks\.(?:register|create|named)\s*\(\s*["']([^"']+)["']"#,
            #"\btask\s*\(\s*["']([^"']+)["']"#,
            #"(?m)^\s*task\s+([A-Za-z_][A-Za-z0-9_-]*)\b"#,
        ]
        var tasks = Set(patterns.flatMap { pattern -> [String] in
            guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
            let range = NSRange(stripped.startIndex..., in: stripped)
            return regex.matches(in: stripped, range: range).compactMap { match in
                guard !stringRanges.contains(where: { NSLocationInRange(match.range.location, $0) }) else { return nil }
                return Range(match.range(at: 1), in: stripped).map { String(stripped[$0]) }
            }
        })
        let pluginIDs = gradlePluginIDs(stripped)
        if !pluginIDs.isDisjoint(with: ["java", "java-library", "application", "groovy"]) {
            tasks.formUnion(["assemble", "test", "check", "clean"])
        }
        return tasks
    }

    private static func gradlePluginIDs(_ gradleBuild: String) -> Set<String> {
        let patterns = [
            #"\bid\s+["']([^"']+)["']"#,
            #"\bid\s*\(\s*["']([^"']+)["']\s*\)"#,
            #"\bapply\s+plugin:\s*["']([^"']+)["']"#,
        ]
        let stringRanges = gradleStringLiteralRanges(gradleBuild)
        var pluginIDs = Set(patterns.flatMap { pattern -> [String] in
            guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
            let range = NSRange(gradleBuild.startIndex..., in: gradleBuild)
            return regex.matches(in: gradleBuild, range: range).compactMap { match in
                guard !stringRanges.contains(where: { NSLocationInRange(match.range.location, $0) }) else { return nil }
                return Range(match.range(at: 1), in: gradleBuild).map { String(gradleBuild[$0]) }
            }
        })
        pluginIDs.formUnion(gradleKotlinDSLPluginAccessors(gradleBuild))
        return pluginIDs
    }

    private static func gradleKotlinDSLPluginAccessors(_ gradleBuild: String) -> Set<String> {
        guard let blockRegex = try? NSRegularExpression(pattern: #"(?ms)\bplugins\s*\{(.*?)\}"#),
              let accessorRegex = try? NSRegularExpression(pattern: #"(?m)^\s*`?(java|java-library|application|groovy)`?\s*$"#)
        else { return [] }
        let fullRange = NSRange(gradleBuild.startIndex..., in: gradleBuild)
        let stringRanges = gradleStringLiteralRanges(gradleBuild)
        return Set(blockRegex.matches(in: gradleBuild, range: fullRange).flatMap { block -> [String] in
            guard !stringRanges.contains(where: { NSLocationInRange(block.range.location, $0) }) else { return [] }
            guard let blockRange = Range(block.range(at: 1), in: gradleBuild) else { return [] }
            let body = String(gradleBuild[blockRange])
            let bodyRange = NSRange(body.startIndex..., in: body)
            return accessorRegex.matches(in: body, range: bodyRange).compactMap { match in
                Range(match.range(at: 1), in: body).map { String(body[$0]) }
            }
        })
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

    private static func cargoDeclaredBins(_ cargoToml: String) -> [(name: String, path: String?, requiredFeatures: Set<String>)] {
        guard let blockRegex = try? NSRegularExpression(
            pattern: #"(?ms)^\s*\[\[bin\]\]\s*(.*?)(?=^\s*\[\[bin\]\]|\z)"#
        ), let nameRegex = try? NSRegularExpression(pattern: #"(?m)^\s*name\s*=\s*["']([^"']+)["']"#),
           let pathRegex = try? NSRegularExpression(pattern: #"(?m)^\s*path\s*=\s*["']([^"']+)["']"#),
           let requiredFeaturesRegex = try? NSRegularExpression(pattern: #"(?m)^\s*required-features\s*=\s*\[([^\]]*)\]"#),
           let quotedValueRegex = try? NSRegularExpression(pattern: #"["']([^"']+)["']"#)
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
            let requiredFeatures = requiredFeaturesRegex.firstMatch(in: text, range: range).flatMap { match -> Set<String>? in
                guard let featuresRange = Range(match.range(at: 1), in: text) else { return nil }
                let features = String(text[featuresRange])
                let featuresNSRange = NSRange(features.startIndex..., in: features)
                return Set(quotedValueRegex.matches(in: features, range: featuresNSRange).compactMap { feature in
                    Range(feature.range(at: 1), in: features).map { String(features[$0]) }
                })
            } ?? []
            return (
                String(text[nameRange]), path,
                requiredFeatures
            )
        }
    }

    private static func cargoPackageName(_ cargoToml: String) -> String? {
        cargoPackageString(cargoToml, key: "name")
    }

    private static func cargoPackageString(_ cargoToml: String, key: String) -> String? {
        let escapedKey = NSRegularExpression.escapedPattern(for: key)
        guard let regex = try? NSRegularExpression(
            pattern: #"(?ms)^\s*\[package\]\s*(.*?)(?=^\s*\[|\z)"#
        ), let valueRegex = try? NSRegularExpression(pattern: #"(?m)^\s*"# + escapedKey + #"\s*=\s*["']([^"']+)["']"#)
        else { return nil }
        let fullRange = NSRange(cargoToml.startIndex..., in: cargoToml)
        guard let packageMatch = regex.firstMatch(in: cargoToml, range: fullRange),
              let packageRange = Range(packageMatch.range(at: 1), in: cargoToml)
        else { return nil }
        let package = String(cargoToml[packageRange])
        let packageNSRange = NSRange(package.startIndex..., in: package)
        guard let valueMatch = valueRegex.firstMatch(in: package, range: packageNSRange),
              let valueRange = Range(valueMatch.range(at: 1), in: package)
        else { return nil }
        return String(package[valueRange])
    }

    private static func cargoPackageBool(_ cargoToml: String, key: String) -> Bool? {
        let escapedKey = NSRegularExpression.escapedPattern(for: key)
        guard let regex = try? NSRegularExpression(
            pattern: #"(?ms)^\s*\[package\]\s*(.*?)(?=^\s*\[|\z)"#
        ), let valueRegex = try? NSRegularExpression(pattern: #"(?m)^\s*"# + escapedKey + #"\s*=\s*(true|false)\b"#)
        else { return nil }
        let fullRange = NSRange(cargoToml.startIndex..., in: cargoToml)
        guard let packageMatch = regex.firstMatch(in: cargoToml, range: fullRange),
              let packageRange = Range(packageMatch.range(at: 1), in: cargoToml)
        else { return nil }
        let package = String(cargoToml[packageRange])
        let packageNSRange = NSRange(package.startIndex..., in: package)
        guard let valueMatch = valueRegex.firstMatch(in: package, range: packageNSRange),
              let valueRange = Range(valueMatch.range(at: 1), in: package)
        else { return nil }
        return package[valueRange] == "true"
    }

    private static func cargoDefaultFeatures(_ cargoToml: String) -> Set<String> {
        guard let featuresSectionRegex = try? NSRegularExpression(pattern: #"(?ms)^\s*\[features\]\s*(.*?)(?=^\s*\[|\z)"#),
              let featureRegex = try? NSRegularExpression(pattern: #"(?m)^\s*([A-Za-z0-9_-]+)\s*=\s*\[([^\]]*)\]"#),
              let quotedValueRegex = try? NSRegularExpression(pattern: #"["']([^"']+)["']"#)
        else { return [] }
        let fullRange = NSRange(cargoToml.startIndex..., in: cargoToml)
        guard let sectionMatch = featuresSectionRegex.firstMatch(in: cargoToml, range: fullRange),
              let sectionRange = Range(sectionMatch.range(at: 1), in: cargoToml)
        else { return [] }
        let section = String(cargoToml[sectionRange])
        let sectionNSRange = NSRange(section.startIndex..., in: section)
        let featureMap = Dictionary(uniqueKeysWithValues: featureRegex.matches(in: section, range: sectionNSRange).compactMap { match -> (String, [String])? in
            guard let nameRange = Range(match.range(at: 1), in: section),
                  let valuesRange = Range(match.range(at: 2), in: section)
            else { return nil }
            let values = String(section[valuesRange])
            let valuesNSRange = NSRange(values.startIndex..., in: values)
            let features = quotedValueRegex.matches(in: values, range: valuesNSRange).compactMap { value -> String? in
                guard let valueRange = Range(value.range(at: 1), in: values) else { return nil }
                let feature = String(values[valueRange])
                guard !feature.hasPrefix("dep:") else { return nil }
                return feature.components(separatedBy: "/").first
            }
            return (String(section[nameRange]), features)
        })
        var enabled: Set<String> = []
        func visit(_ feature: String) {
            guard enabled.insert(feature).inserted else { return }
            for dependency in featureMap[feature] ?? [] {
                visit(dependency)
            }
        }
        for feature in featureMap["default"] ?? [] {
            visit(feature)
        }
        return enabled
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
        let solutionNames = rootEntries.filter { $0.hasSuffix(".sln") }.sorted()
        if !solutionNames.isEmpty {
            candidates = Array(Set(solutionNames.flatMap { dotnetProjectPaths(fromSolution: fileText($0) ?? "") }))
        } else {
            candidates = rootEntries.filter { $0.hasSuffix(".csproj") || $0.hasSuffix(".fsproj") }
        }
        let executableProjects = candidates.sorted().filter { path in
            guard let text = fileText(path) else { return false }
            return dotnetProjectIsExecutable(text)
        }
        return executableProjects.count == 1 ? executableProjects[0] : nil
    }

    private static func dotnetRootBuildTarget(rootEntries: [String]) -> (target: String?, isUnambiguous: Bool) {
        let solutions = rootEntries.filter { $0.hasSuffix(".sln") }.sorted()
        if solutions.count == 1 { return (solutions[0], true) }
        if solutions.count > 1 { return (nil, false) }

        let projects = rootEntries.filter { $0.hasSuffix(".csproj") || $0.hasSuffix(".fsproj") }.sorted()
        if projects.count == 1 { return (projects[0], true) }
        if projects.count > 1 { return (nil, false) }
        return (nil, true)
    }

    private static func dotnetProjectIsExecutable(_ project: String) -> Bool {
        if project.range(of: #"<OutputType>\s*(Exe|WinExe)\s*</OutputType>"#, options: [.regularExpression, .caseInsensitive]) != nil {
            return true
        }
        return project.range(of: #"<Project\b[^>]*\bSdk\s*=\s*["']Microsoft\.NET\.Sdk\.Web["']"#, options: [.regularExpression, .caseInsensitive]) != nil
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
        let uncommented = swiftPackageActiveManifest(manifest)
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

    private static func swiftPackageHasTestTarget(_ manifest: String) -> Bool {
        let uncommented = swiftPackageActiveManifest(manifest)
        return !swiftTestTargetNames(in: uncommented).isEmpty
    }

    private static func swiftPackageActiveManifest(_ manifest: String) -> String {
        // A commented-out declaration must not count — Package.swift is Swift
        // source, so comments and conditional compilation apply the same as
        // anywhere else.
        let languageVersion = swiftToolsVersion(in: manifest) ?? currentSwiftLanguageVersion
        return stripInactiveSwiftConditionalBranches(
            stripCStyleComments(manifest),
            swiftLanguageVersion: languageVersion
        )
    }

    private static func swiftExecutableProducts(in manifest: String) -> [(name: String, targets: Set<String>)] {
        guard let regex = try? NSRegularExpression(
            pattern: #"(?s)\.executable\s*\(\s*name:\s*"([^"]+)"(.*?)(?=\)\s*[,;\]])"#
        ), let targetsRegex = try? NSRegularExpression(pattern: #"targets:\s*\[([^\]]*)\]"#),
           let targetNameRegex = try? NSRegularExpression(pattern: #""([^"]+)""#)
        else { return [] }
        let fullRange = NSRange(manifest.startIndex..., in: manifest)
        let stringRanges = swiftStringLiteralRanges(manifest)
        return regex.matches(in: manifest, range: fullRange).compactMap { match in
            guard !stringRanges.contains(where: { NSLocationInRange(match.range.location, $0) }) else { return nil }
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

    private static func swiftTestTargetNames(in manifest: String) -> Set<String> {
        swiftDeclarationNames(matching: #"\.testTarget\s*\(\s*name:\s*"([^"]+)""#, in: manifest)
    }

    private static func swiftLegacyExecutableTargetNames(in manifest: String) -> Set<String> {
        swiftDeclarationNames(matching: #"\.target\s*\(\s*name:\s*"([^"]+)".*?type:\s*\.executable\b"#, in: manifest)
    }

    private static func swiftDeclarationNames(matching pattern: String, in manifest: String) -> Set<String> {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.dotMatchesLineSeparators]) else { return [] }
        let fullRange = NSRange(manifest.startIndex..., in: manifest)
        let stringRanges = swiftStringLiteralRanges(manifest)
        return Set(regex.matches(in: manifest, range: fullRange).compactMap { match in
            guard !stringRanges.contains(where: { NSLocationInRange(match.range.location, $0) }) else { return nil }
            return Range(match.range(at: 1), in: manifest).map { String(manifest[$0]) }
        })
    }

    private static func swiftStringLiteralRanges(_ text: String) -> [NSRange] {
        var ranges: [NSRange] = []
        var index = text.startIndex
        while index < text.endIndex {
            guard let opener = swiftStringLiteralOpener(at: index, in: text) else {
                index = text.index(after: index)
                continue
            }
            let start = index
            index = opener.contentStart
            if opener.hashCount > 0 || opener.quoteCount == 3 {
                while index < text.endIndex {
                    if swiftStringDelimiterMatches(at: index, in: text, quoteCount: opener.quoteCount, hashCount: opener.hashCount) {
                        index = text.index(index, offsetBy: opener.quoteCount + opener.hashCount)
                        ranges.append(NSRange(start..<index, in: text))
                        break
                    }
                    index = text.index(after: index)
                }
                if index >= text.endIndex {
                    ranges.append(NSRange(start..<text.endIndex, in: text))
                }
                continue
            }
            if opener.quoteCount == 1 {
                var isEscaped = false
                while index < text.endIndex {
                    let char = text[index]
                    index = text.index(after: index)
                    if isEscaped {
                        isEscaped = false
                    } else if char == "\\" {
                        isEscaped = true
                    } else if char == "\"" {
                        break
                    }
                }
                ranges.append(NSRange(start..<index, in: text))
                continue
            }
        }
        return ranges
    }

    private static func swiftStringLiteralOpener(at index: String.Index, in text: String) -> (hashCount: Int, quoteCount: Int, contentStart: String.Index)? {
        var hashCount = 0
        var quoteIndex = index
        while quoteIndex < text.endIndex, text[quoteIndex] == "#" {
            hashCount += 1
            quoteIndex = text.index(after: quoteIndex)
        }
        guard quoteIndex < text.endIndex, text[quoteIndex] == "\"" else { return nil }
        let quoteCount = text[quoteIndex...].hasPrefix("\"\"\"") ? 3 : 1
        let contentStart = text.index(quoteIndex, offsetBy: quoteCount)
        return (hashCount, quoteCount, contentStart)
    }

    private static func swiftStringDelimiterMatches(
        at index: String.Index,
        in text: String,
        quoteCount: Int,
        hashCount: Int
    ) -> Bool {
        guard text.distance(from: index, to: text.endIndex) >= quoteCount + hashCount else { return false }
        var cursor = index
        for _ in 0..<quoteCount {
            guard text[cursor] == "\"" else { return false }
            cursor = text.index(after: cursor)
        }
        for _ in 0..<hashCount {
            guard text[cursor] == "#" else { return false }
            cursor = text.index(after: cursor)
        }
        return true
    }

    private static func swiftToolsVersion(in manifest: String) -> (major: Int, minor: Int)? {
        guard let regex = try? NSRegularExpression(pattern: #"(?m)^\s*//\s*swift-tools-version:\s*([0-9]+)(?:\.([0-9]+))?"#) else { return nil }
        let range = NSRange(manifest.startIndex..., in: manifest)
        guard let match = regex.firstMatch(in: manifest, range: range),
              let majorRange = Range(match.range(at: 1), in: manifest)
        else { return nil }
        let minor: Int
        if match.range(at: 2).location != NSNotFound,
           let minorRange = Range(match.range(at: 2), in: manifest)
        {
            minor = Int(manifest[minorRange]) ?? 0
        } else {
            minor = 0
        }
        return (Int(manifest[majorRange]) ?? 0, minor)
    }

    private static func stripInactiveSwiftConditionalBranches(_ swift: String, swiftLanguageVersion: (major: Int, minor: Int)) -> String {
        struct Frame {
            let parentActive: Bool
            var active: Bool
            var priorBranchesDefinitelyFalse: Bool
        }
        var output: [String] = []
        var stack: [Frame] = []
        func isActive() -> Bool { stack.last?.active ?? true }
        for line in swift.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if let conditionText = swiftConditionalDirectiveArgument(trimmed, keyword: "#if") {
                let parent = isActive()
                let condition = swiftConditionIsActive(conditionText, swiftLanguageVersion: swiftLanguageVersion)
                stack.append(.init(
                    parentActive: parent,
                    active: parent && condition == true,
                    priorBranchesDefinitelyFalse: condition == false
                ))
                continue
            }
            if let conditionText = swiftConditionalDirectiveArgument(trimmed, keyword: "#elseif") {
                guard !stack.isEmpty else { continue }
                let condition = swiftConditionIsActive(conditionText, swiftLanguageVersion: swiftLanguageVersion)
                var frame = stack.removeLast()
                frame.active = frame.parentActive && frame.priorBranchesDefinitelyFalse && condition == true
                frame.priorBranchesDefinitelyFalse = frame.priorBranchesDefinitelyFalse && condition == false
                stack.append(frame)
                continue
            }
            if trimmed == "#else" {
                guard !stack.isEmpty else { continue }
                var frame = stack.removeLast()
                frame.active = frame.parentActive && frame.priorBranchesDefinitelyFalse
                frame.priorBranchesDefinitelyFalse = false
                stack.append(frame)
                continue
            }
            if trimmed == "#endif" {
                _ = stack.popLast()
                continue
            }
            if isActive() {
                output.append(line)
            }
        }
        return output.joined(separator: "\n")
    }

    private static func swiftConditionIsActive(_ condition: String, swiftLanguageVersion: (major: Int, minor: Int)) -> Bool? {
        let trimmed = stripBalancedOuterParentheses(condition.trimmingCharacters(in: .whitespaces))
        let orParts = splitSwiftCondition(trimmed, by: "||")
        if orParts.count > 1 {
            let values = orParts.map { swiftConditionIsActive($0, swiftLanguageVersion: swiftLanguageVersion) }
            if values.contains(true) { return true }
            if values.contains(nil) { return nil }
            return false
        }
        let andParts = splitSwiftCondition(trimmed, by: "&&")
        if andParts.count > 1 {
            let values = andParts.map { swiftConditionIsActive($0, swiftLanguageVersion: swiftLanguageVersion) }
            if values.contains(false) { return false }
            if values.contains(nil) { return nil }
            return true
        }
        if trimmed.hasPrefix("!") {
            return swiftConditionIsActive(String(trimmed.dropFirst()), swiftLanguageVersion: swiftLanguageVersion).map(!)
        }
        if trimmed == "true" { return true }
        if trimmed == "false" { return false }
        if let osName = swiftOSConditionName(trimmed) {
            return osName == "macOS" || osName == "Darwin"
        }
        if let architecture = swiftArchitectureConditionName(trimmed) {
            return architecture == currentSwiftArchitecture
        }
        if let condition = swiftVersionCondition(trimmed, function: "swift") {
            return swiftVersion(swiftLanguageVersion, satisfies: condition)
        }
        if swiftVersionCondition(trimmed, function: "compiler") != nil { return nil }
        if swiftImportConditionName(trimmed) != nil { return nil }
        // Unknown manifest conditions may depend on SwiftPM settings. Leave
        // generated `swift run` unchecked unless we can prove the branch is
        // active the same way SwiftPM would.
        return nil
    }

    private static func swiftConditionalDirectiveArgument(_ line: String, keyword: String) -> String? {
        guard line.hasPrefix(keyword) else { return nil }
        let rest = line.dropFirst(keyword.count)
        guard let first = rest.first, first.isWhitespace || first == "(" else { return nil }
        return String(rest).trimmingCharacters(in: .whitespaces)
    }

    private static func splitSwiftCondition(_ condition: String, by separator: String) -> [String] {
        var parts: [String] = []
        var depth = 0
        var start = condition.startIndex
        var index = condition.startIndex
        while index < condition.endIndex {
            if condition[index] == "(" {
                depth += 1
                index = condition.index(after: index)
                continue
            }
            if condition[index] == ")" {
                depth = max(0, depth - 1)
                index = condition.index(after: index)
                continue
            }
            if depth == 0, condition[index...].hasPrefix(separator) {
                parts.append(String(condition[start..<index]))
                index = condition.index(index, offsetBy: separator.count)
                start = index
                continue
            }
            index = condition.index(after: index)
        }
        parts.append(String(condition[start...]))
        return parts
    }

    private static func stripBalancedOuterParentheses(_ condition: String) -> String {
        var trimmed = condition.trimmingCharacters(in: .whitespaces)
        while trimmed.first == "(", trimmed.last == ")" {
            var depth = 0
            var wrapsWholeCondition = true
            for index in trimmed.indices {
                if trimmed[index] == "(" { depth += 1 }
                if trimmed[index] == ")" { depth -= 1 }
                if depth == 0, index != trimmed.index(before: trimmed.endIndex) {
                    wrapsWholeCondition = false
                    break
                }
            }
            guard wrapsWholeCondition else { break }
            trimmed = String(trimmed.dropFirst().dropLast()).trimmingCharacters(in: .whitespaces)
        }
        return trimmed
    }

    private static func swiftOSConditionName(_ condition: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: #"^os\(\s*([A-Za-z0-9_]+)\s*\)$"#) else { return nil }
        let range = NSRange(condition.startIndex..., in: condition)
        guard let match = regex.firstMatch(in: condition, range: range),
              let nameRange = Range(match.range(at: 1), in: condition)
        else { return nil }
        return String(condition[nameRange])
    }

    private static func swiftArchitectureConditionName(_ condition: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: #"^arch\(\s*([A-Za-z0-9_]+)\s*\)$"#) else { return nil }
        let range = NSRange(condition.startIndex..., in: condition)
        guard let match = regex.firstMatch(in: condition, range: range),
              let nameRange = Range(match.range(at: 1), in: condition)
        else { return nil }
        return String(condition[nameRange])
    }

    private static func swiftImportConditionName(_ condition: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: #"^canImport\(\s*([A-Za-z_][A-Za-z0-9_]*)\s*\)$"#) else { return nil }
        let range = NSRange(condition.startIndex..., in: condition)
        guard let match = regex.firstMatch(in: condition, range: range),
              let nameRange = Range(match.range(at: 1), in: condition)
        else { return nil }
        return String(condition[nameRange])
    }

    private static func swiftVersionCondition(_ condition: String, function: String) -> (operatorText: String, version: (major: Int, minor: Int))? {
        let escapedFunction = NSRegularExpression.escapedPattern(for: function)
        guard let regex = try? NSRegularExpression(
            pattern: #"^"# + escapedFunction + #"\(\s*(>=|>|<=|<)\s*([0-9]+)(?:\.([0-9]+))?\s*\)$"#
        ) else { return nil }
        let range = NSRange(condition.startIndex..., in: condition)
        guard let match = regex.firstMatch(in: condition, range: range),
              let operatorRange = Range(match.range(at: 1), in: condition),
              let majorRange = Range(match.range(at: 2), in: condition)
        else { return nil }
        let minor: Int
        if match.range(at: 3).location != NSNotFound,
           let minorRange = Range(match.range(at: 3), in: condition)
        {
            minor = Int(condition[minorRange]) ?? 0
        } else {
            minor = 0
        }
        return (
            String(condition[operatorRange]),
            (Int(condition[majorRange]) ?? 0, minor)
        )
    }

    private static func swiftVersion(_ current: (major: Int, minor: Int), satisfies condition: (operatorText: String, version: (major: Int, minor: Int))) -> Bool {
        let comparison = current.major == condition.version.major
            ? current.minor - condition.version.minor
            : current.major - condition.version.major
        switch condition.operatorText {
        case ">=": return comparison >= 0
        case ">": return comparison > 0
        case "<=": return comparison <= 0
        case "<": return comparison < 0
        default: return false
        }
    }

    private static var currentSwiftArchitecture: String {
#if arch(arm64)
        "arm64"
#elseif arch(x86_64)
        "x86_64"
#else
        ""
#endif
    }

    private static var currentSwiftLanguageVersion: (major: Int, minor: Int) {
#if swift(>=6.0)
        (6, 0)
#elseif swift(>=5.10)
        (5, 10)
#elseif swift(>=5.9)
        (5, 9)
#else
        (5, 0)
#endif
    }

    private static func goSourceIsRunnableOnCurrentHost(
        named name: String,
        contents: String?,
        toolchainEnvironment: GoToolchainEnvironment
    ) -> Bool {
        guard name.hasSuffix(".go"), !name.hasSuffix("_test.go"),
              let firstCharacter = name.first, firstCharacter != ".", firstCharacter != "_",
              let contents, goFileDeclaresPackageMain(contents),
              goFilenameSupportsCurrentHost(name, toolchainEnvironment: toolchainEnvironment),
              goBuildConstraintAllowsCurrentHost(contents, toolchainEnvironment: toolchainEnvironment)
        else { return false }
        return true
    }

    private static func goFilenameSupportsCurrentHost(_ name: String, toolchainEnvironment: GoToolchainEnvironment) -> Bool {
        var parts = String(name.dropLast(3)).split(separator: "_")
        guard parts.count > 1 else { return true }
        let operatingSystems = goOperatingSystems
        let architectures = goArchitectures
        if let architecture = parts.last, architectures.contains(architecture) {
            guard architecture == toolchainEnvironment.architecture[...] else { return false }
            parts.removeLast()
            if let operatingSystem = parts.last, operatingSystems.contains(operatingSystem) {
                return operatingSystem == toolchainEnvironment.operatingSystem[...]
            }
            return true
        }
        if let operatingSystem = parts.last, operatingSystems.contains(operatingSystem) {
            return operatingSystem == toolchainEnvironment.operatingSystem[...]
        }
        return true
    }

    private static let goOperatingSystems: Set<Substring> = [
        "aix", "android", "darwin", "dragonfly", "freebsd", "illumos", "ios", "js", "linux", "netbsd", "openbsd",
        "plan9", "solaris", "wasip1", "windows",
    ]

    private static let goArchitectures: Set<Substring> = [
        "386", "amd64", "arm", "arm64", "loong64", "mips", "mips64", "mips64le", "mipsle", "ppc64", "ppc64le",
        "riscv64", "s390x", "wasm",
    ]

    private static func goBuildConstraintAllowsCurrentHost(_ contents: String, toolchainEnvironment: GoToolchainEnvironment) -> Bool {
        let lines = contents.components(separatedBy: .newlines)
        if let directive = lines.map({ $0.trimmingCharacters(in: .whitespaces) }).first(where: { $0.hasPrefix("//go:build ") }) {
            let expression = String(directive.dropFirst("//go:build ".count))
            return goBuildExpressionAllowsCurrentHost(expression, toolchainEnvironment: toolchainEnvironment)
        }
        let legacyDirectives = lines.prefix { line in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            return trimmed.isEmpty || trimmed.hasPrefix("//")
        }
        .map { $0.trimmingCharacters(in: .whitespaces) }
        .filter { $0.hasPrefix("// +build ") }
        guard !legacyDirectives.isEmpty else { return true }
        return legacyDirectives.allSatisfy { directive in
            directive.dropFirst("// +build ".count).split { $0 == " " || $0 == "\t" }.contains { option in
                option.split(separator: ",").allSatisfy { term in
                    if term.hasPrefix("!") {
                        return !goBuildTagIsEnabled(term.dropFirst(), toolchainEnvironment: toolchainEnvironment)
                    }
                    return goBuildTagIsEnabled(term, toolchainEnvironment: toolchainEnvironment)
                }
            }
        }
    }

    private static func goBuildExpressionAllowsCurrentHost(_ expression: String, toolchainEnvironment: GoToolchainEnvironment) -> Bool {
        let tokens = expression.matches(of: /&&|\|\||!|\(|\)|[A-Za-z0-9_.]+/).map(\.output)
        guard tokens.joined() == expression.filter({ !$0.isWhitespace }) else { return false }
        var index = 0
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
            return goBuildTagIsEnabled(tag, toolchainEnvironment: toolchainEnvironment)
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

    private static func goBuildTagIsEnabled(_ tag: Substring, toolchainEnvironment: GoToolchainEnvironment) -> Bool {
        let tag = String(tag)
        return goCoreBuildTags(toolchainEnvironment: toolchainEnvironment).contains(tag)
            || (tag == "cgo" && toolchainEnvironment.cgoEnabled)
            || toolchainEnvironment.architectureFeatures.contains(tag)
            || toolchainEnvironment.buildTags.contains(tag)
            || goReleaseTags(minorVersion: toolchainEnvironment.minorVersion).contains(tag)
    }

    private static func goCoreBuildTags(toolchainEnvironment: GoToolchainEnvironment) -> Set<String> {
        var tags: Set<String> = [
            toolchainEnvironment.operatingSystem,
            toolchainEnvironment.architecture,
            "gc",
        ]
        if goUnixOperatingSystems.contains(toolchainEnvironment.operatingSystem) {
            tags.insert("unix")
        }
        return tags
    }

    private static let goUnixOperatingSystems: Set<String> = [
        "aix", "android", "darwin", "dragonfly", "freebsd", "hurd", "illumos", "ios", "linux", "netbsd", "openbsd",
        "solaris",
    ]

    private static func defaultGoArchitectureFeatureTags(architecture: String = GoToolchainEnvironment.hostArchitecture) -> Set<String> {
        switch architecture {
        case "arm64": ["arm64.v8.0"]
        case "amd64": ["amd64.v1"]
        default: []
        }
    }

    private static var defaultGoToolchainEnvironment: GoToolchainEnvironment {
        .init(minorVersion: 25, architectureFeatures: defaultGoArchitectureFeatureTags(), cgoEnabled: true)
    }

    private static func goReleaseTags(minorVersion: Int?) -> Set<String> {
        let minor = minorVersion ?? 25
        guard minor >= 1 else { return [] }
        return Set((1...minor).map { "go1.\($0)" })
    }

    /// Best-effort, bounded Go environment probe. `go env` is evaluated from
    /// the target worktree so local version-manager/toolchain configuration is
    /// reflected, but the detector must not wait unboundedly while opening the
    /// new-script dialog.
    private static func currentGoToolchainEnvironment(worktreeRoot: URL) -> GoToolchainEnvironment? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["go", "env", "GOVERSION", "GOOS", "GOARCH", "GOAMD64", "GOARM64", "CGO_ENABLED", "GOFLAGS"]
        process.currentDirectoryURL = worktreeRoot
        let output = Pipe()
        process.standardOutput = output
        process.standardError = Pipe()
        do {
            try process.run()
            let deadline = Date().addingTimeInterval(0.25)
            while process.isRunning, Date() < deadline {
                Thread.sleep(forTimeInterval: 0.005)
            }
            if process.isRunning {
                process.terminate()
                return nil
            }
        } catch {
            return nil
        }
        guard process.terminationStatus == 0 else { return nil }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        let lines = String(decoding: data, as: UTF8.self)
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        func line(_ index: Int) -> String? {
            lines.indices.contains(index) ? lines[index] : nil
        }
        let version = line(0) ?? ""
        let operatingSystem = line(1).flatMap { $0.isEmpty ? nil : $0 } ?? GoToolchainEnvironment.hostOperatingSystem
        let architecture = line(2).flatMap { $0.isEmpty ? nil : $0 } ?? GoToolchainEnvironment.hostArchitecture
        let architectureFeatureLevel = architecture == "arm64" ? line(4)
            : architecture == "amd64" ? line(3)
            : nil
        let cgoValue = line(5)
        let goflags = line(6) ?? ""
        return .init(
            minorVersion: goToolchainMinorVersion(from: version),
            operatingSystem: operatingSystem,
            architecture: architecture,
            architectureFeatures: goArchitectureFeatureTags(level: architectureFeatureLevel, architecture: architecture),
            buildTags: goBuildTags(fromGOFLAGS: goflags),
            cgoEnabled: cgoValue != "0"
        )
    }

    private static func goToolchainMinorVersion(from version: String) -> Int? {
        guard let regex = try? NSRegularExpression(pattern: #"^go1\.([0-9]+)"#) else { return nil }
        let range = NSRange(version.startIndex..., in: version)
        guard let match = regex.firstMatch(in: version, range: range),
              let minorRange = Range(match.range(at: 1), in: version)
        else { return nil }
        return Int(version[minorRange])
    }

    static func goArchitectureFeatureTags(level: String?, architecture: String = GoToolchainEnvironment.hostArchitecture) -> Set<String> {
        guard let level else { return defaultGoArchitectureFeatureTags(architecture: architecture) }
        switch architecture {
        case "arm64":
        let baseLevel = level.split(separator: ",", maxSplits: 1).first.map(String.init) ?? level
        guard let regex = try? NSRegularExpression(pattern: #"^v([0-9]+)\.([0-9]+)$"#) else { return defaultGoArchitectureFeatureTags(architecture: architecture) }
        let range = NSRange(baseLevel.startIndex..., in: baseLevel)
        guard let match = regex.firstMatch(in: baseLevel, range: range),
              let majorRange = Range(match.range(at: 1), in: baseLevel),
              let minorRange = Range(match.range(at: 2), in: baseLevel),
              let major = Int(baseLevel[majorRange]),
              let minor = Int(baseLevel[minorRange]),
              major >= 8,
              minor >= 0
        else { return defaultGoArchitectureFeatureTags(architecture: architecture) }
        var tags: Set<String> = []
        if major >= 8 {
            let v8UpperBound = major == 8 ? minor : 9
            tags.formUnion((0...v8UpperBound).map { "arm64.v8.\($0)" })
        }
        if major >= 9 {
            tags.formUnion((0...minor).map { "arm64.v9.\($0)" })
        }
        return tags
        case "amd64":
        let baseLevel = level.split(separator: ",", maxSplits: 1).first.map(String.init) ?? level
        guard baseLevel.hasPrefix("v") else { return defaultGoArchitectureFeatureTags(architecture: architecture) }
        let levelText = baseLevel.dropFirst()
        guard let version = Int(levelText), version >= 1 else { return defaultGoArchitectureFeatureTags(architecture: architecture) }
        return Set((1...version).map { "amd64.v\($0)" })
        default:
        return []
        }
    }

    static func goBuildTags(fromGOFLAGS goflags: String) -> Set<String> {
        var tags: Set<String> = []
        var pendingTagsValue = false
        for token in goflags.split(whereSeparator: \.isWhitespace).map(String.init) {
            if pendingTagsValue {
                tags.formUnion(goBuildTags(fromTagsFlagValue: token))
                pendingTagsValue = false
                continue
            }
            if token == "-tags" {
                pendingTagsValue = true
                continue
            }
            if token.hasPrefix("-tags=") {
                tags.formUnion(goBuildTags(fromTagsFlagValue: String(token.dropFirst("-tags=".count))))
            }
            if let toolModeTag = goToolModeBuildTag(fromGOFLAGSFlag: token) {
                tags.insert(toolModeTag)
            }
        }
        return tags
    }

    private static func goBuildTags(fromTagsFlagValue value: String) -> Set<String> {
        Set(value.split { $0 == "," || $0 == " " || $0 == "\t" }.map(String.init).filter { !$0.isEmpty })
    }

    private static func goToolModeBuildTag(fromGOFLAGSFlag flag: String) -> String? {
        for mode in ["race", "msan", "asan"] {
            if flag == "-\(mode)" {
                return mode
            }
            let assignmentPrefix = "-\(mode)="
            if flag.hasPrefix(assignmentPrefix) {
                let value = String(flag.dropFirst(assignmentPrefix.count))
                return goBooleanFlagValueIsEnabled(value) ? mode : nil
            }
        }
        return nil
    }

    private static func goBooleanFlagValueIsEnabled(_ value: String) -> Bool {
        switch value.lowercased() {
        case "1", "t", "true": true
        default: false
        }
    }

    private static func composerInfo(_ composerJSON: String) -> (declaresPHPUnit: Bool, binDirectory: String) {
        guard let data = composerJSON.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return (false, "vendor/bin") }
        let dependencyKeys = ["require", "require-dev"].flatMap { key -> [String] in
            guard let dependencies = object[key] as? [String: Any] else { return [] }
            return Array(dependencies.keys)
        }
        let config = object["config"] as? [String: Any]
        let binDirectory = (config?["bin-dir"] as? String).map(composerBinDirectory)
        return (dependencyKeys.contains("phpunit/phpunit"), binDirectory?.isEmpty == false ? binDirectory! : "vendor/bin")
    }

    private static func composerBinDirectory(_ configuredValue: String) -> String {
        var path = configuredValue.trimmingCharacters(in: .whitespacesAndNewlines)
        while path.count > 1, path.hasSuffix("/") {
            path.removeLast()
        }
        return path
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
            guard !makeColonStartsAssignmentOperator(in: line, at: colonIndex) else { continue }
            let beforeColon = line[line.startIndex..<colonIndex]
            guard !beforeColon.contains("=") else { continue }
            let names = beforeColon.split(separator: " ").map { $0.trimmingCharacters(in: .whitespaces) }
            if names.contains(target) { return true }
        }
        return false
    }

    private static func makeColonStartsAssignmentOperator(in line: Substring, at colonIndex: Substring.Index) -> Bool {
        let afterColon = line.index(after: colonIndex)
        guard afterColon < line.endIndex else { return false }
        if line[afterColon] == "=" {
            return true
        }
        if line[afterColon] == ":" {
            let afterDoubleColon = line.index(after: afterColon)
            return afterDoubleColon < line.endIndex && line[afterDoubleColon] == "="
        }
        return false
    }

    private static func gemfileDeclaresGem(_ gemfile: String, gem: String) -> Bool {
        let stripped = stripHashComments(gemfile)
        let escapedGem = NSRegularExpression.escapedPattern(for: gem)
        return stripped.range(
            of: #"(?m)^\s*gem\s+["']"# + escapedGem + #"["']"#, options: .regularExpression
        ) != nil
    }

    private static func rubyBundleDeclaresGem(
        named gem: String,
        rootEntries: [String],
        worktreeRoot: URL,
        fileManager: FileManager
    ) -> Bool {
        rubyBundleDeclaresAnyGem(named: [gem], rootEntries: rootEntries, worktreeRoot: worktreeRoot, fileManager: fileManager)
    }

    private static func rubyBundleDeclaresAnyGem(
        named gems: [String],
        rootEntries: [String],
        worktreeRoot: URL,
        fileManager: FileManager
    ) -> Bool {
        func fileContents(_ name: String) -> String {
            let url = worktreeRoot.appendingPathComponent(name)
            guard let data = fileManager.contents(atPath: url.path) else { return "" }
            return String(decoding: data, as: UTF8.self)
        }
        if rootEntries.contains("Gemfile"), gems.contains(where: { gemfileDeclaresGem(fileContents("Gemfile"), gem: $0) }) {
            return true
        }
        return rootEntries.filter { $0.hasSuffix(".gemspec") }.contains { name in
            gems.contains { gemspecDeclaresGem(fileContents(name), gem: $0) }
        }
    }

    private static func gemspecDeclaresGem(_ gemspec: String, gem: String) -> Bool {
        let stripped = stripHashComments(gemspec)
        let escapedGem = NSRegularExpression.escapedPattern(for: gem)
        return stripped.range(
            of: #"\badd_(?:development_)?dependency\s+["']"# + escapedGem + #"["']"#,
            options: .regularExpression
        ) != nil
    }

    private static func rakefileDeclaresTask(_ rakefile: String, task: String) -> Bool {
        let commentless = stripRubyHeredocs(stripHashComments(rakefile))
        let stripped = stripRubyStringLiterals(commentless)
        let escapedTask = NSRegularExpression.escapedPattern(for: task)
        guard let taskRegex = try? NSRegularExpression(
            pattern: #"^\s*task(?:\s+(?::"# + escapedTask + #"\b|["']"# + escapedTask + #"["']|"# + escapedTask + #"\s*:)|\s*\(\s*(?::"# + escapedTask + #"\b|["']"# + escapedTask + #"["']))"#
        ), let stringTaskRegex = try? NSRegularExpression(
            pattern: #"^\s*task\s*\(\s*["']"# + escapedTask + #"["']"#
        ), let parenthesizedTaskSkeletonRegex = try? NSRegularExpression(
            pattern: #"^\s*task\s*\("#
        ), let namespaceRegex = try? NSRegularExpression(pattern: #"^\s*namespace\b.*(?:\bdo\b|\{)\s*$"#),
           let methodRegex = try? NSRegularExpression(pattern: #"^\s*def\b"#)
        else { return false }
        var blockStack: [Bool] = []
        let originalSegments = commentless.components(separatedBy: .newlines).flatMap { $0.components(separatedBy: ";") }
        let strippedSegments = stripped.components(separatedBy: .newlines).flatMap { $0.components(separatedBy: ";") }
        for (originalSegment, segment) in zip(originalSegments, strippedSegments) {
            let trimmed = segment.trimmingCharacters(in: .whitespaces)
            if trimmed == "end" || trimmed == "}" {
                _ = blockStack.popLast()
                continue
            }
            let range = NSRange(segment.startIndex..., in: segment)
            let originalRange = NSRange(originalSegment.startIndex..., in: originalSegment)
            if namespaceRegex.firstMatch(in: segment, range: range) != nil {
                blockStack.append(true)
                continue
            }
            if methodRegex.firstMatch(in: segment, range: range) != nil {
                blockStack.append(true)
                continue
            }
            if !blockStack.contains(true), taskRegex.firstMatch(in: segment, range: range) != nil {
                return true
            }
            if !blockStack.contains(true),
               parenthesizedTaskSkeletonRegex.firstMatch(in: segment, range: range) != nil,
               stringTaskRegex.firstMatch(in: originalSegment, range: originalRange) != nil
            {
                return true
            }
            if rubyBlockOpens(trimmed) {
                blockStack.append(false)
            }
        }
        return false
    }

    private static func stripRubyHeredocs(_ ruby: String) -> String {
        guard let heredocRegex = try? NSRegularExpression(pattern: #"<<[-~]?\s*['"]?([A-Za-z_][A-Za-z0-9_]*)['"]?"#) else { return ruby }
        var output: [String] = []
        var terminator: String?
        for line in ruby.components(separatedBy: .newlines) {
            if let currentTerminator = terminator {
                output.append("")
                if line.trimmingCharacters(in: .whitespaces) == currentTerminator {
                    terminator = nil
                }
                continue
            }
            output.append(line)
            let range = NSRange(line.startIndex..., in: line)
            guard let match = heredocRegex.firstMatch(in: line, range: range),
                  let terminatorRange = Range(match.range(at: 1), in: line)
            else { continue }
            terminator = String(line[terminatorRange])
        }
        return output.joined(separator: "\n")
    }

    private static func stripRubyStringLiterals(_ ruby: String) -> String {
        var stripped = ""
        stripped.reserveCapacity(ruby.count)
        var index = ruby.startIndex
        while index < ruby.endIndex {
            let char = ruby[index]
            guard char == "\"" || char == "'" || char == "`" else {
                stripped.append(char)
                index = ruby.index(after: index)
                continue
            }
            let quote = char
            stripped.append(" ")
            index = ruby.index(after: index)
            var isEscaped = false
            while index < ruby.endIndex {
                let inner = ruby[index]
                stripped.append(inner == "\n" ? "\n" : " ")
                index = ruby.index(after: index)
                if isEscaped {
                    isEscaped = false
                } else if inner == "\\" {
                    isEscaped = true
                } else if inner == quote {
                    break
                }
            }
        }
        return stripped
    }

    private static func rubyBlockOpens(_ trimmedLine: String) -> Bool {
        let blockStarters = ["if", "unless", "case", "begin", "for", "while", "until", "def", "class", "module"]
        if blockStarters.contains(where: { trimmedLine == $0 || trimmedLine.hasPrefix("\($0) ") }) {
            return true
        }
        return trimmedLine.hasSuffix(" do") || trimmedLine.contains(" do |")
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
                    var depth = 1
                    while index < text.endIndex, depth > 0 {
                        let nextIndex = text.index(after: index)
                        if text[index] == "\n" {
                            stripped.append("\n")
                            index = nextIndex
                            continue
                        }
                        if nextIndex < text.endIndex {
                            if text[index] == "/", text[nextIndex] == "*" {
                                depth += 1
                                index = text.index(after: nextIndex)
                                continue
                            }
                            if text[index] == "*", text[nextIndex] == "/" {
                                depth -= 1
                                index = text.index(after: nextIndex)
                                continue
                            }
                        }
                        index = nextIndex
                    }
                    continue
                }
            }
            stripped.append(char)
            index = text.index(after: index)
        }
        return stripped
    }

    private static func cStringLiteralRanges(_ text: String) -> [NSRange] {
        var ranges: [NSRange] = []
        var inString = false
        var isEscaped = false
        var index = text.startIndex
        var stringStart = text.startIndex
        var quoteCharacter: Character = "\""
        while index < text.endIndex {
            let char = text[index]
            if inString {
                if isEscaped {
                    isEscaped = false
                } else if char == "\\" {
                    isEscaped = true
                } else if char == quoteCharacter {
                    inString = false
                    let end = text.index(after: index)
                    ranges.append(NSRange(stringStart..<end, in: text))
                }
                index = text.index(after: index)
                continue
            }
            if char == "\"" || char == "'" {
                inString = true
                stringStart = index
                quoteCharacter = char
                index = text.index(after: index)
                continue
            }
            index = text.index(after: index)
        }
        return ranges
    }

    private static func gradleStringLiteralRanges(_ text: String) -> [NSRange] {
        cStringLiteralRanges(text) + groovySlashyStringLiteralRanges(text)
    }

    private static func groovySlashyStringLiteralRanges(_ text: String) -> [NSRange] {
        var ranges: [NSRange] = []
        var index = text.startIndex
        while index < text.endIndex {
            if text[index...].hasPrefix("$/") {
                let start = index
                index = text.index(index, offsetBy: 2)
                while index < text.endIndex {
                    if text[index...].hasPrefix("/$") {
                        index = text.index(index, offsetBy: 2)
                        ranges.append(NSRange(start..<index, in: text))
                        break
                    }
                    index = text.index(after: index)
                }
                if index >= text.endIndex {
                    ranges.append(NSRange(start..<text.endIndex, in: text))
                }
                continue
            }
            if text[index] == "/",
               slashCanStartGroovyString(at: index, in: text)
            {
                let start = index
                index = text.index(after: index)
                var isEscaped = false
                while index < text.endIndex {
                    let char = text[index]
                    index = text.index(after: index)
                    if isEscaped {
                        isEscaped = false
                    } else if char == "\\" {
                        isEscaped = true
                    } else if char == "/" {
                        ranges.append(NSRange(start..<index, in: text))
                        break
                    }
                }
                if index >= text.endIndex {
                    ranges.append(NSRange(start..<text.endIndex, in: text))
                }
                continue
            }
            index = text.index(after: index)
        }
        return ranges
    }

    private static func slashCanStartGroovyString(at index: String.Index, in text: String) -> Bool {
        let next = text.index(after: index)
        guard next < text.endIndex, text[next] != "/", text[next] != "*" else { return false }
        let prefix = text[..<index].trimmingCharacters(in: .whitespacesAndNewlines)
        guard let previous = prefix.last else { return true }
        return previous == "=" || previous == "(" || previous == "[" || previous == "{" || previous == "," || previous == ":"
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

    private static func stripElixirStringLiterals(_ text: String) -> String {
        var stripped = ""
        stripped.reserveCapacity(text.count)
        var index = text.startIndex
        while index < text.endIndex {
            let char = text[index]
            if char == "\"" {
                stripped.append("\"\"")
                index = text.index(after: index)
                var isEscaped = false
                while index < text.endIndex {
                    let inner = text[index]
                    index = text.index(after: index)
                    if isEscaped {
                        isEscaped = false
                    } else if inner == "\\" {
                        isEscaped = true
                    } else if inner == "\"" {
                        break
                    }
                }
                continue
            }
            if char == "~", text.index(after: index) < text.endIndex {
                let sigil = text[text.index(after: index)]
                if sigil == "s" || sigil == "S" {
                    let delimiterIndex = text.index(index, offsetBy: 2)
                    if delimiterIndex < text.endIndex {
                        let delimiter = text[delimiterIndex]
                        if let closingDelimiter = elixirClosingSigilDelimiter(for: delimiter) {
                            stripped.append("~\(sigil)\(delimiter)\(closingDelimiter)")
                            index = text.index(after: delimiterIndex)
                            var isEscaped = false
                            while index < text.endIndex {
                                let inner = text[index]
                                index = text.index(after: index)
                                if sigil == "s", isEscaped {
                                    isEscaped = false
                                } else if sigil == "s", inner == "\\" {
                                    isEscaped = true
                                } else if inner == closingDelimiter {
                                    break
                                }
                            }
                            continue
                        }
                    }
                }
            }
            stripped.append(char)
            index = text.index(after: index)
        }
        return stripped
    }

    private static func elixirClosingSigilDelimiter(for delimiter: Character) -> Character? {
        switch delimiter {
        case "(": ")"
        case "[": "]"
        case "{": "}"
        case "<": ">"
        case "/", "|", "\"", "'": delimiter
        default: nil
        }
    }

    private static func pyprojectDeclaresPythonTool(
        _ pyproject: String,
        tool: String,
        includeOptionalDependencies: Bool,
        dependencyGroups: Set<String>
    ) -> Bool {
        let stripped = stripHashComments(pyproject)
        let optionalPoetryGroups = poetryOptionalGroups(in: stripped)
        for section in tomlSections(stripped) {
            let table = section.name
            switch table {
            case "project":
                if tomlKeyedDependencyText(section.body, declares: tool, keys: ["dependencies"]) { return true }
            case "build-system":
                continue
            case "dependency-groups":
                guard !dependencyGroups.isEmpty else { continue }
                if tomlKeyedDependencyText(section.body, declares: tool, keys: Array(dependencyGroups)) { return true }
            default:
                if table.hasPrefix("project.optional-dependencies") {
                    guard includeOptionalDependencies else { continue }
                    if tomlDependencyText(section.body, declares: tool) { return true }
                    continue
                }
                if table.hasPrefix("tool.poetry.group."), table.hasSuffix(".dependencies") {
                    let group = table
                        .dropFirst("tool.poetry.group.".count)
                        .dropLast(".dependencies".count)
                    guard !optionalPoetryGroups.contains(String(group)) else { continue }
                } else {
                    guard table == "tool.poetry.dev-dependencies" else { continue }
                }
                if tomlDependencyText(section.body, declares: tool) { return true }
            }
        }
        return false
    }

    private static func poetryOptionalGroups(in pyproject: String) -> Set<String> {
        Set(tomlSections(pyproject).compactMap { section in
            guard section.name.hasPrefix("tool.poetry.group."),
                  !section.name.hasSuffix(".dependencies"),
                  section.body.range(of: #"(?m)^\s*optional\s*=\s*true\s*$"#, options: .regularExpression) != nil
            else { return nil }
            return String(section.name.dropFirst("tool.poetry.group.".count))
        })
    }

    private static func uvDefaultDependencyGroups(_ pyproject: String) -> Set<String> {
        let stripped = stripHashComments(pyproject)
        guard let toolUV = tomlSections(stripped).first(where: { $0.name == "tool.uv" }) else { return [] }
        return Set(tomlStringArrayValues(toolUV.body, key: "default-groups"))
    }

    private static func tomlSections(_ toml: String) -> [(name: String, body: String)] {
        let lines = toml.components(separatedBy: .newlines)
        var sections: [(name: String, body: String)] = []
        var currentName = ""
        var currentLines: [String] = []
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("["), trimmed.hasSuffix("]") {
                sections.append((currentName, currentLines.joined(separator: "\n")))
                currentName = trimmed.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
                currentLines = []
            } else {
                currentLines.append(line)
            }
        }
        sections.append((currentName, currentLines.joined(separator: "\n")))
        return sections
    }

    private static func tomlDependencyText(_ text: String, declares tool: String) -> Bool {
        let escapedTool = NSRegularExpression.escapedPattern(for: tool)
        guard let arrayRegex = try? NSRegularExpression(pattern: #"(?ms)=\s*\[(.*?)\]"#),
              let inlineTableRegex = try? NSRegularExpression(pattern: #"(?ms)=\s*\{(.*?)\}"#),
              let quotedDependencyRegex = try? NSRegularExpression(
                  pattern: #"["']"# + escapedTool + #"([<>=~! ;,\[][^"']*)?["']"#
              ),
              let tableDependencyRegex = try? NSRegularExpression(pattern: #"(?m)^\s*["']?"# + escapedTool + #"["']?\s*="#)
        else { return false }
        let range = NSRange(text.startIndex..., in: text)
        if tableDependencyRegex.firstMatch(in: text, range: range) != nil {
            return true
        }
        let arrayMatches = arrayRegex.matches(in: text, range: range)
        if arrayMatches.contains(where: { match in
            guard let bodyRange = Range(match.range(at: 1), in: text) else { return false }
            let body = String(text[bodyRange])
            return quotedDependencyRegex.firstMatch(in: body, range: NSRange(body.startIndex..., in: body)) != nil
        }) {
            return true
        }
        return inlineTableRegex.matches(in: text, range: range).contains { match in
            guard let bodyRange = Range(match.range(at: 1), in: text) else { return false }
            let body = String(text[bodyRange])
            return tableDependencyRegex.firstMatch(in: body, range: NSRange(body.startIndex..., in: body)) != nil
        }
    }

    private static func tomlKeyedDependencyText(_ text: String, declares tool: String, keys: [String]) -> Bool {
        let escapedTool = NSRegularExpression.escapedPattern(for: tool)
        guard let quotedDependencyRegex = try? NSRegularExpression(
            pattern: #"["']"# + escapedTool + #"([<>=~! ;,\[][^"']*)?["']"#
        ) else { return false }
        return keys.contains { key in
            let escapedKey = NSRegularExpression.escapedPattern(for: key)
            guard let arrayRegex = try? NSRegularExpression(pattern: #"(?ms)^\s*"# + escapedKey + #"\s*=\s*\[(.*?)\]"#)
            else { return false }
            let range = NSRange(text.startIndex..., in: text)
            return arrayRegex.matches(in: text, range: range).contains { match in
                guard let bodyRange = Range(match.range(at: 1), in: text) else { return false }
                let body = String(text[bodyRange])
                return quotedDependencyRegex.firstMatch(in: body, range: NSRange(body.startIndex..., in: body)) != nil
            }
        }
    }

    private static func tomlStringArrayValues(_ text: String, key: String) -> [String] {
        let escapedKey = NSRegularExpression.escapedPattern(for: key)
        guard let arrayRegex = try? NSRegularExpression(pattern: #"(?ms)^\s*"# + escapedKey + #"\s*=\s*\[(.*?)\]"#),
              let stringRegex = try? NSRegularExpression(pattern: #"["']([^"']+)["']"#)
        else { return [] }
        let range = NSRange(text.startIndex..., in: text)
        return arrayRegex.matches(in: text, range: range).flatMap { match -> [String] in
            guard let bodyRange = Range(match.range(at: 1), in: text) else { return [] }
            let body = String(text[bodyRange])
            let fullBodyRange = NSRange(body.startIndex..., in: body)
            return stringRegex.matches(in: body, range: fullBodyRange).compactMap { stringMatch in
                guard let valueRange = Range(stringMatch.range(at: 1), in: body) else { return nil }
                return String(body[valueRange])
            }
        }
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

    private static func yamlFlowValue(startingWith firstLineValue: String, continuingWith remainingLines: ArraySlice<String>) -> String {
        var value = stripLineComment(firstLineValue)
        var depth = yamlFlowBraceDepth(value)
        guard depth > 0 else { return value }
        for rawLine in remainingLines {
            let line = stripLineComment(rawLine)
            value += "\n\(line)"
            depth += yamlFlowBraceDepth(line)
            if depth <= 0 { break }
        }
        return value
    }

    private static func yamlFlowBraceDepth(_ text: String) -> Int {
        var depth = 0
        for character in text {
            if character == "{" { depth += 1 }
            if character == "}" { depth -= 1 }
        }
        return depth
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
