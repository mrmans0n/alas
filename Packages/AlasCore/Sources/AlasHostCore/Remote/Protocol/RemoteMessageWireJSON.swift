import Foundation
import AlasFoundation
import AlasModel
import AlasPlatform
import AlasFeatures
import AlasCode
import AlasAgents
import AlasACP

/// One transcript message as sent to the web client. `text` carries the
/// human-visible body for simple kinds; `json` carries a structured blob
/// for tool calls / file edits / plans the web client renders specially.
public struct RemoteWireMessage: Codable, Equatable, Sendable {
    public let stableId: String
    public let kind: String          // "user" | "agent" | "thought" | "toolCall" | "fileEdit" | "plan" | "visualAid" | "systemNotice"
    public let text: String?
    public let json: String?         // JSON string for structured kinds; nil otherwise
    public let index: Int            // transcript position; the client orders and windows by this
    public var isHidden: Bool? = nil

    /// A conservative bound for compact JSONEncoder output, without serializing
    /// or copying the bodies. The fixed overhead covers keys, punctuation,
    /// string quotes and a signed 64-bit index. Absent bodies add no bytes.
    public var transportByteCount: Int {
        var count = 64
            + Self.escapedTransportByteCount(stableId)
            + Self.escapedTransportByteCount(kind)
        if let text {
            count += 10 + Self.escapedTransportByteCount(text)
        }
        if let json {
            count += 10 + Self.escapedTransportByteCount(json)
        }
        if isHidden != nil { count += 17 }
        return count
    }

    /// The notice a row of `kind` too large to send is replaced with.
    public static func oversizedNotice(kind: String) -> String {
        "This \(kind) content is too large for remote display. The full content is available on the owning Mac."
    }

    /// The budget must fit the row's identity and a short omission notice.
    /// Returning the count lets callers batch rows without rescanning the body.
    public func boundedForTransport(maximumBytes: Int) -> (message: RemoteWireMessage, byteCount: Int) {
        let byteCount = transportByteCount
        guard byteCount > maximumBytes else { return (self, byteCount) }

        let notice = RemoteWireMessage(
            stableId: stableId,
            kind: "systemNotice",
            text: Self.oversizedNotice(kind: kind),
            json: nil,
            index: index
        )
        let noticeByteCount = notice.transportByteCount
        precondition(
            noticeByteCount <= maximumBytes,
            "The transport budget must fit the row identity and oversized-content notice."
        )
        return (notice, noticeByteCount)
    }

    private static func escapedTransportByteCount(_ value: String) -> Int {
        var count = 0
        for byte in value.utf8 {
            switch byte {
            case 0x00...0x1f:
                count += 6 // \u00xx also bounds the shorter escapes such as \n.
            case 0x22, 0x2f, 0x5c:
                count += 2 // Quote, slash and backslash.
            default:
                count += 1
            }
        }
        return count
    }

    public init(stableId: String, kind: String, text: String?, json: String?, index: Int, isHidden: Bool? = nil) {
        self.stableId = stableId
        self.kind = kind
        self.text = text
        self.json = json
        self.index = index
        self.isHidden = isHidden
    }
}

/// A visual aid as the phone receives it in `RemoteWireMessage.json`. The
/// answer timestamp stays on the Mac; the phone needs only what it shows.
public struct RemoteVisualAid: Codable, Equatable, Sendable {
    public struct Option: Codable, Equatable, Sendable {
        public let id: String
        public let label: String

        public init(id: String, label: String) {
            self.id = id
            self.label = label
        }
    }

    public struct Question: Codable, Equatable, Sendable {
        public let prompt: String
        public let options: [Option]
        public let allowMultiple: Bool

        public init(prompt: String, options: [Option], allowMultiple: Bool) {
            self.prompt = prompt
            self.options = options
            self.allowMultiple = allowMultiple
        }
    }

