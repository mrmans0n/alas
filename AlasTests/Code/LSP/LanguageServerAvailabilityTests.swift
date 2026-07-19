import Foundation
import Testing
@testable import Alas

@Suite("LanguageServerAvailability")
@MainActor
struct LanguageServerAvailabilityTests {
    @Test("disabled entries report disabled")
    func disabled() {
        let entry = config(language: "swift", command: "sourcekit-lsp", enabled: false)
        let availability = LanguageServerAvailability(environment: [:], xcrunFind: { _ in nil }, additionalPathDirectories: [], gatekeeperAssessor: { _ in .allowed })
        #expect(availability.status(for: entry) == .disabled)
    }

    @Test("absolute executable path reports available")
    func absoluteExecutable() throws {
        let dir = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let executable = dir.appendingPathComponent("server")
        let created = FileManager.default.createFile(atPath: executable.path, contents: Data())
        #expect(created)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)

        let entry = config(command: executable.path)
        let availability = LanguageServerAvailability(environment: [:], xcrunFind: { _ in nil }, additionalPathDirectories: [], gatekeeperAssessor: { _ in .allowed })
        #expect(availability.status(for: entry) == .available)
    }

    @Test("bare command resolves against PATH")
    func pathExecutable() throws {
        let dir = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let executable = dir.appendingPathComponent("test-lsp")
        let created = FileManager.default.createFile(atPath: executable.path, contents: Data())
        #expect(created)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)

        let entry = config(command: "test-lsp")
        let availability = LanguageServerAvailability(environment: ["PATH": dir.path], xcrunFind: { _ in nil }, additionalPathDirectories: [], gatekeeperAssessor: { _ in .allowed })
        #expect(availability.status(for: entry) == .available)
    }

    @Test("minimal GUI PATH still checks additional tool directories")
    func additionalToolDirectories() throws {
        let dir = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let executable = dir.appendingPathComponent("rust-analyzer")
        let created = FileManager.default.createFile(atPath: executable.path, contents: Data())
        #expect(created)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)

        let entry = config(language: "rust", command: "rust-analyzer")
        let availability = LanguageServerAvailability(
            environment: ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin"],
            xcrunFind: { _ in nil },
            additionalPathDirectories: ["\(NSHomeDirectory())/.npm-global/bin", dir.path],
            gatekeeperAssessor: { _ in .allowed }
        )

        #expect(availability.status(for: entry) == .available)
        #expect(availability.resolvedCommand(for: entry) == executable.path)
    }

    @Test("gui PATH includes npm-global directory")
    func launchEnvironmentIncludesNpmGlobal() {
        let entry = config(command: "custom-lsp")
        let availability = LanguageServerAvailability(
            environment: ["PATH": "/usr/bin:/bin"],
            xcrunFind: { _ in nil },
            additionalPathDirectories: ["\(NSHomeDirectory())/.npm-global/bin", "/opt/homebrew/bin"],
            gatekeeperAssessor: { _ in .allowed }
        )

        let env = availability.launchEnvironment(for: entry)
        let path = env["PATH"] ?? ""
        #expect(path.contains("/.npm-global/bin"))
        #expect(path.contains("/opt/homebrew/bin"))
    }

    @Test("Swift sourcekit-lsp falls back to xcrun")
    func swiftXcrunFallback() {
        var requestedTool: String?
        let entry = config(language: "swift", command: "sourcekit-lsp")
        let availability = LanguageServerAvailability(environment: ["PATH": ""], xcrunFind: { tool in
            requestedTool = tool
            return "/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/sourcekit-lsp"
        }, additionalPathDirectories: [], gatekeeperAssessor: { _ in .allowed })

        #expect(availability.status(for: entry) == .available)
        #expect(requestedTool == "sourcekit-lsp")
    }

    @Test("xcrun fallback is Swift sourcekit-lsp only")
    func xcrunFallbackIsSwiftOnly() {
        var didCallXcrun = false
        let entry = config(language: "rust", command: "rust-analyzer")
        let availability = LanguageServerAvailability(environment: ["PATH": ""], xcrunFind: { _ in
            didCallXcrun = true
            return "/usr/local/bin/rust-analyzer"
        }, additionalPathDirectories: [], gatekeeperAssessor: { _ in .allowed })

        #expect(availability.status(for: entry) == .notInstalled)
        #expect(didCallXcrun == false)
    }

