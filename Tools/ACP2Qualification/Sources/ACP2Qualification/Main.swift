import AlasCore
import Darwin
import Foundation

struct QualificationArguments: Sendable {
    let adapter: URL
    let helper: URL
    let mode: QualificationMode
    let output: URL

    init(_ arguments: [String]) throws {
        guard arguments.count == 8 else { throw QualificationFailure.arguments }
        var values: [String: String] = [:]
        for index in stride(from: 0, to: arguments.count, by: 2) {
            guard ["--adapter", "--helper", "--permission", "--output"].contains(arguments[index]),
                  values.updateValue(arguments[index + 1], forKey: arguments[index]) == nil else { throw QualificationFailure.arguments }
        }
        guard let adapter = values["--adapter"], adapter.hasPrefix("/"),
              let helper = values["--helper"], helper.hasPrefix("/"),
              let output = values["--output"], output.hasPrefix("/"),
              let mode = values["--permission"].flatMap(QualificationMode.init(rawValue:)) else { throw QualificationFailure.arguments }
        self.adapter = URL(fileURLWithPath: adapter).resolvingSymlinksInPath()
        self.helper = URL(fileURLWithPath: helper).resolvingSymlinksInPath()
        self.output = URL(fileURLWithPath: output)
        self.mode = mode
    }
}

enum QualificationFailure: Error { case arguments, identity, scratch, startup, prompt, permission, deadline, storage, cleanup }

struct QualificationReport: Codable {
    var formatVersion = 3
    var passed = false
    var failureStage: String?
    var identity: [String: String] = [:]
    var permissionMode: String
    var promptCompleted = false
    var promptMarker = false
    var permissionOffered = false
    var permissionOfferCount = 0
    var refusals: [String] = []
    var rejections: [String] = []
    var selectedAllowOnce = false
    var replyWritten = false
    var persistedReplyMatches: Bool?
    var persistedProtocolErrorCode: String?
    var sentinelMatches = false
    var sentinelAbsent = false
    var terminalReason: String?
    var intentCount: Int64?
    var attemptCount: Int64?
    var observationCount: Int64?
    var writtenObservationCount: Int64?
    var persistedAcknowledgedCursor: Int64?
    var journalBarrier: Int64?
    var runnerReady = false
    var activeRawBrokerCount: Int?
    var finalRawBrokerCount: Int?
    var finalLegacyBrokerCount: Int?
    var finalBrokerCount: Int?
}

