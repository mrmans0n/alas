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
        var seenBases = Set<String>()
        var modelItems: [ChipSpec.Item] = []
        for (info, variant) in parsed where seenBases.insert(variant.base).inserted {
            // Pick the variant for this base whose thinking value matches the
            // user's current selection; else any variant from this base.
            let preferred = parsed.first(where: { p in
                p.variant.base == variant.base
                    && (thinkingKey.map { key in
                        p.variant.attrs.first(where: { $0.key == key })?.value == currentThinkingValue
                    } ?? true)
            }) ?? (info, variant)
            modelItems.append(ChipSpec.Item(
                id: preferred.info.id,
                name: preferred.info.name,
                description: preferred.info.description))
        }
        let model = modelItems.count > 0
            ? ChipSpec(source: .model, options: modelItems, currentId: currentModel)
            : nil

        // Thinking chip: one item per distinct thinking value within the
        // current base, ordered by first appearance.
        let thinking: ChipSpec? = {
            guard let thinkingKey else { return nil }
            var seenValues = Set<String>()
            var thinkingItems: [ChipSpec.Item] = []
            for (info, variant) in currentGroup {
                guard let value = variant.attrs.first(where: { $0.key == thinkingKey })?.value,
                      seenValues.insert(value).inserted
                else { continue }
                thinkingItems.append(ChipSpec.Item(
                    id: info.id, name: value, description: info.description))
            }
            guard !thinkingItems.isEmpty else { return nil }
            return ChipSpec(source: .model, options: thinkingItems, currentId: currentModel)
        }()

        return Derived(model: model, thinking: thinking)
    }
}
