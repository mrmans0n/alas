import Foundation

/// Result of the `_alas/context_usage` extension: what fills the context
/// window, as reported by Claude's `getContextUsage`. Every field is optional
/// on the wire; a missing or malformed field decodes as empty instead of
/// failing the whole breakdown.
public struct ACPContextBreakdown: Decodable, Equatable, Sendable {
    public var categories: [Category] = []
    public var maxTokens = 0
    public var memoryFiles: [MemoryFile] = []
    public var mcpTools: [MCPTool] = []
    public var skills: Skills?
    public var agents: [Agent] = []
    public var messageBreakdown: MessageBreakdown?

    public struct Category: Decodable, Equatable, Sendable {
        public let name: String
        public let tokens: Int
        /// Classify on this, never on the English `name`.
        public let kind: Kind

        public enum Kind: String, Decodable, Sendable {
            case used, free, buffer, deferred, unknown

            public init(from decoder: Decoder) throws {
                self = Kind(rawValue: try decoder.singleValueContainer().decode(String.self)) ?? .unknown
            }
        }

        public init(name: String, tokens: Int, kind: Kind) {
            self.name = name
            self.tokens = tokens
            self.kind = kind
        }
    }

    public struct MemoryFile: Decodable, Equatable, Sendable {
        public let path: String
        public let type: String
        public let tokens: Int

        public init(path: String, type: String, tokens: Int) {
            self.path = path
            self.type = type
            self.tokens = tokens
        }
    }

    public struct MCPTool: Decodable, Equatable, Sendable {
        public let name: String
        public let serverName: String
        public let tokens: Int
        public let isLoaded: Bool?

        public init(name: String, serverName: String, tokens: Int, isLoaded: Bool?) {
            self.name = name
            self.serverName = serverName
            self.tokens = tokens
            self.isLoaded = isLoaded
        }
    }

    public struct Skills: Decodable, Equatable, Sendable {
        public let totalSkills: Int
        public let includedSkills: Int
        public let tokens: Int
        public let skillFrontmatter: [Skill]?

        public struct Skill: Decodable, Equatable, Sendable {
            public let name: String
            public let tokens: Int

            public init(name: String, tokens: Int) {
                self.name = name
                self.tokens = tokens
            }
        }

        public init(totalSkills: Int, includedSkills: Int, tokens: Int, skillFrontmatter: [Skill]?) {
            self.totalSkills = totalSkills
            self.includedSkills = includedSkills
            self.tokens = tokens
            self.skillFrontmatter = skillFrontmatter
        }
    }

    public struct Agent: Decodable, Equatable, Sendable {
        public let agentType: String
        public let tokens: Int

        public init(agentType: String, tokens: Int) {
            self.agentType = agentType
            self.tokens = tokens
        }
    }

    public struct MessageBreakdown: Decodable, Equatable, Sendable {
        public let userMessageTokens: Int
        public let assistantMessageTokens: Int
        public let toolCallTokens: Int
        public let toolResultTokens: Int
        public let attachmentTokens: Int

        public init(userMessageTokens: Int, assistantMessageTokens: Int, toolCallTokens: Int, toolResultTokens: Int, attachmentTokens: Int) {
            self.userMessageTokens = userMessageTokens
            self.assistantMessageTokens = assistantMessageTokens
            self.toolCallTokens = toolCallTokens
            self.toolResultTokens = toolResultTokens
            self.attachmentTokens = attachmentTokens
        }
    }

    public init(categories: [Category], maxTokens: Int) {
        self.categories = categories
        self.maxTokens = maxTokens
    }

    private enum CodingKeys: String, CodingKey {
        case categories, maxTokens, memoryFiles, mcpTools, skills, agents, messageBreakdown
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        categories = (try? c.decodeIfPresent([Category].self, forKey: .categories)) ?? []
        maxTokens = (try? c.decodeIfPresent(Int.self, forKey: .maxTokens)) ?? 0
        memoryFiles = (try? c.decodeIfPresent([MemoryFile].self, forKey: .memoryFiles)) ?? []
        mcpTools = (try? c.decodeIfPresent([MCPTool].self, forKey: .mcpTools)) ?? []
        skills = try? c.decodeIfPresent(Skills.self, forKey: .skills)
        agents = (try? c.decodeIfPresent([Agent].self, forKey: .agents)) ?? []
        messageBreakdown = try? c.decodeIfPresent(MessageBreakdown.self, forKey: .messageBreakdown)
    }

    /// One square of the defrag grid: the category it belongs to (index into
    /// `categories`) and how much of the square that category fills, `0...1`.
    public struct GridCell: Equatable, Sendable {
        public let category: Int
        public let fullness: Double

        public init(category: Int, fullness: Double) {
            self.category = category
            self.fullness = fullness
        }
    }

    /// Lays the window out as `squares` cells: `used` categories first in
    /// adapter order, each ending in a partial square, then free space, then
    /// the autocompact buffer at the end. A nonzero category always gets at
    /// least one square. `deferred` and unknown rows sit outside the window
    /// and are not drawn. Free space takes whatever squares remain, so the
    /// grid always has exactly `squares` cells (or none for an empty window).
    public func gridCells(squares: Int = 100) -> [GridCell] {
        guard maxTokens > 0, squares > 0 else { return [] }
        let unit = Double(maxTokens) / Double(squares)
        var cells: [GridCell] = []
        for (index, category) in categories.enumerated() where category.kind == .used && category.tokens > 0 {
            let exact = Double(category.tokens) / unit
            let count = max(1, Int(exact.rounded(.up)))
            let tail = exact - Double(count - 1)
            for square in 0..<count {
                cells.append(GridCell(category: index, fullness: square == count - 1 ? min(1, tail) : 1))
            }
        }
        cells = Array(cells.prefix(squares))
        var buffer: [GridCell] = []
        if let index = categories.firstIndex(where: { $0.kind == .buffer && $0.tokens > 0 }) {
            let count = min(squares - cells.count, Int((Double(categories[index].tokens) / unit).rounded()))
            buffer = Array(repeating: GridCell(category: index, fullness: 1), count: max(0, count))
        }
        let freeIndex = categories.firstIndex { $0.kind == .free } ?? -1
        let freeCount = squares - cells.count - buffer.count
        return cells + Array(repeating: GridCell(category: freeIndex, fullness: 0), count: freeCount) + buffer
    }
}
