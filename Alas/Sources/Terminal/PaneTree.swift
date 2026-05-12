// PaneTree.swift
// Recursive split-tree model for terminal tabs.
//
// A `.terminal` tab's `root` is a single `PaneNode`. Leaves reference live
// `TerminalSession`s by `sessionId`; splits hold a fraction (0…1, size of the
// first child along the axis) and two children. Tree mutations are pure on the
// data; session lifetime is managed by `TerminalService`.

import Foundation

enum SplitAxis: String, Codable, Equatable {
    // horizontal: divider runs horizontally → children stacked top/bottom (Split Down).
    // vertical:   divider runs vertically   → children side-by-side       (Split Right).
    case horizontal
    case vertical
}

struct PaneLeaf: Codable, Equatable, Identifiable {
    let id: String
    var sessionId: String
    var lastCwd: String?
}

struct PaneSplit: Codable, Equatable, Identifiable {
    let id: String
    var axis: SplitAxis
    var fraction: Double
    /// v1 always contains exactly two children. The array type leaves room for
    /// future N-way splits; `removingLeaf` already collapses single-child splits
    /// so callers never observe a degenerate 0/1-child state.
    var children: [PaneNode]
}

enum PaneNode: Codable, Equatable, Identifiable {
    case leaf(PaneLeaf)
    case split(PaneSplit)

    var id: String {
        switch self {
        case .leaf(let l):  return l.id
        case .split(let s): return s.id
        }
    }

    private enum CodingKeys: String, CodingKey { case kind }
    private enum Kind: String, Codable { case leaf, split }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try container.decode(Kind.self, forKey: .kind)
        let single = try decoder.singleValueContainer()
        switch kind {
        case .leaf:
            self = .leaf(try single.decode(PaneLeafCodable.self).asLeaf)
        case .split:
            self = .split(try single.decode(PaneSplitCodable.self).asSplit)
        }
    }

    func encode(to encoder: Encoder) throws {
        var single = encoder.singleValueContainer()
        switch self {
        case .leaf(let l):
            try single.encode(PaneLeafCodable(kind: .leaf, id: l.id, sessionId: l.sessionId, lastCwd: l.lastCwd))
        case .split(let s):
            try single.encode(PaneSplitCodable(
                kind: .split, id: s.id, axis: s.axis, fraction: s.fraction, children: s.children
            ))
        }
    }
}

// MARK: - Codable wire shapes

private struct PaneLeafCodable: Codable {
    enum Kind: String, Codable { case leaf }
    let kind: Kind
    let id: String
    let sessionId: String
    let lastCwd: String?

    var asLeaf: PaneLeaf {
        PaneLeaf(id: id, sessionId: sessionId, lastCwd: lastCwd)
    }
}

private struct PaneSplitCodable: Codable {
    enum Kind: String, Codable { case split }
    let kind: Kind
    let id: String
    let axis: SplitAxis
    let fraction: Double
    let children: [PaneNode]

    var asSplit: PaneSplit {
        PaneSplit(id: id, axis: axis, fraction: fraction, children: children)
    }
}

// MARK: - Tree helpers

extension PaneNode {
    /// Left-to-right, top-to-bottom traversal of every leaf in render order.
    func leaves() -> [PaneLeaf] {
        switch self {
        case .leaf(let l):  return [l]
        case .split(let s): return s.children.flatMap { $0.leaves() }
        }
    }

    /// The leftmost / topmost leaf — used as a focus fallback.
    func firstLeaf() -> PaneLeaf {
        switch self {
        case .leaf(let l):  return l
        case .split(let s): return s.children[0].firstLeaf()
        }
    }

    /// Locate a leaf by id and return the path of containing split ids.
    /// Path is empty when the root itself is the leaf.
    func find(leafId: String) -> (path: [String], leaf: PaneLeaf)? {
        switch self {
        case .leaf(let l):
            return l.id == leafId ? (path: [], leaf: l) : nil
        case .split(let s):
            for child in s.children {
                if let inner = child.find(leafId: leafId) {
                    return (path: [s.id] + inner.path, leaf: inner.leaf)
                }
            }
            return nil
        }
    }

    /// Replace the leaf with the given id by `replacement` anywhere in the tree.
    /// If no leaf matches, returns the tree unchanged.
    func replacingLeaf(id: String, with replacement: PaneNode) -> PaneNode {
        switch self {
        case .leaf(let l):
            return l.id == id ? replacement : self
        case .split(var s):
            s.children = s.children.map { $0.replacingLeaf(id: id, with: replacement) }
            return .split(s)
        }
    }

    /// Remove the leaf with `id`. If a parent split is left with a single child,
    /// collapse the split up to that child. Returns nil if removing this leaf
    /// would leave the tree empty.
    func removingLeaf(id: String) -> PaneNode? {
        switch self {
        case .leaf(let l):
            return l.id == id ? nil : self
        case .split(var s):
            var newChildren: [PaneNode] = []
            for child in s.children {
                if let kept = child.removingLeaf(id: id) {
                    newChildren.append(kept)
                }
            }
            if newChildren.isEmpty { return nil }
            if newChildren.count == 1 { return newChildren[0] }
            s.children = newChildren
            return .split(s)
        }
    }
}

// MARK: - Focus-by-direction

enum PaneFocusDirection { case left, right, up, down }

enum PaneFocusFinder {
    /// Find the nearest leaf in `direction` from the source leaf.
    /// Returns nil if no candidate exists (e.g. source is at the edge or unknown).
    static func nearestLeaf(
        from sourceId: String,
        direction: PaneFocusDirection,
        frames: [String: CGRect]
    ) -> String? {
        guard let source = frames[sourceId] else { return nil }
        let candidates = frames.filter { id, rect in
            guard id != sourceId else { return false }
            return isInDirection(source: source, candidate: rect, direction: direction)
                && hasPerpendicularOverlap(source: source, candidate: rect, direction: direction)
        }
        return candidates.min(by: { lhs, rhs in
            distance(source: source, target: lhs.value, direction: direction)
                < distance(source: source, target: rhs.value, direction: direction)
        })?.key
    }

    private static func isInDirection(source: CGRect, candidate: CGRect, direction: PaneFocusDirection) -> Bool {
        switch direction {
        case .left:  return candidate.midX < source.midX
        case .right: return candidate.midX > source.midX
        case .up:    return candidate.midY < source.midY
        case .down:  return candidate.midY > source.midY
        }
    }

    private static func hasPerpendicularOverlap(source: CGRect, candidate: CGRect, direction: PaneFocusDirection) -> Bool {
        switch direction {
        case .left, .right:
            return max(source.minY, candidate.minY) < min(source.maxY, candidate.maxY)
        case .up, .down:
            return max(source.minX, candidate.minX) < min(source.maxX, candidate.maxX)
        }
    }

    private static func distance(source: CGRect, target: CGRect, direction: PaneFocusDirection) -> CGFloat {
        switch direction {
        case .left, .right:
            return abs(target.midX - source.midX)
        case .up, .down:
            return abs(target.midY - source.midY)
        }
    }
}
