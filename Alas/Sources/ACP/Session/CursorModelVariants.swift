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
        let currentVariant = parse(currentModel)
        guard parsed.contains(where: { $0.variant.base == currentVariant.base }) else {
            return Derived(model: nil, thinking: nil)
        }

        // Which attr key represents "thinking" within the current base group?
        // Prefer `effort`; fall back to `thinking`.
        let currentGroup = parsed.filter { $0.variant.base == currentVariant.base }
        let thinkingKey: String? = {
            if currentGroup.contains(where: { $0.variant.attrs.contains(where: { $0.key == "effort" }) }) {
                return "effort"
            }
            if currentGroup.contains(where: { $0.variant.attrs.contains(where: { $0.key == "thinking" }) }) {
                return "thinking"
            }
            return nil
        }()

        let currentThinkingValue = thinkingKey.flatMap { key in
            currentVariant.attrs.first(where: { $0.key == key })?.value
        }

        // Model chip: one item per distinct base, ordered by first appearance.
        // For each base, prefer the variant whose thinking value matches the
        // current selection AND whose other attrs (context, fast, …) best
        // match the current variant — picking the first match would silently
        // change hidden dimensions like context when the user only meant to
        // switch the model.
        var seenBases = Set<String>()
        var modelItems: [ChipSpec.Item] = []
        for (info, variant) in parsed where seenBases.insert(variant.base).inserted {
            let candidates = parsed.filter { p in
                p.variant.base == variant.base
                    && (thinkingKey.map { key in
                        p.variant.attrs.first(where: { $0.key == key })?.value == currentThinkingValue
                    } ?? true)
            }
            let preferred = bestMatch(in: candidates, against: currentVariant,
                                       ignoring: thinkingKey) ?? (info, variant)
            modelItems.append(ChipSpec.Item(
                id: preferred.info.id,
                name: preferred.info.name,
                description: preferred.info.description))
        }
        let model = !modelItems.isEmpty
            ? ChipSpec(source: .model, options: modelItems, currentId: currentModel)
            : nil

        // Thinking chip: one item per distinct thinking value within the
        // current base, ordered by first appearance. For each value, pick
        // the variant id whose non-thinking attrs best match the current
        // variant — same reason as above.
        let thinking: ChipSpec? = {
            guard let thinkingKey else { return nil }
            var seenValues = Set<String>()
            var thinkingItems: [ChipSpec.Item] = []
            for (_, variant) in currentGroup {
                guard let value = variant.attrs.first(where: { $0.key == thinkingKey })?.value,
                      seenValues.insert(value).inserted
                else { continue }
                let candidates = currentGroup.filter { p in
                    p.variant.attrs.first(where: { $0.key == thinkingKey })?.value == value
                }
                guard let pick = bestMatch(in: candidates, against: currentVariant,
                                           ignoring: thinkingKey) else { continue }
                thinkingItems.append(ChipSpec.Item(
                    id: pick.info.id, name: value, description: pick.info.description))
            }
            guard !thinkingItems.isEmpty else { return nil }
            return ChipSpec(source: .model, options: thinkingItems, currentId: currentModel)
        }()

        return Derived(model: model, thinking: thinking)
    }

    /// Pick the candidate whose non-thinking attrs best match `reference`.
    /// Ties resolve to the first candidate in source order (stable). Returns
    /// nil only when `candidates` is empty.
    private static func bestMatch(
        in candidates: [(info: ACPModelInfo, variant: Variant)],
        against reference: Variant,
        ignoring thinkingKey: String?
    ) -> (info: ACPModelInfo, variant: Variant)? {
        candidates.max { a, b in
            attrMatchScore(a.variant, against: reference, ignoring: thinkingKey)
                < attrMatchScore(b.variant, against: reference, ignoring: thinkingKey)
        }
    }

    /// Count attrs in `candidate` whose `(key, value)` also appears in
    /// `reference`, skipping the thinking key itself.
    private static func attrMatchScore(
        _ candidate: Variant,
        against reference: Variant,
        ignoring thinkingKey: String?
    ) -> Int {
        candidate.attrs.reduce(0) { acc, attr in
            if let thinkingKey, attr.key == thinkingKey { return acc }
            let refValue = reference.attrs.first(where: { $0.key == attr.key })?.value
            return acc + (refValue == attr.value ? 1 : 0)
        }
    }
}