    public struct Answer: Codable, Equatable, Sendable {
        public let kind: String
        public let selectedOptionIds: [String]?
        public let note: String?

        public init(kind: String, selectedOptionIds: [String]?, note: String?) {
            self.kind = kind
            self.selectedOptionIds = selectedOptionIds
            self.note = note
        }
    }

    public let id: String
    public let title: String
    public let html: String
    public let question: Question?
    public let answer: Answer?
    /// `"embedded"` or `"card"`, from `ACPVisualAid.Presentation`.
    public let presentation: String

    public init(_ visual: ACPVisualAid) {
        id = visual.id.uuidString
        title = visual.title
        html = visual.html
        presentation = visual.presentation.rawValue
        question = visual.question.map { question in
            Question(
                prompt: question.prompt,
                options: question.options.map { Option(id: $0.id, label: $0.label) },
                allowMultiple: question.allowMultiple)
        }
        switch visual.answer {
        case .answered(let ids, let note, _):
            answer = Answer(kind: "answered", selectedOptionIds: ids, note: note)
        case .dismissed:
            answer = Answer(kind: "dismissed", selectedOptionIds: nil, note: nil)
        case nil:
            answer = nil
        }
    }

    private enum CodingKeys: String, CodingKey {
        case id, title, html, question, answer, presentation
    }

    /// A row from a Mac that predates `presentation` reads as a card.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        title = try c.decode(String.self, forKey: .title)
        html = try c.decode(String.self, forKey: .html)
        question = try c.decodeIfPresent(Question.self, forKey: .question)
        answer = try c.decodeIfPresent(Answer.self, forKey: .answer)
        presentation = try c.decodeIfPresent(String.self, forKey: .presentation) ?? ACPVisualAid.Presentation.card.rawValue
    }
}

/// One queued prompt as sent to the web client. Deliberately carries an image
/// COUNT, never image bytes or URIs — the web client has no authenticated way
/// to fetch attachment data, and a queued bubble only needs to say "there are
/// images here" to render its placeholder. `resourceCount` mirrors the same
/// idea for `.resourceLink`/`.resource` blocks (file mentions): the browser
/// never receives the underlying URI, only a count to render as a chip.
public struct RemoteQueuedPrompt: Codable, Equatable, Sendable {
    public let id: String          // QueuedPrompt.id, uuidString
    public let text: String        // .text blocks, joined
    public let imageCount: Int
    public let resourceCount: Int
    public let status: String      // "pending" | "sending"
    public let lastError: String?
    public let scheduledAt: Double? // Unix milliseconds for JavaScript Date
    public var canRemove: Bool? = nil // Absent from older peers, which allow generic queue actions.

    public init(id: String, text: String, imageCount: Int, resourceCount: Int, status: String, lastError: String?, scheduledAt: Double?, canRemove: Bool? = nil) {
        self.id = id
        self.text = text
        self.imageCount = imageCount
        self.resourceCount = resourceCount
        self.status = status
        self.lastError = lastError
        self.scheduledAt = scheduledAt
        self.canRemove = canRemove
    }
}

public struct RemoteWorktreeSummary: Codable, Equatable, Sendable {
    public let projectName: String
    public let worktreeName: String
    public let branch: String
    public let path: String
    public let metricsAvailable: Bool
    public let comparisonRef: String?
    public let commitCount: Int
    public let changedFileCount: Int
    public let addedLines: Int
    public let deletedLines: Int
    public let conflictCount: Int
    /// Ordering inputs for a peer's sidebar, so it can follow the owning
    /// Mac's own worktree ordering. Nil from an older peer that predates them.
    public var isMain: Bool? = nil
    public var createdAt: Double? = nil
    public var lastActivity: Double? = nil
    /// True for a folder project, which has no git and so no Changes. Sent
    /// only when true; nil (git, or an older host) keeps today's behavior.
    public var isFolder: Bool? = nil

