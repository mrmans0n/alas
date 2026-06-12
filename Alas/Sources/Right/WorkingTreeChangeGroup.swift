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
        unstagedEntries.first ?? entries[0]
    }

    var add: Int {
        entries.reduce(0) { $0 + $1.add }
    }

    var del: Int {
        entries.reduce(0) { $0 + $1.del }
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