@main struct Main {
    @MainActor static func main() async {
        do {
            let arguments = try QualificationArguments(Array(CommandLine.arguments.dropFirst()))
            let report = try await run(arguments)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try FileManager.default.createDirectory(at: arguments.output, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            try encoder.encode(report).write(to: arguments.output.appendingPathComponent("result.json"), options: .withoutOverwriting)
            print(report.passed ? "Qualification passed; sanitized evidence saved." : "Qualification failed at \(report.failureStage ?? "unknown"); sanitized evidence saved.")
            if !report.passed { exit(1) }
        } catch {
            // Provider errors and model text can contain account information.
            // Keep them out of stdout and the evidence directory.
            FileHandle.standardError.write(Data("Qualification could not start or save evidence. Usage: acp2-qualify --adapter <absolute-path> --helper <absolute-path> --permission allow-once|cancel --output <directory>\n".utf8))
            exit(1)
        }
    }

    @MainActor private static func run(_ arguments: QualificationArguments) async throws -> QualificationReport {
        let root = URL(fileURLWithPath: "/private/tmp/apq-" + String(UUID().uuidString.prefix(8)))
        guard mkdir(root.path, 0o700) == 0 else { throw QualificationFailure.scratch }
        var report = QualificationReport(permissionMode: arguments.mode.rawValue)
        var stage = "identity"
        let environment = ProcessInfo.processInfo.environment.filter { ["HOME", "PATH", "USER", "LOGNAME", "SHELL", "TMPDIR", "LANG"].contains($0.key) }
        var launchEnvironment = environment
        let transport = JSONRPCStdioTransport(executable: arguments.helper, arguments: ["serve"],
            environment: ["ALAS_HELPER_STATE_DIR": root.appendingPathComponent("h").path], framing: .newline, terminationScope: .processOnly)
        let remote = RemoteHelperClient(host: "local", idleShutdownNanoseconds: 0, transportFactory: { transport })
        let service = LocalACPBrokerService(client: remote)
        var broker: ACPBrokerClient?
        var runner: ACPV2SessionRunner?
        let completions = AsyncStream<ACPTurnCompletion.Result>.makeStream()
        var decisions: [Task<Void, Never>] = []
        var offerCount = 0
        var refused = false
        var written = false
        var selected = false
        var selectedOption: String?
        let command = "printf ACP_V2_PERMISSION_CHECK > " + root.appendingPathComponent("permission-probe.txt").path
        do {
            report.identity = try await identity(arguments, environment: environment)
            let agent = report.identity["agentID"]!
            if agent == "codex" { launchEnvironment["INITIAL_AGENT_MODE"] = "read-only" }
            let client = ACPBrokerClient(service: service, brokerId: .init(rawValue: "q"), sessionId: "q",
                command: arguments.adapter.path, args: [], cwd: root.path, env: launchEnvironment,
                operationKeyPrefix: UUID().uuidString, wireContext: .rawV2)
            broker = client
            let persistence = ACPSessionPersistence(path: root.appendingPathComponent("session.sqlite").path)
            let token = UUID().uuidString
            try await persistence.upsertSession(.init(id: "q", agentId: agent, title: "Qualification", autoRun: false,
                createdAt: 1, updatedAt: 1, lastOpenedAt: 1, archived: false))
            _ = try await persistence.seizeLease(sessionId: "q", instanceId: "qualification", pid: Int64(ProcessInfo.processInfo.processIdentifier), now: Int64(Date().timeIntervalSince1970), leaseToken: token)
            let session = ACPSession(id: "q", agentId: agent, worktreeId: "q", title: "Qualification")
            runner = try await ACPV2SessionRunner.makeBroker(session: session, client: client, persistence: persistence,
                fence: .init(sessionId: "q", ownerInstance: "qualification", token: token), info: .init(name: "alas", version: "qualification"),
                isCurrent: { true }, onEvent: { event in
                    switch event {
                    case .completion(let completion): completions.continuation.yield(completion.result)
                    case .interaction(.offer(let handle)):
                        offerCount += 1
                        let assessment = QualificationDecisionPolicy.assess(in: handle.request, expectedCommand: command, directory: root)
                        let option = assessment.optionID
                        if let reason = assessment.refusal { report.refusals.append(reason.rawValue) }
                        let mayAllow = arguments.mode == .allowOnce && offerCount == 1 && option != nil
                        if option == nil || offerCount != 1 { refused = true }
                        selected = selected || mayAllow
                        if mayAllow { selectedOption = option }
                        decisions.append(Task { @MainActor in
                            do {
                                let receipt = try await runner!.decide(handle, decision: mayAllow ? .selectPermission(optionID: option!) : .cancelPermission)
                                if receipt.value.fact == .broker(.written) { written = true }
                                else { refused = true }
                            } catch { refused = true }
                        })
                    case .interaction(.rejection(let handle)):
                        switch handle.request.classification {
                        case .malformed: report.rejections.append("malformed")
                        case .unsupported(let reason): report.rejections.append(String(describing: reason))
                        default: report.rejections.append("unavailable")
                        }
                    case .interaction: break
                    }
                })
            stage = "startup"
            let started = try await runner!.start(params: .init(cwd: root.path, mcpServers: []), deadline: .now.advanced(by: .seconds(60)))
            if agent == "claude" {
                let response = try await client.send(.init(method: "session/set_config_option",
                    params: ["sessionId": started.sessionId, "configId": "mode", "type": "id", "value": "default"], brokerOperationKey: "qualification:mode-default"))
                guard let raw = response.rawDelivery, try raw.decode().error == nil else { throw QualificationFailure.startup }
                response.acknowledgeDurableConsumption()
            }
            var ended = completions.stream.makeAsyncIterator()
            let prompts = ["Reply with exactly ACP_V2_READY. Do not use tools.",
                "Use your shell tool to run exactly: \(command). This is an isolated disposable scratch directory. Request approval if needed. If permission is declined or cancelled, stop and reply PERMISSION_CANCELLED. Do not change any other file or retry with another tool."]
            for (index, prompt) in prompts.enumerated() {
                stage = index == 0 ? "prompt" : "permission"
                let timeout = Task { @MainActor in
                    do { try await ContinuousClock().sleep(for: .seconds(120)) } catch { return }
                    runner?.stop()
                    completions.continuation.finish()
                }
                defer { timeout.cancel() }
                let record = try await runner!.submit(id: UUID(), row: .user(id: UUID(), messageId: nil, text: prompt, attachments: []),
                    params: .init(sessionId: started.sessionId, prompt: [.text(prompt)]))
                guard case .accepted = record.recovery, let result = await ended.next() else { throw QualificationFailure.deadline }
                if index == 0 {
                    report.promptCompleted = result == .completed
                    report.promptMarker = session.transcript.messages.compactMap { message -> String? in
                        if case .agent(_, _, let text) = message { return text.value }
                        return nil
                    }.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines) == "ACP_V2_READY"
                    guard report.promptCompleted, report.promptMarker, offerCount == 0 else { throw QualificationFailure.prompt }
                } else {
                    switch result {
                    case .completed: report.terminalReason = "completed"
                    case .cancelled where arguments.mode == .cancel: report.terminalReason = "cancelled"
                    case .failed: report.terminalReason = "failed"
                    throw QualificationFailure.permission
                    case .limited: report.terminalReason = "limited"
                    throw QualificationFailure.permission
                    case .stopped: report.terminalReason = "stopped"
                    throw QualificationFailure.permission
                    case .cancelled: report.terminalReason = "cancelled"
                    throw QualificationFailure.permission
                    }
                }
            }
            for task in decisions { await task.value }
            report.permissionOffered = offerCount == 1
            report.selectedAllowOnce = selected
            report.replyWritten = written
            let sentinel = root.appendingPathComponent("permission-probe.txt")
            report.sentinelAbsent = !FileManager.default.fileExists(atPath: sentinel.path)
            report.sentinelMatches = (try? Data(contentsOf: sentinel)) == Data("ACP_V2_PERMISSION_CHECK".utf8)
            guard offerCount == 1, !refused, written,
                  arguments.mode == .allowOnce ? (selected && report.sentinelMatches) : (!selected && report.sentinelAbsent) else { throw QualificationFailure.permission }
            stage = "storage"
            try await client.replayRawBrokerEvents()
            try collectStoredFacts(root: root, mode: arguments.mode, selectedOption: selectedOption, report: &report)
            let rawBrokers = try await remote.listACPBroker(wireContext: .rawV2).brokers
            report.activeRawBrokerCount = rawBrokers.count
            guard rawBrokers.count == 1, let snapshot = rawBrokers.first,
                  snapshot.metadata.brokerId.rawValue == "q", snapshot.metadata.alasSessionId == "q",
                  snapshot.metadata.adapterProgram == arguments.adapter.path,
                  snapshot.metadata.adapterArgs.isEmpty, snapshot.metadata.cwd == root.path,
                  snapshot.journalTail.rawValue <= UInt64(Int64.max) else { throw QualificationFailure.storage }
            let barrier = Int64(snapshot.journalTail.rawValue)
            report.journalBarrier = barrier
            let mirrorDeadline = ContinuousClock.now.advanced(by: .seconds(5))
            repeat {
                report.persistedAcknowledgedCursor = try await persistence.loadSession(id: "q")?.acpBrokerAcknowledgedCursor ?? 0
                if (report.persistedAcknowledgedCursor ?? -1) >= barrier { break }
                try await client.replayRawBrokerEvents()
                await Task.yield()
            } while ContinuousClock.now < mirrorDeadline
            report.runnerReady = runner?.status == .ready
            guard report.intentCount == 1, report.attemptCount == 1, report.observationCount == 1, report.writtenObservationCount == 1,
                  report.persistedReplyMatches == true, report.runnerReady,
                  (report.persistedAcknowledgedCursor ?? -1) > 0,
                  (report.persistedAcknowledgedCursor ?? -1) >= barrier else { throw QualificationFailure.storage }
            stage = "identity-revalidation"
            guard try await identity(arguments, environment: environment) == report.identity else { throw QualificationFailure.identity }
            report.passed = true
        } catch { report.failureStage = stage }
        report.runnerReady = runner?.status == .ready
        runner?.stop()
        completions.continuation.finish()
        for task in decisions { task.cancel() }
        for task in decisions { await task.value }
        report.permissionOffered = offerCount > 0
        report.permissionOfferCount = offerCount
        report.selectedAllowOnce = selected
        report.replyWritten = written
        let sentinel = root.appendingPathComponent("permission-probe.txt")
        report.sentinelAbsent = !FileManager.default.fileExists(atPath: sentinel.path)
        report.sentinelMatches = (try? Data(contentsOf: sentinel)) == Data("ACP_V2_PERMISSION_CHECK".utf8)
        try? collectStoredFacts(root: root, mode: arguments.mode, selectedOption: selectedOption, report: &report)
        if report.passed {
            report.passed = offerCount == 1 && !refused && written && report.runnerReady
                && report.intentCount == 1 && report.attemptCount == 1 && report.observationCount == 1 && report.writtenObservationCount == 1
                && report.persistedReplyMatches == true && (report.persistedAcknowledgedCursor ?? -1) >= (report.journalBarrier ?? Int64.max)
                && (arguments.mode == .allowOnce ? selected && report.sentinelMatches : !selected && report.sentinelAbsent)
            if !report.passed { report.failureStage = "final-evidence" }
        }
        // The namespace was created exclusively for this run. Never close an adopted source.
        let cleanupTimeout = Task {
            do { try await ContinuousClock().sleep(for: .seconds(15)) } catch { return }
            await remote.shutdown()
        }
        if let broker {
            if broker.adoptedRunningAgent { await broker.detach() }
            else { await broker.shutdown() }
        }
        report.finalRawBrokerCount = try? await remote.listACPBroker(wireContext: .rawV2).brokers.count
        report.finalLegacyBrokerCount = try? await remote.listACPBroker(wireContext: .legacyV1).brokers.count
        if let raw = report.finalRawBrokerCount, let legacy = report.finalLegacyBrokerCount {
            report.finalBrokerCount = raw + legacy
        }
        cleanupTimeout.cancel()
        await remote.shutdown()
        if report.finalBrokerCount != 0 { report.passed = false
        report.failureStage = "cleanup" }
        if report.finalBrokerCount == 0 { try? FileManager.default.removeItem(at: root) }
        return report
    }