    public init(projectName: String, worktreeName: String, branch: String, path: String, metricsAvailable: Bool, comparisonRef: String?, commitCount: Int, changedFileCount: Int, addedLines: Int, deletedLines: Int, conflictCount: Int, isMain: Bool? = nil, createdAt: Double? = nil, lastActivity: Double? = nil, isFolder: Bool? = nil) {
        self.projectName = projectName
        self.worktreeName = worktreeName
        self.branch = branch
        self.path = path
        self.metricsAvailable = metricsAvailable
        self.comparisonRef = comparisonRef
        self.commitCount = commitCount
        self.changedFileCount = changedFileCount
        self.addedLines = addedLines
        self.deletedLines = deletedLines
        self.conflictCount = conflictCount
        self.isMain = isMain
        self.createdAt = createdAt
        self.lastActivity = lastActivity
        self.isFolder = isFolder
    }
}

public struct RemoteWorktreeOption: Codable, Equatable, Sendable {
    public let id: String
    public let projectName: String
    public let worktreeName: String
    public let branch: String
    public let path: String
    public let metricsAvailable: Bool
    public let comparisonRef: String?
    public let commitCount: Int
    public let changedFileCount: Int
    public let addedLines: Int
    public let deletedLines: Int
    public let conflictCount: Int
    /// The peer's project id. Older peers omit it; clients then match by
    /// `projectName`.
    public var projectId: String? = nil

    public init(id: String, projectName: String, worktreeName: String, branch: String, path: String, metricsAvailable: Bool, comparisonRef: String?, commitCount: Int, changedFileCount: Int, addedLines: Int, deletedLines: Int, conflictCount: Int, projectId: String? = nil) {
        self.id = id
        self.projectName = projectName
        self.worktreeName = worktreeName
        self.branch = branch
        self.path = path
        self.metricsAvailable = metricsAvailable
        self.comparisonRef = comparisonRef
        self.commitCount = commitCount
        self.changedFileCount = changedFileCount
        self.addedLines = addedLines
        self.deletedLines = deletedLines
        self.conflictCount = conflictCount
        self.projectId = projectId
    }
}

/// A model an agent advertised on the sending Mac, remembered across
/// sessions. A hint for pickers, not a contract.
public struct RemoteModelOption: Codable, Equatable, Sendable {
    public let id: String
    public let name: String

    public init(id: String, name: String) {
        self.id = id
        self.name = name
    }
}

/// A thinking level an agent advertised on the sending Mac, remembered
/// across sessions. A hint for pickers, not a contract.
public struct RemoteEffortOption: Codable, Equatable, Sendable {
    public let id: String
    public let name: String

    public init(id: String, name: String) {
        self.id = id
        self.name = name
    }
}

public struct RemoteAgentOption: Codable, Equatable, Sendable {
    public let id: String
    public let name: String
    public let isDefault: Bool
    /// Nil when the sending Mac has never seen this agent's models, or is
    /// older than this field.
    public var models: [RemoteModelOption]? = nil
    /// Nil when the sending Mac has never seen this agent's thinking levels,
    /// cannot set them before a session exists, or is older than this field.
    public var efforts: [RemoteEffortOption]? = nil
    /// Projects whose host cannot launch this agent, such as SSH projects
    /// for an agent installed only on the sending Mac. Nil when it runs
    /// everywhere, or the sending Mac is older than this field.
    public var unavailableProjectIds: [String]? = nil

    /// Whether pickers should offer this agent for `projectId`; nil means
    /// the project is not known yet.
    public func isAvailable(inProjectId projectId: String?) -> Bool {
        guard let projectId else { return true }
        return unavailableProjectIds?.contains(projectId) != true
    }

    public init(id: String, name: String, isDefault: Bool, models: [RemoteModelOption]? = nil, efforts: [RemoteEffortOption]? = nil, unavailableProjectIds: [String]? = nil) {
        self.id = id
        self.name = name
        self.isDefault = isDefault
        self.models = models
        self.efforts = efforts
        self.unavailableProjectIds = unavailableProjectIds
    }
}

