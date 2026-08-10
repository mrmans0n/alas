import Foundation

struct CommitDetails: Equatable {
    let info: CommitInfo
    let body: String          // commit message minus the subject line; "" if none
    let authorEmail: String
    let parents: [String]     // full shas of parent commits, in git order
    let files: [CommitChangedFile]
}

struct CommitChangedFile: Identifiable, Equatable, Hashable {
    var id: String { path }
    let path: String              // for renames, this is the new path
    let originalPath: String?     // for renames/copies, the original path; nil otherwise
    let status: String            // single letter: A, M, D, R, C, T
    let add: Int                  // 0 for binary files
    let del: Int                  // 0 for binary files
}
