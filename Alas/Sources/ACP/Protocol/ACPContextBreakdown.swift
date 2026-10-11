import Foundation

/// Result of the `_alas/context_usage` extension: what fills the context
/// window, as reported by Claude's `getContextUsage`. Every field is optional
/// on the wire; a missing or malformed field decodes as empty instead of
/// failing the whole breakdown.
struct ACPContextBreakdown: Decodable, Equatable {
    var categories: [Category] = []
    var maxTokens = 0
    var memoryFiles: [MemoryFile] = []
    var mcpTools: [MCPTool] = []
    var skills: Skills?
    var agents: [Agent] = []
    var messageBreakdown: MessageBreakdown?

    struct Category: Decodable, Equatable {
        let name: String
        let tokens: Int
        /// Classify on this, never on the English `name`.
        let kind: Kind

        enum Kind: String, Decodable {
            case used, free, buffer, deferred, unknown

            init(from decoder: Decoder) throws {
                self = Kind(rawValue: try decoder.singleValueContainer().decode(String.self)) ?? .unknown
            }
        }
    }

    struct MemoryFile: Decodable, Equatable {
        let path: String
        let type: String
        let tokens: Int
    }

    struct MCPTool: Decodable, Equatable {
        let name: String
        let serverName: String
        let tokens: Int
        let isLoaded: Bool?
    }

    struct Skills: Decodable, Equatable {
        let totalSkills: Int
        let includedSkills: Int
        let tokens: Int
        let skillFrontmatter: [Skill]?

        struct Skill: Decodable, Equatable {
            let name: String
            let tokens: Int
        }
    }

    struct Agent: Decodable, Equatable {
        let agentType: String
        let tokens: Int
    }

    struct MessageBreakdown: Decodable, Equatable {
        let userMessageTokens: Int
        let assistantMessageTokens: Int
        let toolCallTokens: Int
        let toolResultTokens: Int
        let attachmentTokens: Int
    }

    init(categories: [Category], maxTokens: Int) {
        self.categories = categories
        self.maxTokens = maxTokens
    }

    private enum CodingKeys: String, CodingKey {
        case categories, maxTokens, memoryFiles, mcpTools, skills, agents, messageBreakdown
    }

    init(from decoder: Decoder) throws {
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
    struct GridCell: Equatable {
        let category: Int
        let fullness: Double
    }

    /// Lays the window out as `squares` cells: `used` categories first in
    /// adapter order, each ending in a partial square, then free space, then
    /// the autocompact buffer at the end. A nonzero category always gets at
    /// least one square. `deferred` and unknown rows sit outside the window
    /// and are not drawn. Free space takes whatever squares remain, so the
    /// grid always has exactly `squares` cells (or none for an empty window).
    func gridCells(squares: Int = 100) -> [GridCell] {
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