public struct RemoteProjectOption: Codable, Equatable, Sendable {
    public let id: String
    public let name: String

    public init(id: String, name: String) {
        self.id = id
        self.name = name
    }
}

public enum RemoteWorktreeSessionCreationStage: String, Codable, Equatable, Sendable {
    case worktree
    case session
}

public enum RemoteBranchListResult: Equatable, Sendable {
    case success(branches: [String], preferredBase: String)
    case failure(String)
}

public enum RemoteCreateWorktreeSessionResult: Equatable, Sendable {
    case success(RemoteSessionSummary)
    case failure(
        stage: RemoteWorktreeSessionCreationStage,
        message: String,
        worktreeId: String?
    )
    /// Nothing was created: the client's user must approve `hook` first.
    case needsRepoHookApproval(PeerRepoHook)
}

public enum RemoteCreateSessionResult: Equatable, Sendable {
    case success(RemoteSessionSummary)
    case failure(String)
}

public enum RemoteSessionTabActionResult: Equatable, Sendable {
    case success
    case failure(String)
}

public struct RemoteSessionSummary: Equatable, Sendable {
    public let id: String
    public let title: String
    public let agentId: String
    public let status: String       // "idle" | "streaming" | "awaitingPermission" | "awaitingInput"
    public let canDrive: Bool       // this remote-host instance currently holds the writer lease
    public let isActive: Bool       // still backed by an open Alas tab
    /// The tab's position in its worktree's tab strip on the host. Nil for
    /// history sessions and from hosts that predate tab ordering.
    public let tabIndex: Int?
    public let projectId: String?
    public let worktreeId: String?
    public let updatedAt: Int64
    public let worktree: RemoteWorktreeSummary?
    /// Set only on rows a gateway forwards from a peer: the peer's `serverId`
    /// and display name, so a client can group by Mac. Nil means the row is
    /// local to the Mac that sent it, exactly as before federation.
    public let serverId: String?
    public let serverName: String?

    public init(
        id: String,
        title: String,
        agentId: String,
        status: String,
        canDrive: Bool,
        isActive: Bool = true,
        tabIndex: Int? = nil,
        projectId: String? = nil,
        worktreeId: String? = nil,
        updatedAt: Int64 = 0,
        worktree: RemoteWorktreeSummary? = nil,
        serverId: String? = nil,
        serverName: String? = nil
    ) {
        self.id = id
        self.title = title
        self.agentId = agentId
        self.status = status
        self.canDrive = canDrive
        self.isActive = isActive
        self.tabIndex = tabIndex
        self.projectId = projectId
        self.worktreeId = worktreeId
        self.updatedAt = updatedAt
        self.worktree = worktree
        self.serverId = serverId
        self.serverName = serverName
    }
}

extension RemoteSessionSummary: Codable {
    private enum CodingKeys: String, CodingKey {
        case id, title, agentId, status, canDrive, isActive, tabIndex, projectId, worktreeId, updatedAt, worktree
        case serverId, serverName
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            id: try c.decode(String.self, forKey: .id),
            title: try c.decode(String.self, forKey: .title),
            agentId: try c.decode(String.self, forKey: .agentId),
            status: try c.decode(String.self, forKey: .status),
            canDrive: try c.decode(Bool.self, forKey: .canDrive),
            isActive: try c.decodeIfPresent(Bool.self, forKey: .isActive) ?? true,
            tabIndex: try c.decodeIfPresent(Int.self, forKey: .tabIndex),
            projectId: try c.decodeIfPresent(String.self, forKey: .projectId),
            worktreeId: try c.decodeIfPresent(String.self, forKey: .worktreeId),
            updatedAt: try c.decodeIfPresent(Int64.self, forKey: .updatedAt) ?? 0,
            worktree: try c.decodeIfPresent(RemoteWorktreeSummary.self, forKey: .worktree),
            serverId: try c.decodeIfPresent(String.self, forKey: .serverId),
            serverName: try c.decodeIfPresent(String.self, forKey: .serverName)
        )
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(title, forKey: .title)
        try c.encode(agentId, forKey: .agentId)
        try c.encode(status, forKey: .status)
        try c.encode(canDrive, forKey: .canDrive)
        try c.encode(isActive, forKey: .isActive)
        try c.encodeIfPresent(tabIndex, forKey: .tabIndex)
        try c.encodeIfPresent(projectId, forKey: .projectId)
        try c.encodeIfPresent(worktreeId, forKey: .worktreeId)
        try c.encode(updatedAt, forKey: .updatedAt)
        try c.encodeIfPresent(worktree, forKey: .worktree)
        try c.encodeIfPresent(serverId, forKey: .serverId)
        try c.encodeIfPresent(serverName, forKey: .serverName)
    }
}

