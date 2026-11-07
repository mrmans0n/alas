import CryptoKit
import Foundation

public struct ReviewIdentity: Codable, Equatable, Hashable, Sendable {
    public let host: String
    public let repo: String
    public let number: Int
    public init(host: String, repo: String, number: Int) { self.host = host
    self.repo = repo
    self.number = number }
}

public enum NativeStackAction: String, Codable, CaseIterable, Sendable {
    case open, sync, rebase, land, landThrough
}

public struct NativeStackEntry: Codable, Equatable, Sendable {
    public let id: String
    public let sha: String
    public let position: Int
    public let number: Int?
    public let title: String
    public let state: String?
    public init(id: String, sha: String, position: Int, number: Int? = nil, title: String, state: String? = nil) {
        self.id = id
        self.sha = sha
        self.position = position
        self.number = number
        self.title = title
        self.state = state
    }
}

public struct NativeStack: Codable, Equatable, Sendable {
    public let id: String
    public let name: String
    public let base: String
    public let host: String
    public let repo: String
    public let worktree: String?
    public let fingerprint: String
    public let complete: Bool
    public let entries: [NativeStackEntry]
    public let actions: [NativeStackAction]
    public let unavailableActions: [String: String]?
    /// Saved local or remote membership only; never proves order or heads.
    /// For unmapped local entries, nil means unknown and [] confirms no saved review mapping.
    public let reviewNumbers: [Int]?

    public init(id: String, name: String, base: String, host: String, repo: String, worktree: String? = nil,
                complete: Bool, entries: [NativeStackEntry], actions: [NativeStackAction], unavailableActions: [String: String]? = nil,
                reviewNumbers: [Int]? = nil) {
        self.id = id
        self.name = name
        self.base = base
        self.host = host
        self.repo = repo
        self.worktree = worktree
        self.complete = complete
        self.entries = entries
        self.actions = actions
        self.unavailableActions = unavailableActions
        self.reviewNumbers = reviewNumbers
        struct Scope: Encodable {
            struct Member: Encodable { let id: String
            let sha: String
            let position: Int
            let number: Int? }
            let id: String
            let name: String
            let base: String
            let host: String
            let repo: String
            let worktree: String?
            let members: [Member]
            let reviewNumbers: [Int]?
        }
        let scope = Scope(id: id, name: name, base: base, host: host, repo: repo, worktree: worktree,
                          members: entries.map { .init(id: $0.id, sha: $0.sha, position: $0.position, number: $0.number) },
                          reviewNumbers: reviewNumbers?.sorted())
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        fingerprint = SHA256.hash(data: (try? encoder.encode(scope)) ?? Data()).map { String(format: "%02x", $0) }.joined()
    }

    /// The current worktree proves ordered entries and ownership; discovery membership is
    /// validated separately against the complete server inventory by the action resolver.
    fileprivate var ownerScopeFingerprint: String {
        Self(id: id, name: name, base: base, host: host, repo: repo, worktree: worktree,
             complete: complete, entries: entries, actions: []).fingerprint
    }
}

public struct StackInventory: Codable, Equatable, Sendable {
    public var complete: Bool
    public var busy: Bool
    public var stacks: [NativeStack]
    public var fetchedAt: Double?
    public var error: String?
    /// False only when the host explicitly rules native workflows out for this execution context.
    public var applicable: Bool?
    public init(complete: Bool, busy: Bool, stacks: [NativeStack], fetchedAt: Double? = nil, error: String? = nil, applicable: Bool? = nil) {
        self.complete = complete
        self.busy = busy
        self.stacks = stacks
        self.fetchedAt = fetchedAt
        self.error = error
        self.applicable = applicable
    }
    public static var unavailable: Self { .init(complete: false, busy: false, stacks: [], error: "Native stacks are not available.") }