    @Test("resolvedCommand returns xcrun path for Swift")
    func resolvedCommandXcrun() {
        let entry = config(language: "swift", command: "sourcekit-lsp")
        let xcrunPath = "/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/sourcekit-lsp"
        let availability = LanguageServerAvailability(environment: ["PATH": ""], xcrunFind: { _ in xcrunPath }, additionalPathDirectories: [], gatekeeperAssessor: { _ in .allowed })

        #expect(availability.resolvedCommand(for: entry) == xcrunPath)
    }

    @Test("spawnArguments uses absolute path from xcrun")
    func spawnArgumentsXcrun() {
        let entry = config(language: "swift", command: "sourcekit-lsp", args: ["--flag"])
        let xcrunPath = "/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/sourcekit-lsp"
        let availability = LanguageServerAvailability(environment: ["PATH": ""], xcrunFind: { _ in xcrunPath }, additionalPathDirectories: [], gatekeeperAssessor: { _ in .allowed })
        let spawn = availability.spawnArguments(for: entry)

        #expect(spawn != nil)
        #expect(spawn!.executable == xcrunPath)
        #expect(spawn!.arguments == ["--flag"])
    }

    @Test("xcrun find uses bounded runner and parses successful output")
    nonisolated func xcrunFindUsesBoundedRunner() {
        var observedExecutable: URL?
        var observedArguments: [String] = []
        var observedEnvironment: [String: String] = [:]
        var observedTimeout: TimeInterval?
        let xcrunPath = """
        /Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/sourcekit-lsp
        """
        let runner = SubprocessRunner { executable, arguments, environment, timeout in
            observedExecutable = executable
            observedArguments = arguments
            observedEnvironment = environment
            observedTimeout = timeout
            return SubprocessRunner.Result(exitCode: 0, stdout: xcrunPath, stderr: "")
        }

        let resolved = LanguageServerAvailability.xcrunFind(
            "sourcekit-lsp",
            runner: runner,
            timeout: 1.25
        )

        #expect(resolved == xcrunPath.trimmingCharacters(in: .whitespacesAndNewlines))
        #expect(observedExecutable?.path == "/usr/bin/xcrun")
        #expect(observedArguments == ["--find", "sourcekit-lsp"])
        #expect(observedEnvironment == ProcessInfo.processInfo.environment)
        #expect(observedTimeout == 1.25)
    }