/// A permission request surfaced to the client.
public struct RemotePermissionPayload: Codable, Equatable, Sendable {
    public let requestId: Int
    public let toolName: String
    public let options: [RemotePermissionOption]
    /// `_meta.permission.title` (see `ACPPermissionPresentation`). Absent
    /// for adapters without the extension — the client falls back to the
    /// generic "Allow “<toolName>”?" prompt.
    public let title: String?
    /// `_meta.permission.description` — reason line under the prompt.
    public let reason: String?
    /// `_meta.permission.defaultToNo` — the client should give the reject
    /// option default-button styling instead of the allow option.
    public let defaultToNo: Bool
    /// `_meta.claudeCode.mcpServer.name` for `mcp__*` calls.
    public let mcpServerName: String?
    /// First text block from the permission's `toolCall.content`, commonly
    /// the command that is awaiting approval.
    public let commandSummary: String?

    public init(
        requestId: Int, toolName: String, options: [RemotePermissionOption],
        title: String? = nil, reason: String? = nil, defaultToNo: Bool = false,
        mcpServerName: String? = nil, commandSummary: String? = nil
    ) {
        self.requestId = requestId
        self.toolName = toolName
        self.options = options
        self.title = title
        self.reason = reason
        self.defaultToNo = defaultToNo
        self.mcpServerName = mcpServerName
        self.commandSummary = commandSummary
    }

    private enum CodingKeys: String, CodingKey {
        case requestId, toolName, options, title, reason, defaultToNo, mcpServerName, commandSummary
    }

    // `RemotePeerConnection` decodes this from other Alas instances, which
    // can run an older protocol version that predates defaultToNo entirely
    // — RemoteProtocolVersion treats additive fields like this one as
    // version-compatible, so a missing key must decode to `false`, not
    // fail the whole payload the way synthesized Decodable would for a
    // non-optional Bool.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        requestId = try c.decode(Int.self, forKey: .requestId)
        toolName = try c.decode(String.self, forKey: .toolName)
        options = try c.decode([RemotePermissionOption].self, forKey: .options)
        title = try c.decodeIfPresent(String.self, forKey: .title)
        reason = try c.decodeIfPresent(String.self, forKey: .reason)
        defaultToNo = try c.decodeIfPresent(Bool.self, forKey: .defaultToNo) ?? false
        mcpServerName = try c.decodeIfPresent(String.self, forKey: .mcpServerName)
        commandSummary = try c.decodeIfPresent(String.self, forKey: .commandSummary)
    }
}

public struct RemotePermissionOption: Codable, Equatable, Sendable {
    public let optionId: String
    public let name: String
    public let kind: String
    /// `_meta.permission.description` for this option.
    public let description: String?

    public init(optionId: String, name: String, kind: String, description: String? = nil) {
        self.optionId = optionId
        self.name = name
        self.kind = kind
        self.description = description
    }
}