    /// Incorporates a membership-only discovery row without asserting entry order or heads.
    public mutating func includeDiscoveredStack(_ discovered: NativeStack) {
        guard let index = stacks.firstIndex(where: { $0.id == discovered.id }) else {
            stacks.append(discovered)
            return
        }
        let local = stacks[index]
        guard local.name == discovered.name, local.host == discovered.host, local.repo == discovered.repo else { return }
        let discoveredNumbers = Set(discovered.reviewNumbers ?? [])
        let localNumbers = Set(local.entries.compactMap(\.number)).union(local.reviewNumbers ?? [])
        let contradicted = local.complete && localNumbers != discoveredNumbers
        // A fully mapped owning worktree remains the authority for order, heads, and base.
        guard !local.complete || contradicted else { return }
        var reasons = local.unavailableActions ?? [:]
        if contradicted {
            let reason = "Remote review membership differs from the owning worktree. Refresh native gg before using inbox mutation actions."
            for action in NativeStackAction.allCases where action != .open { reasons[action.rawValue] = reason }
        }
        stacks[index] = NativeStack(id: local.id, name: local.name, base: local.base, host: local.host, repo: local.repo,
                                    worktree: local.worktree, complete: false, entries: local.entries,
                                    actions: contradicted ? local.actions.filter { $0 == .open } : local.actions,
                                    unavailableActions: reasons.isEmpty ? nil : reasons,
                                    reviewNumbers: localNumbers.union(discoveredNumbers).sorted())
    }

    /// Applies the failure-path cache policy after a project-scoped inventory read.
    public func retainingKnownStacks(from cached: StackInventory?) -> Self {
        guard !complete else { return self }
        let reason = error ?? "Native stack inventory is incomplete. Refresh successfully before taking an action."
        func sameIdentity(_ lhs: NativeStack, _ rhs: NativeStack) -> Bool {
            lhs.id == rhs.id && lhs.host == rhs.host && lhs.repo == rhs.repo && lhs.name == rhs.name
        }
        func numbers(_ stack: NativeStack) -> Set<Int> {
            Set(stack.entries.compactMap(\.number)).union(stack.reviewNumbers ?? [])
        }
        func stale(_ stack: NativeStack, id: String? = nil, additionalNumbers: Set<Int> = []) -> NativeStack {
            let known = numbers(stack).union(additionalNumbers).sorted()
            let reasons = Dictionary(uniqueKeysWithValues: NativeStackAction.allCases.map { action in
                var underlying = stack.unavailableActions?[action.rawValue]
                if let oldError = cached?.error, underlying == oldError { underlying = nil }
                if let oldError = cached?.error, let text = underlying, text.hasPrefix(oldError + "\n") {
                    underlying = String(text.dropFirst(oldError.count + 1))
                }
                let message = underlying.map { $0 == reason || $0.hasPrefix(reason + "\n") ? $0 : reason + "\n" + $0 } ?? reason
                return (action.rawValue, message)
            })
            return NativeStack(id: id ?? stack.id, name: stack.name, base: stack.base, host: stack.host, repo: stack.repo,
                               worktree: stack.worktree, complete: false, entries: stack.entries, actions: [],
                               unavailableActions: reasons, reviewNumbers: known.isEmpty ? stack.reviewNumbers : known)
        }
        var retained = stacks.map { current in
            guard let previous = cached?.stacks.first(where: { sameIdentity($0, current) }) else { return stale(current) }
            let lostMembers = !Set(previous.entries.map(\.id)).isSubset(of: Set(current.entries.map(\.id)))
            let lostReviews = !numbers(previous).isSubset(of: numbers(current))
            return stale(lostMembers || lostReviews ? previous : current,
                         additionalNumbers: numbers(previous).union(numbers(current)))
        }
        for previous in cached?.stacks ?? [] where !retained.contains(where: { sameIdentity($0, previous) }) {
            var id = previous.id
            if retained.contains(where: { $0.id == id }) {
                let identity = Data([previous.id, previous.host, previous.repo, previous.name].joined(separator: "\u{0}").utf8)
                id += ":stale:" + SHA256.hash(data: identity).map { String(format: "%02x", $0) }.joined()
            }
            retained.append(stale(previous, id: id))
        }
        return Self(complete: false, busy: busy, stacks: retained.sorted { $0.id < $1.id },
                    fetchedAt: cached?.fetchedAt ?? fetchedAt, error: reason, applicable: applicable)
    }
}

