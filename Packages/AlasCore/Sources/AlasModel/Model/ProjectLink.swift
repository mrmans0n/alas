import AlasFoundation

/// Matches an SSH project to the local project with the same git origin.
public enum ProjectLink {
    /// The id of the one local project whose origin names the same repository
    /// as `remoteOrigin`. Nil when none or several match: two local clones of
    /// one repository are not guessed between.
    public static func match(remoteOrigin: String, locals: [(id: String, origin: String?)]) -> String? {
        guard let identity = GitRemoteIdentity.normalized(remoteOrigin) else { return nil }
        let matches = locals.filter { $0.origin.flatMap(GitRemoteIdentity.normalized) == identity }
        return matches.count == 1 ? matches[0].id : nil
    }
}