/// A question option as sent to the client.
public struct RemoteQuestionOption: Codable, Equatable, Sendable {
    public let id: String
    public let label: String

    public init(id: String, label: String) {
        self.id = id
        self.label = label
    }
}

/// A single question surfaced to the client.
public struct RemoteQuestion: Codable, Equatable, Sendable {
    public let id: String
    public let prompt: String
    public let options: [RemoteQuestionOption]
    public let allowMultiple: Bool

    public init(id: String, prompt: String, options: [RemoteQuestionOption], allowMultiple: Bool) {
        self.id = id
        self.prompt = prompt
        self.options = options
        self.allowMultiple = allowMultiple
    }
}

/// A question request (one or more questions) surfaced to the client.
public struct RemoteQuestionPayload: Codable, Equatable, Sendable {
    public let requestId: Int
    public let title: String?
    public let questions: [RemoteQuestion]

    public init(requestId: Int, title: String?, questions: [RemoteQuestion]) {
        self.requestId = requestId
        self.title = title
        self.questions = questions
    }
}

/// The client's answer to one question.
public struct RemoteQuestionAnswer: Codable, Equatable, Sendable {
    public let questionId: String
    public let selectedOptionIds: [String]

    public init(questionId: String, selectedOptionIds: [String]) {
        self.questionId = questionId
        self.selectedOptionIds = selectedOptionIds
    }
}

public struct RemotePlanTodo: Codable, Equatable, Sendable {
    public let id: String
    public let content: String
    public let status: String

    public init(id: String, content: String, status: String) {
        self.id = id
        self.content = content
        self.status = status
    }
}

public struct RemotePlanPhase: Codable, Equatable, Sendable {
    public let name: String
    public let todos: [RemotePlanTodo]

    public init(name: String, todos: [RemotePlanTodo]) {
        self.name = name
        self.todos = todos
    }
}

public struct RemotePlanPayload: Codable, Equatable, Sendable {
    public let requestId: JSONRPCID
    public let toolCallId: String
    public let name: String
    public let overview: String
    public let plan: String
    public let todos: [RemotePlanTodo]
    public let isProject: Bool
    public let phases: [RemotePlanPhase]

    public init(requestId: JSONRPCID, toolCallId: String, name: String, overview: String, plan: String, todos: [RemotePlanTodo], isProject: Bool, phases: [RemotePlanPhase]) {
        self.requestId = requestId
        self.toolCallId = toolCallId
        self.name = name
        self.overview = overview
        self.plan = plan
        self.todos = todos
        self.isProject = isProject
        self.phases = phases
    }
}

public struct RemoteElicitationOption: Codable, Equatable, Sendable {
    public let value: String
    public let title: String?
    public let description: String?

    public init(value: String, title: String?, description: String?) {
        self.value = value
        self.title = title
        self.description = description
    }
}

public struct RemoteElicitationField: Codable, Equatable, Sendable {
    public let key: String
    public let type: String
    public let title: String
    public let description: String?
    public let required: Bool
    public let minLength: Int?
    public let maxLength: Int?
    public let minimum: Double?
    public let maximum: Double?
    public let minItems: Int?
    public let maxItems: Int?
    public let format: String?
    public let pattern: String?
    /// Whether free-form string input should be masked in native prompts.
    public let isSecret: Bool
    public let options: [RemoteElicitationOption]
    public let defaultValue: ACPElicitationValue?

    public init(
        key: String,
        type: String,
        title: String,
        description: String?,
        required: Bool,
        minLength: Int?,
        maxLength: Int?,
        minimum: Double?,
        maximum: Double?,
        minItems: Int?,
        maxItems: Int?,
        format: String?,
        pattern: String?,
        isSecret: Bool = false,
        options: [RemoteElicitationOption],
        defaultValue: ACPElicitationValue?
    ) {
        self.key = key
        self.type = type
        self.title = title
        self.description = description
        self.required = required
        self.minLength = minLength
        self.maxLength = maxLength
        self.minimum = minimum
        self.maximum = maximum
        self.minItems = minItems
        self.maxItems = maxItems
        self.format = format
        self.pattern = pattern
        self.isSecret = isSecret
        self.options = options
        self.defaultValue = defaultValue
    }

