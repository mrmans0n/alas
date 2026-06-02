import Foundation

/// Cursor ACP encodes thinking/effort/context as bracket-suffixed model
/// variant ids — e.g. `claude-opus-4-6[thinking=true,context=200k,effort=high,fast=false]`.
/// Cursor does NOT advertise a `thought_level` configOption; thinking is
/// purely a function of which variant the client selects via
/// `session/set_model`. This file parses that wire shape so we can derive
/// orthogonal Model + Thinking chips client-side.
///
/// Pure functions: no I/O, no SwiftUI imports. The overlay that decides
/// *whether* to use this lives in `ACPChipState.normalize`.
enum CursorModelVariants {
    struct Variant {
        var base: String
        /// Ordered key/value pairs. Order is preserved so `compose` round-trips.
        var attrs: [(key: String, value: String)]
    }

    /// Parse a variant id. Ids without a `[…]` suffix return the whole
    /// string as `base` with empty attrs. Malformed suffixes (no closing
    /// `]`) are treated the same way — better to surface the raw id than
    /// drop it.
    static func parse(_ id: String) -> Variant {
        guard let open = id.firstIndex(of: "["),
              id.last == "]" else {
            return Variant(base: id, attrs: [])
        }
        let base = String(id[..<open])
        let inner = id[id.index(after: open)..<id.index(before: id.endIndex)]
        let attrs: [(String, String)] = inner.split(separator: ",").compactMap { frag in
            let parts = frag.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard parts.count == 2 else { return nil }
            return (String(parts[0]), String(parts[1]))
        }
        return Variant(base: base, attrs: attrs)
    }

    /// Inverse of `parse`. With empty `attrs`, returns `base` unchanged.
    static func compose(base: String, attrs: [(key: String, value: String)]) -> String {
        guard !attrs.isEmpty else { return base }
        let inner = attrs.map { "\($0.key)=\($0.value)" }.joined(separator: ",")
        return "\(base)[\(inner)]"
    }
}

extension CursorModelVariants {
    struct Derived: Equatable {
        var model: ChipSpec?
        var thinking: ChipSpec?
    }

    /// Build orthogonal Model + Thinking chips from Cursor's variant list.
    /// Both chips dispatch via `session/set_model` (item ids are full variant
    /// strings). Returns `(nil, nil)` when there's nothing variant-shaped to
    /// derive — the caller falls back to whatever the standard normalization
    /// produced.
    static func derive(
        availableModels: [ACPModelInfo],
        currentModel: String?
    ) -> Derived {
        guard let currentModel,
              availableModels.contains(where: { $0.id.contains("[") })
        else { return Derived(model: nil, thinking: nil) }

        let parsed: [(info: ACPModelInfo, variant: Variant)] = availableModels.map {
            ($0, parse($0.id))
        }
        // Require an exact match — a stale `currentModel` whose base happens
        // to overlap with the advertised list would otherwise produce chips
        // whose `currentId` is not one of their options.
        guard parsed.contains(where: { $0.info.id == currentModel }) else {
            return Derived(model: nil, thinking: nil)
        }
        let currentVariant = parse(currentModel)

        // The "thinking" axis can be expressed two ways within the same base
        // group: `effort=low|medium|high` for graded thinking, and
        // `thinking=true|false` for on/off. A real-world Cursor variant set
        // can mix them — e.g. `[thinking=false]` (off, no effort attr) plus
        // `[thinking=true,effort=high]` (on, graded). We pick a per-variant
        // label that takes effort when present and falls back to the thinking
        // value, so both dimensions stay reachable in the chip.
        let currentGroup = parsed.filter { $0.variant.base == currentVariant.base }
        let currentThinkingLabel = thinkingLabel(of: currentVariant)

        // Model chip: one item per distinct base, ordered by first appearance.
        // For each base, prefer the variant whose thinking label matches the
        // current selection AND whose other attrs (context, fast, …) best
        // match the current variant — picking the first match would silently
        // change hidden dimensions like context when the user only meant to
        // switch the model. Fall back to any variant of that base when no
        // candidate carries the current thinking label.
        var seenBases = Set<String>()
        var modelItems: [ChipSpec.Item] = []
        for (info, variant) in parsed where seenBases.insert(variant.base).inserted {
            let sameBase = parsed.filter { $0.variant.base == variant.base }
            let matching = sameBase.filter { thinkingLabel(of: $0.variant) == currentThinkingLabel }
            let pool = matching.isEmpty ? sameBase : matching
            let preferred = bestMatch(in: pool, against: currentVariant) ?? (info, variant)
            modelItems.append(ChipSpec.Item(
                id: preferred.info.id,
                name: preferred.info.name,
                description: preferred.info.description))
        }
        let model = !modelItems.isEmpty
            ? ChipSpec(source: .model, options: modelItems, currentId: currentModel)
            : nil

        // Thinking chip: one item per distinct thinking label within the
        // current base, ordered by first appearance. For each label, pick
        // the variant id whose non-thinking attrs best match the current
        // variant. A variant with no thinking/effort attr at all has no
        // label and is skipped.
        var seenLabels = Set<String>()
        var thinkingItems: [ChipSpec.Item] = []
        for (_, variant) in currentGroup {
            guard let label = thinkingLabel(of: variant),
                  seenLabels.insert(label).inserted
            else { continue }
            let candidates = currentGroup.filter { thinkingLabel(of: $0.variant) == label }
            guard let pick = bestMatch(in: candidates, against: currentVariant) else { continue }
            thinkingItems.append(ChipSpec.Item(
                id: pick.info.id, name: label, description: pick.info.description))
        }
        let thinking = !thinkingItems.isEmpty
            ? ChipSpec(source: .model, options: thinkingItems, currentId: currentModel)
            : nil

        return Derived(model: model, thinking: thinking)
    }

    /// The label representing this variant's thinking axis. Cursor uses two
    /// conventions: `effort=…` for graded thinking and `thinking=…` for
    /// on/off. Effort wins when both are present on the same variant.
    /// Returns nil when neither attr is set.
    private static func thinkingLabel(of variant: Variant) -> String? {
        if let v = variant.attrs.first(where: { $0.key == "effort" })?.value { return v }
        if let v = variant.attrs.first(where: { $0.key == "thinking" })?.value { return v }
        return nil
    }

    /// Pick the candidate whose non-thinking attrs best match `reference`.
    /// Ties resolve to the first candidate in source order (stable). Returns
    /// nil only when `candidates` is empty.
    private static func bestMatch(
        in candidates: [(info: ACPModelInfo, variant: Variant)],
        against reference: Variant
    ) -> (info: ACPModelInfo, variant: Variant)? {
        candidates.max { a, b in
            attrMatchScore(a.variant, against: reference)
                < attrMatchScore(b.variant, against: reference)
        }
    }

    /// Count attrs in `candidate` whose `(key, value)` also appears in
    /// `reference`, ignoring both thinking-axis keys.
    private static func attrMatchScore(
        _ candidate: Variant,
        against reference: Variant
    ) -> Int {
        let thinkingKeys: Set<String> = ["effort", "thinking"]
        return candidate.attrs.reduce(0) { acc, attr in
            if thinkingKeys.contains(attr.key) { return acc }
            let refValue = reference.attrs.first(where: { $0.key == attr.key })?.value
            return acc + (refValue == attr.value ? 1 : 0)
        }
    }
}