    @Test("xcrun find timeout is treated as missing")
    nonisolated func xcrunFindTimeoutIsMissing() {
        let runner = SubprocessRunner { _, _, _, _ in
            SubprocessRunner.Result(exitCode: nil, stdout: "", stderr: "")
        }

        #expect(LanguageServerAvailability.xcrunFind(
            "sourcekit-lsp",
            runner: runner,
            timeout: 1.25
        ) == nil)
    }

    @Test("spawnArguments uses resolved absolute path from PATH")
    func spawnArgumentsPathCommand() throws {
        let dir = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let executable = dir.appendingPathComponent("test-lsp")
        let created = FileManager.default.createFile(atPath: executable.path, contents: Data())
        #expect(created)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)

        let entry = config(command: "test-lsp", args: ["--verbose"])
        let availability = LanguageServerAvailability(environment: ["PATH": dir.path], xcrunFind: { _ in nil }, additionalPathDirectories: [], gatekeeperAssessor: { _ in .allowed })
        let spawn = availability.spawnArguments(for: entry)

        #expect(spawn != nil)
        #expect(spawn!.executable == executable.path)
        #expect(spawn!.arguments == ["--verbose"])
    }

    @Test("spawnArguments wraps unresolvable bare command with env")
    func spawnArgumentsEnvFallback() {
        let entry = config(command: "missing-lsp", args: ["--flag"])
        let availability = LanguageServerAvailability(environment: ["PATH": ""], xcrunFind: { _ in nil }, additionalPathDirectories: [], gatekeeperAssessor: { _ in .allowed })
        let spawn = availability.spawnArguments(for: entry)

        #expect(spawn == nil)
    }

    @Test("entry.env PATH is merged for resolution")
    func envPathResolution() throws {
        let dir = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let executable = dir.appendingPathComponent("custom-lsp")
        let created = FileManager.default.createFile(atPath: executable.path, contents: Data())
        #expect(created)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)

        let entry = config(command: "custom-lsp", env: ["PATH": dir.path])
        let availability = LanguageServerAvailability(environment: ["PATH": ""], xcrunFind: { _ in nil }, additionalPathDirectories: [], gatekeeperAssessor: { _ in .allowed })
        #expect(availability.status(for: entry) == .available)
    }

    @Test("launch environment uses same augmented PATH as resolution")
    func launchEnvironmentPath() {
        let entry = config(command: "custom-lsp", env: ["PATH": "/custom/bin", "CUSTOM": "1"])
        let availability = LanguageServerAvailability(
            environment: ["PATH": "/usr/bin:/bin", "HOME": "/Users/test"],
            xcrunFind: { _ in nil },
            additionalPathDirectories: ["/opt/homebrew/bin", "/custom/bin"],
            gatekeeperAssessor: { _ in .allowed }
        )

        let env = availability.launchEnvironment(for: entry)

        #expect(env["CUSTOM"] == "1")
        #expect(env["HOME"] == "/Users/test")
        #expect(env["PATH"] == "/custom/bin:/usr/bin:/bin:/opt/homebrew/bin")
    }

    @Test("resolved command + gatekeeper rejected → blockedByGatekeeper(realPath:)")
    func gatekeeperRejected() throws {
        let dir = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let executable = dir.appendingPathComponent("kotlin-lsp")
        #expect(FileManager.default.createFile(atPath: executable.path, contents: Data()))
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)

        let entry = config(language: "kotlin", command: "kotlin-lsp")
        let availability = LanguageServerAvailability(
            environment: ["PATH": dir.path],
            xcrunFind: { _ in nil },
            additionalPathDirectories: [],
            gatekeeperAssessor: { _ in .rejected }
        )

        let status = availability.status(for: entry)
        guard case .blockedByGatekeeper(let realPath) = status else {
            #expect(Bool(false), "Expected .blockedByGatekeeper, got \(status)")
            return
        }
        // realPath should be the executable path with symlinks resolved.
        #expect(realPath == executable.resolvingSymlinksInPath().path)
    }

    @Test("resolved command + gatekeeper allowed → available")
    func gatekeeperAllowed() throws {
        let dir = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let executable = dir.appendingPathComponent("kotlin-lsp")
        #expect(FileManager.default.createFile(atPath: executable.path, contents: Data()))
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)

        let entry = config(language: "kotlin", command: "kotlin-lsp")
        let availability = LanguageServerAvailability(
            environment: ["PATH": dir.path],
            xcrunFind: { _ in nil },
            additionalPathDirectories: [],
            gatekeeperAssessor: { _ in .allowed }
        )

        #expect(availability.status(for: entry) == .available)
    }

    @Test("resolved command + gatekeeper unknown → available (don't hide LSPs on assessor failure)")
    func gatekeeperUnknownIsAvailable() throws {
        let dir = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let executable = dir.appendingPathComponent("kotlin-lsp")
        #expect(FileManager.default.createFile(atPath: executable.path, contents: Data()))
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)

        let entry = config(language: "kotlin", command: "kotlin-lsp")
        let availability = LanguageServerAvailability(
            environment: ["PATH": dir.path],
            xcrunFind: { _ in nil },
            additionalPathDirectories: [],
            gatekeeperAssessor: { _ in .unknown }
        )

        #expect(availability.status(for: entry) == .available)
    }

    @Test("available primary command checks configured gatekeeper helper")
    func helperGatekeeperRejected() throws {
        let dir = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let server = try executable(named: "kotlin-lsp", in: dir)
        let helper = try executable(named: "intellij-server", in: dir)
        var assessed: [String] = []

        let entry = config(language: "kotlin", command: "kotlin-lsp", gatekeeperHelpers: ["intellij-server"])
        let availability = LanguageServerAvailability(
            environment: ["PATH": dir.path],
            xcrunFind: { _ in nil },
            additionalPathDirectories: [],
            gatekeeperAssessor: { path in
                assessed.append(path)
                return path == helper.resolvingSymlinksInPath().path ? .rejected : .allowed
            }
        )

        let status = availability.status(for: entry)

        guard case .blockedByGatekeeper(let realPath) = status else {
            Issue.record("Expected helper block, got \(status)")
            return
        }
        #expect(realPath == helper.resolvingSymlinksInPath().path)
        #expect(assessed == [server.resolvingSymlinksInPath().path, helper.resolvingSymlinksInPath().path])
    }

    @Test("allowed gatekeeper helper keeps server available")
    func helperGatekeeperAllowed() throws {
        let dir = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let server = try executable(named: "kotlin-lsp", in: dir)
        let helper = try executable(named: "intellij-server", in: dir)
        var assessed: [String] = []

        let entry = config(language: "kotlin", command: "kotlin-lsp", gatekeeperHelpers: ["intellij-server"])
        let availability = LanguageServerAvailability(
            environment: ["PATH": dir.path],
            xcrunFind: { _ in nil },
            additionalPathDirectories: [],
            gatekeeperAssessor: { path in
                assessed.append(path)
                return .allowed
            }
        )

        #expect(availability.status(for: entry) == .available)
        #expect(assessed == [server.resolvingSymlinksInPath().path, helper.resolvingSymlinksInPath().path])
    }

    @Test("gatekeeper helper path containing slash is assessed")
    func helperGatekeeperPathIsAssessed() throws {
        let dir = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let helperDir = dir.appendingPathComponent("helpers")
        try FileManager.default.createDirectory(at: helperDir, withIntermediateDirectories: true)
        _ = try executable(named: "kotlin-lsp", in: dir)
        let helper = try executable(named: "intellij-server", in: helperDir)

        let entry = config(language: "kotlin", command: "kotlin-lsp", gatekeeperHelpers: [helper.path])
        let availability = LanguageServerAvailability(
            environment: ["PATH": dir.path],
            xcrunFind: { _ in nil },
            additionalPathDirectories: [],
            gatekeeperAssessor: { path in
                path == helper.resolvingSymlinksInPath().path ? .rejected : .allowed
            }
        )

        let status = availability.status(for: entry)

        guard case .blockedByGatekeeper(let realPath) = status else {
            Issue.record("Expected helper path block, got \(status)")
            return
        }
        #expect(realPath == helper.resolvingSymlinksInPath().path)
    }

    @Test("gatekeeper helper resolves next to symlinked launcher target")
    func helperGatekeeperResolvesNextToSymlinkedLauncherTarget() throws {
        let dir = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let pathDir = dir.appendingPathComponent("path")
        let installDir = dir.appendingPathComponent("kotlin-server")
        let helperDir = installDir.appendingPathComponent("bin")
        try FileManager.default.createDirectory(at: pathDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: helperDir, withIntermediateDirectories: true)

        let launcher = try executable(named: "kotlin-lsp.sh", in: installDir)
        let pathCommand = pathDir.appendingPathComponent("kotlin-lsp")
        try FileManager.default.createSymbolicLink(at: pathCommand, withDestinationURL: launcher)
        let helper = try executable(named: "intellij-server", in: helperDir)

        let entry = config(language: "kotlin", command: "kotlin-lsp", gatekeeperHelpers: ["intellij-server"])
        let availability = LanguageServerAvailability(
            environment: ["PATH": pathDir.path],
            xcrunFind: { _ in nil },
            additionalPathDirectories: [],
            gatekeeperAssessor: { path in
                path == helper.resolvingSymlinksInPath().path ? .rejected : .allowed
            }
        )

        let status = availability.status(for: entry)

        guard case .blockedByGatekeeper(let realPath) = status else {
            Issue.record("Expected helper block, got \(status)")
            return
        }
        #expect(realPath == helper.resolvingSymlinksInPath().path)
    }

    @Test("missing gatekeeper helper does not make server unavailable")
    func missingHelperDoesNotBlockAvailability() throws {
        let dir = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let server = try executable(named: "kotlin-lsp", in: dir)
        var assessed: [String] = []

        let entry = config(language: "kotlin", command: "kotlin-lsp", gatekeeperHelpers: ["intellij-server"])
        let availability = LanguageServerAvailability(
            environment: ["PATH": dir.path],
            xcrunFind: { _ in nil },
            additionalPathDirectories: [],
            gatekeeperAssessor: { path in
                assessed.append(path)
                return .allowed
            }
        )

        #expect(availability.status(for: entry) == .available)
        #expect(assessed == [server.resolvingSymlinksInPath().path])
    }

    @Test("duplicate helper paths are assessed once")
    func duplicateHelperPathsAreAssessedOnce() throws {
        let dir = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let server = try executable(named: "kotlin-lsp", in: dir)
        var assessed: [String] = []

        let entry = config(
            language: "kotlin",
            command: "kotlin-lsp",
            gatekeeperHelpers: ["kotlin-lsp", "kotlin-lsp"]
        )
        let availability = LanguageServerAvailability(
            environment: ["PATH": dir.path],
            xcrunFind: { _ in nil },
            additionalPathDirectories: [],
            gatekeeperAssessor: { path in
                assessed.append(path)
                return .allowed
            }
        )

        #expect(availability.status(for: entry) == .available)
        #expect(assessed == [server.resolvingSymlinksInPath().path])
    }

    @Test("auto-remediation clears quarantined helper before reporting available")
    func remediationClearsBlockedHelper() async throws {
        let dir = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        _ = try executable(named: "kotlin-lsp", in: dir)
        let helper = try executable(named: "intellij-server", in: dir)
        let helperPath = helper.resolvingSymlinksInPath().path
        var blocked = Set([helperPath])
        var remediated: [String] = []

        let entry = config(language: "kotlin", command: "kotlin-lsp", gatekeeperHelpers: ["intellij-server"])
        let availability = LanguageServerAvailability(
            environment: ["PATH": dir.path],
            xcrunFind: { _ in nil },
            additionalPathDirectories: [],
            gatekeeperAssessor: { path in blocked.contains(path) ? .rejected : .allowed },
            gatekeeperRemediator: { path, _ in
                remediated.append(path)
                blocked.remove(path)
                return .allowed
            }
        )

        #expect(await availability.statusRemediatingGatekeeper(for: entry) == .available)
        #expect(remediated == [helperPath])
    }

    @Test("auto-remediation clears helper install root when marker is configured")
    func remediationClearsHelperInstallRoot() async throws {
        let dir = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let installDir = dir.appendingPathComponent("kotlin-server")
        let helperDir = installDir.appendingPathComponent("bin")
        try FileManager.default.createDirectory(at: helperDir, withIntermediateDirectories: true)
        #expect(FileManager.default.createFile(
            atPath: installDir.appendingPathComponent("product-info.json").path,
            contents: Data()
        ))
        _ = try executable(named: "kotlin-lsp.sh", in: installDir)
        let helper = try executable(named: "intellij-server", in: helperDir)
        let helperPath = helper.resolvingSymlinksInPath().path
        var blocked = Set([helperPath])
        var remediated: [String] = []

        let entry = config(
            language: "kotlin",
            command: installDir.appendingPathComponent("kotlin-lsp.sh").path,
            gatekeeperHelpers: ["intellij-server"],
            gatekeeperRemediationRootMarkers: ["product-info.json"]
        )
        let availability = LanguageServerAvailability(
            xcrunFind: { _ in nil },
            additionalPathDirectories: [],
            gatekeeperAssessor: { path in blocked.contains(path) ? .rejected : .allowed },
            gatekeeperRemediator: { _, remediationTarget in
                remediated.append(remediationTarget)
                blocked.remove(helperPath)
                return .allowed
            }
        )

        #expect(await availability.statusRemediatingGatekeeper(for: entry) == .available)
        #expect(remediated == [installDir.path])
    }

    @Test("auto-remediation clears install root when binaries were already allowed")
    func remediationClearsInstallRootWhenBinariesAlreadyAllowed() async throws {
        let dir = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let installDir = dir.appendingPathComponent("kotlin-server")
        let helperDir = installDir.appendingPathComponent("bin")
        try FileManager.default.createDirectory(at: helperDir, withIntermediateDirectories: true)
        #expect(FileManager.default.createFile(
            atPath: installDir.appendingPathComponent("product-info.json").path,
            contents: Data()
        ))
        _ = try executable(named: "kotlin-lsp.sh", in: installDir)
        _ = try executable(named: "intellij-server", in: helperDir)
        var blocked = Set([installDir.path])
        var remediated: [String] = []

        let entry = config(
            language: "kotlin",
            command: installDir.appendingPathComponent("kotlin-lsp.sh").path,
            gatekeeperHelpers: ["intellij-server"],
            gatekeeperRemediationRootMarkers: ["product-info.json"]
        )
        let availability = LanguageServerAvailability(
            xcrunFind: { _ in nil },
            additionalPathDirectories: [],
            gatekeeperAssessor: { path in blocked.contains(path) ? .rejected : .allowed },
            gatekeeperRemediator: { _, remediationTarget in
                remediated.append(remediationTarget)
                blocked.remove(remediationTarget)
                return .allowed
            }
        )

        #expect(await availability.statusRemediatingGatekeeper(for: entry) == .available)
        #expect(remediated == [installDir.path])
    }

    @Test("auto-remediation failure returns blocked helper path")
    func remediationFailureReturnsBlockedHelper() async throws {
        let dir = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        _ = try executable(named: "kotlin-lsp", in: dir)
        let helper = try executable(named: "intellij-server", in: dir)
        let helperPath = helper.resolvingSymlinksInPath().path

        let entry = config(language: "kotlin", command: "kotlin-lsp", gatekeeperHelpers: ["intellij-server"])
        let availability = LanguageServerAvailability(
            environment: ["PATH": dir.path],
            xcrunFind: { _ in nil },
            additionalPathDirectories: [],
            gatekeeperAssessor: { path in path == helperPath ? .rejected : .allowed },
            gatekeeperRemediator: { _, _ in .failed("nope") }
        )

        let status = await availability.statusRemediatingGatekeeper(for: entry)

        guard case .blockedByGatekeeper(let realPath) = status else {
            Issue.record("Expected blocked helper path, got \(status)")
            return
        }
        #expect(realPath == helperPath)
    }

    @Test("auto-remediation rechecks primary command after successful remediation")
    func remediationRechecksPrimaryCommand() async throws {
        let dir = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let server = try executable(named: "kotlin-lsp", in: dir)
        let serverPath = server.resolvingSymlinksInPath().path
        var blocked = Set([serverPath])
        var remediated: [String] = []

        let entry = config(language: "kotlin", command: "kotlin-lsp")
        let availability = LanguageServerAvailability(
            environment: ["PATH": dir.path],
            xcrunFind: { _ in nil },
            additionalPathDirectories: [],
            gatekeeperAssessor: { path in blocked.contains(path) ? .rejected : .allowed },
            gatekeeperRemediator: { path, _ in
                remediated.append(path)
                blocked.remove(path)
                return .allowed
            }
        )

        #expect(await availability.statusRemediatingGatekeeper(for: entry) == .available)
        #expect(remediated == [serverPath])
    }

    @Test("notInstalled commands never reach the gatekeeper assessor")
    func notInstalledSkipsAssessor() {
        var assessorCalled = false
        let entry = config(language: "kotlin", command: "totally-not-installed-lsp")
        let availability = LanguageServerAvailability(
            environment: ["PATH": "/tmp/empty"],
            xcrunFind: { _ in nil },
            additionalPathDirectories: [],
            gatekeeperAssessor: { _ in
                assessorCalled = true
                return .rejected
            }
        )
        #expect(availability.status(for: entry) == .notInstalled)
        #expect(assessorCalled == false)
    }

    private func config(
        language: String = "test",
        command: String,
        args: [String] = [],
        env: [String: String] = [:],
        gatekeeperHelpers: [String] = [],
        gatekeeperRemediationRootMarkers: [String] = [],
        enabled: Bool = true
    ) -> LanguageServerConfig {
        LanguageServerConfig(
            language: language,
            extensions: [language],
            command: command,
            args: args,
            env: env,
            rootMarkers: [],
            gatekeeperHelpers: gatekeeperHelpers,
            gatekeeperRemediationRootMarkers: gatekeeperRemediationRootMarkers,
            enabled: enabled
        )
    }

    private func executable(named name: String, in dir: URL) throws -> URL {
        let url = dir.appendingPathComponent(name)
        #expect(FileManager.default.createFile(atPath: url.path, contents: Data()))
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return url
    }

    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("AlasTests")
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
