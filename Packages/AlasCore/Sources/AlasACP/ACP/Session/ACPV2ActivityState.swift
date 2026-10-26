import Foundation
import AlasCode

/// Identified v2 activity values. These effects never execute commands,
/// change foreground state, acknowledge delivery, or mutate the app's storage.
public struct ACPV2ActivityState: Sendable {
    public typealias Context = ACPV2MessageTranscript.Context

    public enum Key: Hashable, Sendable {
        case toolCall(String), plan(String), terminal(String)
    }

    public struct ToolCall: Equatable, Sendable {
        public let toolCallID: String
        public fileprivate(set) var name: String?
        public fileprivate(set) var title: String?
        public fileprivate(set) var kind: String? = "other"
        public fileprivate(set) var status: String? = "pending"
        public fileprivate(set) var content: [ACPV2SessionUpdateEnvelope.ToolContent] = []
        public fileprivate(set) var locations: [LSPJSONValue] = []
        public fileprivate(set) var rawInput: LSPJSONValue?
        public fileprivate(set) var rawOutput: LSPJSONValue?
        public fileprivate(set) var metadata: [String: LSPJSONValue] = [:]
    }

    /// Agent-reported display data, deliberately independent of process-backed
    /// terminal hosts and their execution APIs. Missing exit information is unknown.
    public struct DisplayTerminal: Equatable, Sendable {
        public let terminalID: String
        public fileprivate(set) var command: String?
        public fileprivate(set) var cwd: String?
        public fileprivate(set) var output = Data()
        public fileprivate(set) var snapshotMetadata: [String: LSPJSONValue]?
        public fileprivate(set) var exitStatus: ACPV2SessionUpdateEnvelope.ExitInformation?
        public fileprivate(set) var metadata: [String: LSPJSONValue] = [:]
    }

    public enum Effect: Equatable, Sendable {
        case toolCallChanged(ToolCall)
        case planChanged(ACPV2SessionUpdateEnvelope.PlanUpdate)
        case terminalChanged(DisplayTerminal)
    }

    public struct Reduction: Equatable, Sendable {
        public enum Disposition: Equatable, Sendable { case applied, unhandled, staleContext }
        public let event: ACPV2SessionUpdateEnvelope
        public let disposition: Disposition
        public let effects: [Effect]
    }

    public let context: Context
    public private(set) var order: [Key] = []
    private var tools: [String: ToolCall] = [:]
    private var plans: [String: ACPV2SessionUpdateEnvelope.PlanUpdate] = [:]
    private var terminals: [String: DisplayTerminal] = [:]

    public init(context: Context) { self.context = context }

    public func toolCall(id: String) -> ToolCall? { tools[id] }
    public func plan(id: String) -> ACPV2SessionUpdateEnvelope.PlanUpdate? { plans[id] }
    public func terminal(id: String) -> DisplayTerminal? { terminals[id] }

    @discardableResult
    public mutating func apply(_ event: ACPV2SessionUpdateEnvelope, context: Context) -> Reduction {
        guard context == self.context, event.sessionID == context.sessionID else {
            return Reduction(event: event, disposition: .staleContext, effects: [])
        }
        let effects: [Effect]
        switch event.payload {
        case .toolCall(let patch):
            var tool = tools[patch.toolCallID] ?? ToolCall(toolCallID: patch.toolCallID)
            tool.name = patch.name.applying(to: tool.name)
            tool.title = patch.title.applying(to: tool.title)
            tool.kind = patch.kind.applying(to: tool.kind)
            tool.status = patch.status.applying(to: tool.status)
            tool.content = patch.content.applying(to: tool.content, cleared: [])
            tool.locations = patch.locations.applying(to: tool.locations, cleared: [])
            tool.rawInput = patch.rawInput.applying(to: tool.rawInput)
            tool.rawOutput = patch.rawOutput.applying(to: tool.rawOutput)
            tool.metadata = patch.metadata.applying(to: tool.metadata)
            effects = save(tool)
        case .toolContentChunk(let chunk):
            var tool = tools[chunk.toolCallID] ?? ToolCall(toolCallID: chunk.toolCallID)
            tool.content.append(chunk.content)
            effects = save(tool)
        case .plan(let plan):
            if plans[plan.planID] == plan { effects = [] }
            else {
                if plans[plan.planID] == nil { order.append(.plan(plan.planID)) }
                plans[plan.planID] = plan
                effects = [.planChanged(plan)]
            }
        case .terminal(let patch):
            var terminal = terminals[patch.terminalID] ?? DisplayTerminal(terminalID: patch.terminalID)
            terminal.command = patch.command.applying(to: terminal.command)
            terminal.cwd = patch.cwd.applying(to: terminal.cwd)
            switch patch.output {
            case .omitted: break
            case .clear:
                terminal.output = Data()
                terminal.snapshotMetadata = nil
            case .value(let snapshot):
                terminal.output = snapshot.data
                terminal.snapshotMetadata = snapshot.metadata
            }
            terminal.exitStatus = patch.exitStatus.applying(to: terminal.exitStatus)
            terminal.metadata = patch.metadata.applying(to: terminal.metadata)
            effects = save(terminal)
        case .terminalOutputChunk(let chunk):
            let isNew = terminals[chunk.terminalID] == nil
            if isNew { order.append(.terminal(chunk.terminalID)) }
            if isNew || !chunk.data.isEmpty {
                // Mutate the owned buffer directly rather than retaining an old
                // value that forces a whole-buffer copy for every byte chunk.
                terminals[chunk.terminalID, default: DisplayTerminal(terminalID: chunk.terminalID)].output.append(chunk.data)
                effects = terminals[chunk.terminalID].map { [.terminalChanged($0)] } ?? []
            } else { effects = [] }
        default:
            return Reduction(event: event, disposition: .unhandled, effects: [])
        }
        return Reduction(event: event, disposition: .applied, effects: effects)
    }

    private mutating func save(_ tool: ToolCall) -> [Effect] {
        let old = tools[tool.toolCallID]
        var effects: [Effect] = []
        if old != tool {
            if old == nil { order.append(.toolCall(tool.toolCallID)) }
            tools[tool.toolCallID] = tool
            effects.append(.toolCallChanged(tool))
        }
        for content in tool.content {
            if let id = content.terminalID, terminals[id] == nil {
                effects += save(DisplayTerminal(terminalID: id))
            }
        }
        return effects
    }

    private mutating func save(_ terminal: DisplayTerminal) -> [Effect] {
        let old = terminals[terminal.terminalID]
        guard old != terminal else { return [] }
        if old == nil { order.append(.terminal(terminal.terminalID)) }
        terminals[terminal.terminalID] = terminal
        return [.terminalChanged(terminal)]
    }
}