    private enum CodingKeys: String, CodingKey {
        case key, type, title, description, required, minLength, maxLength, minimum, maximum
        case minItems, maxItems, format, pattern, isSecret, options, defaultValue
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            key: try container.decode(String.self, forKey: .key),
            type: try container.decode(String.self, forKey: .type),
            title: try container.decode(String.self, forKey: .title),
            description: try container.decodeIfPresent(String.self, forKey: .description),
            required: try container.decode(Bool.self, forKey: .required),
            minLength: try container.decodeIfPresent(Int.self, forKey: .minLength),
            maxLength: try container.decodeIfPresent(Int.self, forKey: .maxLength),
            minimum: try container.decodeIfPresent(Double.self, forKey: .minimum),
            maximum: try container.decodeIfPresent(Double.self, forKey: .maximum),
            minItems: try container.decodeIfPresent(Int.self, forKey: .minItems),
            maxItems: try container.decodeIfPresent(Int.self, forKey: .maxItems),
            format: try container.decodeIfPresent(String.self, forKey: .format),
            pattern: try container.decodeIfPresent(String.self, forKey: .pattern),
            isSecret: try container.decodeIfPresent(Bool.self, forKey: .isSecret) ?? false,
            options: try container.decode([RemoteElicitationOption].self, forKey: .options),
            defaultValue: try container.decodeIfPresent(ACPElicitationValue.self, forKey: .defaultValue)
        )
    }
}

public struct RemoteElicitationPayload: Codable, Equatable, Sendable {
    public let requestId: String
    public let title: String?
    public let message: String
    public let mode: String
    public let fields: [RemoteElicitationField]
    public let elicitationId: String?
    public let url: String?

    public init(requestId: String, title: String?, message: String, mode: String, fields: [RemoteElicitationField], elicitationId: String?, url: String?) {
        self.requestId = requestId
        self.title = title
        self.message = message
        self.mode = mode
        self.fields = fields
        self.elicitationId = elicitationId
        self.url = url
    }
}

/// Why a changes/files request could not be served. Decoded leniently so an
/// older client keeps working against a newer host that adds reasons.
public enum RemoteFileAccessReason: String, Codable, Equatable, Sendable {
    case sessionUnknown
    case worktreeUnavailable
    case pathRejected
    case notFound
    case binary
    case tooLarge
    case gitFailed
    case unknown

    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = RemoteFileAccessReason(rawValue: raw) ?? .unknown
    }
}

/// Wire projection of `ChangedFile`. `conflict` carries `ConflictKind`'s raw
/// value so the client can mark conflicted files without knowing the enum.
public struct RemoteChangedFile: Codable, Equatable, Sendable {
    public let path: String
    public let status: String
    public let add: Int
    public let del: Int
    public let conflict: String?
    public let renameFrom: String?

    public init(path: String, status: String, add: Int, del: Int, conflict: String?, renameFrom: String?) {
        self.path = path
        self.status = status
        self.add = add
        self.del = del
        self.conflict = conflict
        self.renameFrom = renameFrom
    }
}

public struct RemoteCommit: Codable, Equatable, Sendable {
    /// Full identity on current peers; absent in older change-list replies.
    public var sha: String? = nil
    public var revision: String { sha ?? shortSha }
    public let shortSha: String
    public let subject: String
    public let author: String
    public let add: Int
    public let del: Int

    public init(sha: String? = nil, shortSha: String, subject: String, author: String, add: Int, del: Int) {
        self.sha = sha
        self.shortSha = shortSha
        self.subject = subject
        self.author = author
        self.add = add
        self.del = del
    }
}