    private static func collectStoredFacts(root: URL, mode: QualificationMode, selectedOption: String?, report: inout QualificationReport) throws {
        let path = root.appendingPathComponent("session.sqlite").path
        guard FileManager.default.fileExists(atPath: path) else { return }
        let store = try ACPSessionStore(path: path)
        func count(_ query: String) throws -> Int64? { try store.db.query(query).first?["n"] as? Int64 }
        report.intentCount = try count("SELECT COUNT(*) AS n FROM acp_v2_response_intents")
        report.attemptCount = try count("SELECT COUNT(*) AS n FROM acp_v2_response_attempts")
        report.observationCount = try count("SELECT COUNT(*) AS n FROM acp_v2_response_observations")
        report.writtenObservationCount = try count("SELECT COUNT(*) AS n FROM acp_v2_response_observations WHERE kind=1 AND status=2")
        report.persistedAcknowledgedCursor = try store.loadSession(id: "q")?.acpBrokerAcknowledgedCursor
        if let frame = try store.db.query("SELECT frame FROM acp_v2_response_intents").first?["frame"] as? Data,
           case .object(let envelope) = try LSPJSONValue.decode(from: frame) {
            if case .object(let error)? = envelope["error"], case .number(let code)? = error["code"] { report.persistedProtocolErrorCode = code }
            if case .object(let result)? = envelope["result"], case .object(let outcome)? = result["outcome"] {
                report.persistedReplyMatches = mode == .allowOnce
                    ? outcome["outcome"] == .string("selected") && outcome["optionId"] == selectedOption.map(LSPJSONValue.string)
                    : outcome["outcome"] == .string("cancelled")
            }
        }
    }

