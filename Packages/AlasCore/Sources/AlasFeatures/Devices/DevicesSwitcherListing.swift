import Foundation

public struct DevicesSwitcherSection: Equatable, Sendable, Identifiable {
    public enum Kind: Hashable, Sendable { case running, runtime(String), simulatorsNote, android, vms }

    public let kind: Kind
    public let title: String
    public let rows: [DevicesTabState.Row]
    /// The simulators or Android note; only with an empty query.
    public let note: String?
    public var id: Kind { kind }
}

public struct DevicesSwitcherListing: Equatable, Sendable {
    public let sections: [DevicesSwitcherSection]
    /// Runtime groups folded away; 0 when nothing is folded.
    public let foldedRuntimeCount: Int
}

extension DevicesTabState {
    /// The switcher's sections: running devices first, then simulators by
    /// runtime (newest first), Android and VMs. `query` keeps the rows whose
    /// text contains every word of it.
    public func switcherListing(query: String, showsOlderRuntimes: Bool) -> DevicesSwitcherListing {
        let tokens = query.lowercased().split(whereSeparator: \.isWhitespace).map(String.init)
        let filtering = !tokens.isEmpty
        func matching(_ rows: [Row]) -> [Row] {
            guard filtering else { return rows }
            return rows.filter { row in
                let haystack = "\(row.title) \(row.detail) \(row.status) \(Self.platformWord(row.platform))".lowercased()
                return tokens.allSatisfy(haystack.contains)
            }
        }
        func isRunning(_ row: Row) -> Bool { row.tone == .live || row.tone == .busy }

        let simulators = matching(simulatorRows)
        let android = matching(androidRows)
        let vms = matching(vmRows)
        var sections: [DevicesSwitcherSection] = []

        let running = (simulators + android + vms).filter(isRunning)
        if !running.isEmpty {
            sections.append(DevicesSwitcherSection(kind: .running, title: "Running", rows: running, note: nil))
        }

        var groups: [(name: String, rows: [Row])] = []
        for row in simulators where !isRunning(row) {
            if let index = groups.firstIndex(where: { $0.name == row.detail }) {
                groups[index].rows.append(row)
            } else {
                groups.append((row.detail, [row]))
            }
        }
        groups = groups.enumerated().sorted { lhs, rhs in
            let (l, r) = (Self.runtimeVersion(lhs.element.name), Self.runtimeVersion(rhs.element.name))
            return l == r ? lhs.offset < rhs.offset : Self.isDescending(l, r)
        }.map(\.element)

        var folded = 0
        if !filtering, !showsOlderRuntimes, groups.count > 1 {
            let kept = groups.enumerated().filter { index, group in
                index == 0 || group.rows.contains { $0.target == lastUsed }
            }.map(\.element)
            folded = groups.count - kept.count
            groups = kept
        }
        sections += groups.map {
            DevicesSwitcherSection(kind: .runtime($0.name), title: $0.name, rows: $0.rows, note: nil)
        }

        if !filtering, simulatorRows.isEmpty, let simulatorsNote {
            sections.append(
                DevicesSwitcherSection(kind: .simulatorsNote, title: "iOS simulators", rows: [], note: simulatorsNote)
            )
        }

        let idleAndroid = android.filter { !isRunning($0) }
        let androidNote = filtering ? nil : androidNote
        if !idleAndroid.isEmpty || androidNote != nil {
            sections.append(
                DevicesSwitcherSection(kind: .android, title: "Android", rows: idleAndroid, note: androidNote)
            )
        }
        let idleVMs = vms.filter { !isRunning($0) }
        if !idleVMs.isEmpty {
            sections.append(DevicesSwitcherSection(kind: .vms, title: "This worktree's VMs", rows: idleVMs, note: nil))
        }
        return DevicesSwitcherListing(sections: sections, foldedRuntimeCount: folded)
    }

    private static func platformWord(_ platform: DevicesPlatform) -> String {
        switch platform {
        case .ios: "ios simulator"
        case .android: "android"
        case .vm(let guest): guest == .macOS ? "vm macos" : "vm linux"
        }
    }

    /// "iOS 26.5" is [26, 5]; a name without a version is empty and sorts last.
    private static func runtimeVersion(_ name: String) -> [Int] {
        guard let last = name.split(separator: " ").last else { return [] }
        let parts = last.split(separator: ".").map { Int($0) }
        return parts.contains(nil) ? [] : parts.compactMap { $0 }
    }

    /// True when `lhs` is the newer version; component-wise, empty last.
    private static func isDescending(_ lhs: [Int], _ rhs: [Int]) -> Bool {
        if lhs.isEmpty || rhs.isEmpty { return !lhs.isEmpty }
        return lhs.lexicographicallyPrecedes(rhs) == false
    }
}