/// Wire projection of `ParsedDiff.Hunk.Line`. `kind` is "context", "add", or
/// "delete"; `text` has no leading +/-/space. `noTrailingNewline` mirrors
/// the source line's `\ No newline at end of file` sentinel, so a diff that
/// only adds/removes a trailing newline doesn't render as two
/// identical-looking lines with no visual distinction.
public struct RemoteDiffLine: Equatable, Sendable {
    public let kind: String
    public let text: String
    public let oldNumber: Int?
    public let newNumber: Int?
    public let noTrailingNewline: Bool

    public init(kind: String, text: String, oldNumber: Int?, newNumber: Int?, noTrailingNewline: Bool = false) {
        self.kind = kind
        self.text = text
        self.oldNumber = oldNumber
        self.newNumber = newNumber
        self.noTrailingNewline = noTrailingNewline
    }
}

extension RemoteDiffLine: Codable {
    private enum CodingKeys: String, CodingKey {
        case kind, text, oldNumber, newNumber, noTrailingNewline
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            kind: try c.decode(String.self, forKey: .kind),
            text: try c.decode(String.self, forKey: .text),
            oldNumber: try c.decodeIfPresent(Int.self, forKey: .oldNumber),
            newNumber: try c.decodeIfPresent(Int.self, forKey: .newNumber),
            // Decoded leniently so an older host that hasn't sent this field
            // yet still decodes (a client ahead of a not-yet-updated host).
            noTrailingNewline: try c.decodeIfPresent(Bool.self, forKey: .noTrailingNewline) ?? false
        )
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(kind, forKey: .kind)
        try c.encode(text, forKey: .text)
        try c.encodeIfPresent(oldNumber, forKey: .oldNumber)
        try c.encodeIfPresent(newNumber, forKey: .newNumber)
        try c.encode(noTrailingNewline, forKey: .noTrailingNewline)
    }
}

/// Wire projection of `ParsedDiff.Hunk`.
public struct RemoteDiffHunk: Codable, Equatable, Sendable {
    public let header: String
    public let oldStart: Int
    public let newStart: Int
    public let lines: [RemoteDiffLine]

    public init(header: String, oldStart: Int, newStart: Int, lines: [RemoteDiffLine]) {
        self.header = header
        self.oldStart = oldStart
        self.newStart = newStart
        self.lines = lines
    }
}

public enum RemoteChangeListResult: Equatable, Sendable {
    case success(
        comparisonRef: String?, metricsAvailable: Bool,
        files: [RemoteChangedFile], staged: [RemoteChangedFile], unstaged: [RemoteChangedFile],
        commits: [RemoteCommit], truncated: Bool, commitsTruncated: Bool = false)
    case failure(reason: RemoteFileAccessReason, message: String?)
}

public enum RemoteCommitFilesResult: Equatable, Sendable {
    case success(files: [RemoteChangedFile], truncated: Bool)
    case failure(reason: RemoteFileAccessReason, message: String?)
}

public enum RemoteFileDiffResult: Equatable, Sendable {
    /// `metadataNote` is set when `hunks` is empty because the change was
    /// metadata-only (a pure rename/copy or executable-bit change with no
    /// content edits) — see `ParsedDiff.metadataSummary`. The client shows
    /// it in place of the hunk viewer instead of rendering a blank diff
    /// that looks indistinguishable from "nothing changed".
    case success(hunks: [RemoteDiffHunk], truncated: Bool, metadataNote: String? = nil)
    case failure(reason: RemoteFileAccessReason, message: String?)
}

public enum RemoteFileTreeResult: Equatable, Sendable {
    case success(nodes: [RemoteFileNode], truncated: Bool)
    case failure(reason: RemoteFileAccessReason, message: String?)
}

public enum RemoteFileContentsResult: Equatable, Sendable {
    case success(text: String, truncated: Bool)
    case failure(reason: RemoteFileAccessReason, byteSize: Int?, message: String?)
}