    private static func identity(_ arguments: QualificationArguments, environment: [String: String]) async throws -> [String: String] {
        try await Task.detached {
            let root = arguments.adapter.deletingLastPathComponent().deletingLastPathComponent()
            let manifest = try JSONSerialization.jsonObject(with: Data(contentsOf: root.appendingPathComponent("package.json"))) as? [String: Any]
            guard let name = manifest?["name"] as? String,
                  let descriptor = [ACPManagedAdapterDescriptor.claude, .codex].first(where: { $0.packageName == name }),
                  let version = manifest?["version"] as? String, let bin = manifest?["bin"] as? [String: String],
                  let binary = bin[descriptor.binaryName], root.appendingPathComponent(binary).resolvingSymlinksInPath() == arguments.adapter,
                  let source = manifest?["alasDownstream"] as? [String: String], let commit = source["sourceCommit"],
                  let node = environment["PATH"]?.split(separator: ":").filter({ $0.hasPrefix("/") }).map({ URL(fileURLWithPath: String($0)).appendingPathComponent("node") }).first(where: { FileManager.default.isExecutableFile(atPath: $0.path) }) else { throw QualificationFailure.identity }
            let process = Process()
            let output = Pipe()
            process.executableURL = node
            process.arguments = ["--version"]
            process.environment = environment
            process.standardOutput = output
            process.standardError = FileHandle.nullDevice
            try process.run()
            let bytes = output.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            guard process.terminationStatus == 0, let nodeVersion = String(data: bytes, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines), nodeVersion.hasPrefix("v") else { throw QualificationFailure.identity }
            return ["agentID": descriptor.agentID, "packageName": name, "packageVersion": version,
                "declaredSourceCommit": commit, "packageDigest": try QualificationIdentity.packageDigest(at: root),
                "helperDigest": try QualificationIdentity.fileDigest(arguments.helper), "nodeVersion": nodeVersion,
                "nodeDigest": try QualificationIdentity.fileDigest(node.resolvingSymlinksInPath()),
                "providerRouteRequested": "default-cli-login",
                "approvalMode": name.contains("codex") ? "read-only" : "default"]
        }.value
    }
}
