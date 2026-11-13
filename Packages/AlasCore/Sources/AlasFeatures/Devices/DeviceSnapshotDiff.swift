import Foundation

/// What changed between an agent's previous snapshot of a simulator and a new
/// one. Elements still on screen keep their previous refs, so refs the agent
/// holds keep working.
public struct DeviceSnapshotDiff: Sendable {
    public struct Change: Equatable, Sendable {
        public let ref: String
        /// `value` or `enabled`.
        public let field: String
        public let from: String?
        public let to: String?

        public init(ref: String, field: String, from: String?, to: String?) {
            self.ref = ref
            self.field = field
            self.from = from
            self.to = to
        }
    }

    /// The new snapshot, with matched elements under their previous refs.
    public let snapshot: DeviceSnapshot
    /// Fewer than half of the new elements were there before, or nothing was:
    /// the agent gets the whole screen instead of a diff.
    public let screenChanged: Bool
    public let added: [DeviceElement]
    public let removed: [DeviceElement]
    public let changed: [Change]

    /// Elements match by role, id and label; ones with the same key pair in
    /// snapshot order. Frames don't count, so scrolling isn't a change.
    public init(previous: DeviceSnapshot?, next: DeviceSnapshot) {
        struct Key: Hashable {
            let role: String
            let id: String?
            let label: String?
        }
        func key(_ element: DeviceElement) -> Key { Key(role: element.role, id: element.id, label: element.label) }
        var unmatched: [Key: [DeviceElement]] = [:]
        for element in previous?.elements ?? [] { unmatched[key(element), default: []].append(element) }
        var carried: [DeviceElement] = []
        var added: [DeviceElement] = []
        var changed: [Change] = []
        var matched = 0
        for element in next.elements {
            guard var candidates = unmatched[key(element)], !candidates.isEmpty else {
                carried.append(element)
                added.append(element)
                continue
            }
            let old = candidates.removeFirst()
            unmatched[key(element)] = candidates
            matched += 1
            if old.value != element.value {
                changed.append(Change(ref: old.ref, field: "value", from: old.value, to: element.value))
            }
            if old.enabled != element.enabled {
                changed.append(Change(ref: old.ref, field: "enabled", from: String(old.enabled), to: String(element.enabled)))
            }
            carried.append(element.withRef(old.ref))
        }
        let screenChanged = previous == nil || matched * 2 < next.elements.count
        self.screenChanged = screenChanged
        snapshot = screenChanged ? next : DeviceSnapshot(
            generation: next.generation, screenWidth: next.screenWidth, screenHeight: next.screenHeight, elements: carried
        )
        self.added = screenChanged ? [] : added
        self.removed = screenChanged ? [] : (previous?.elements ?? []).filter { unmatched[key($0)]?.contains($0) == true }
        self.changed = screenChanged ? [] : changed
    }

    /// The reply: the whole screen when it changed, else what was added,
    /// removed and changed; each list keeps at most `limit` entries.
    public func json(limit: Int = 200) -> [String: Any] {
        var truncated = false
        func capped<T>(_ items: [T]) -> [T] {
            if items.count > limit { truncated = true }
            return Array(items.prefix(limit))
        }
        var reply: [String: Any]
        if screenChanged {
            reply = [
                "screen_changed": true,
                "screen": snapshot.screenJSON,
                "elements": capped(snapshot.elements).map(DeviceSnapshot.elementJSON),
            ]
        } else {
            reply = [
                "added": capped(added).map(DeviceSnapshot.elementJSON),
                "removed": capped(removed).map { element -> [String: Any] in
                    var entry: [String: Any] = ["ref": element.ref, "role": element.role]
                    if let label = element.label { entry["label"] = label }
                    return entry
                },
                "changed": capped(changed).map { change -> [String: Any] in
                    var entry: [String: Any] = ["ref": change.ref, "field": change.field]
                    if let from = change.from { entry["from"] = from }
                    if let to = change.to { entry["to"] = to }
                    return entry
                },
            ]
        }
        if truncated { reply["truncated"] = true }
        return reply
    }
}
