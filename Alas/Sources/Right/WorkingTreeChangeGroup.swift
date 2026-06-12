import Foundation

enum WorkingTreeStageState: Equatable {
    case unstaged
    case staged
    case mixed
}

struct WorkingTreeChangeGroup: Identifiable, Equatable {
    let path: String
    let entries: [ChangedFile]

    var id: String { path }

    var stagedEntries: [ChangedFile] {
        entries.filter { $0.stage == .staged }
    }

    var unstagedEntries: [ChangedFile] {
        entries.filter { $0.stage == .unstaged }
    }

    var stageState: WorkingTreeStageState {
        switch (stagedEntries.isEmpty, unstagedEntries.isEmpty) {
        case (false, false): return .mixed
        case (false, true):  return .staged
        default:             return .unstaged
        }
    }

    var primaryEntry: ChangedFile {
        let primary = unstagedEntries.first ?? entries[0]
        guard
            primary.renameFrom == nil,
            let renameFrom = entries.first(where: { $0.status == "R" && $0.renameFrom != nil })?.renameFrom
        else {
            return primary
        }
        return ChangedFile(
            path: primary.path,
            status: primary.status,
            stage: primary.stage,
            add: primary.add,
            del: primary.del,
            renameFrom: renameFrom,
            conflict: primary.conflict
        )
    }

    var add: Int {
        entries.map(\.add).max() ?? 0
    }

    var del: Int {
        entries.map(\.del).max() ?? 0
    }

    static func group(files: [ChangedFile]) -> [WorkingTreeChangeGroup] {
        Dictionary(grouping: files, by: \.path)
            .map { path, entries in
                WorkingTreeChangeGroup(
                    path: path,
                    entries: entries.sorted { lhs, rhs in
                        lhs.stage.rawValue.localizedStandardCompare(rhs.stage.rawValue) == .orderedAscending
                    }
                )
            }
            .sorted { lhs, rhs in
                lhs.path.localizedStandardCompare(rhs.path) == .orderedAscending
            }
    }
}

extension Array where Element == WorkingTreeChangeGroup {
    func groups(under folder: String) -> [WorkingTreeChangeGroup] {
        let prefix = folder.hasSuffix("/") ? folder : folder + "/"
        return filter { $0.path.hasPrefix(prefix) }
    }

    func stagedEntries(under folder: String) -> [ChangedFile] {
        groups(under: folder).flatMap(\.stagedEntries)
    }

    func unstagedEntries(under folder: String) -> [ChangedFile] {
        groups(under: folder).flatMap(\.unstagedEntries)
    }
}