public struct PluginStackListParams: Codable, Sendable { public let refresh: Bool }
public struct PluginStackInventoryResult: Codable, Sendable { public let inventory: StackInventory
public init(inventory: StackInventory) { self.inventory = inventory } }
public struct PluginStackOpenedResult: Codable, Sendable { public let opened: Bool
public init() { opened = true } }
public struct PluginStackAcquireResult: Codable, Sendable { public let token: String
public init(token: String) { self.token = token } }
public struct PluginStackReleaseParams: Codable, Sendable { public let token: String }
public struct PluginStackReleasedResult: Codable, Sendable { public let released: Bool
public init() { released = true } }

public struct PluginStackError: Error, Equatable, LocalizedError, Sendable {
    public let message: String
    public var errorDescription: String? { message }
    public init(_ message: String) { self.message = message }
}

public struct PluginStackOpenParams: Codable, Sendable {
    public let stack: String
    public let fingerprint: String
    public let action: NativeStackAction
    public let entry: String?
    public init(stack: String, fingerprint: String, action: NativeStackAction, entry: String? = nil) {
        self.stack = stack
        self.fingerprint = fingerprint
        self.action = action
        self.entry = entry
    }
    public var isValid: Bool {
        (1...1024).contains(stack.utf8.count) && (1...256).contains(fingerprint.utf8.count)
            && entry.map { (1...1024).contains($0.utf8.count) } != false
            && (action != .landThrough || entry != nil)
    }
    /// Check the published inventory scope before independently verifying its current owning snapshot.
    public func resolve(in inventory: StackInventory, verifyingOwner current: NativeStack) throws -> (stack: NativeStack, entry: NativeStackEntry?) {
        let resolved = try resolve(in: inventory)
        guard current.ownerScopeFingerprint == resolved.stack.ownerScopeFingerprint else { throw PluginStackError("The stack changed. Refresh and try again.") }
        return resolved
    }

    public func resolve(in inventory: StackInventory) throws -> (stack: NativeStack, entry: NativeStackEntry?) {
        guard isValid else { throw PluginStackError("Invalid stack action parameters.") }
        guard let selected = inventory.stacks.first(where: { $0.id == stack }) else { throw PluginStackError("Unknown stack in this project.") }
        guard selected.fingerprint == fingerprint else { throw PluginStackError("The stack changed. Refresh and try again.") }
        guard selected.actions.contains(action) else {
            throw PluginStackError(selected.unavailableActions?[action.rawValue] ?? "This native action is unavailable.")
        }
        if let entry, !selected.entries.contains(where: { $0.id == entry }) { throw PluginStackError("Unknown entry in this stack.") }
        if action != .open {
            guard !inventory.busy else { throw PluginStackError(inventory.error ?? "A project mutation is already running.") }
            guard inventory.complete else { throw PluginStackError(inventory.error ?? "Stack inventory is incomplete. Refresh before taking an action.") }
            if action == .land || action == .landThrough {
                guard selected.complete else { throw PluginStackError("Stack membership is incomplete. Refresh before landing.") }
            }
        }
        let target: NativeStackEntry?
        switch action {
        case .land: target = selected.entries.max(by: { $0.position < $1.position })
        case .landThrough: target = selected.entries.first(where: { $0.id == entry })
        default: target = nil
        }
        if action == .land || action == .landThrough, target == nil { throw PluginStackError("This stack has no landing target.") }
        return (selected, target)
    }
}
