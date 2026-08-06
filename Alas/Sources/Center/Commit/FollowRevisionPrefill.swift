enum FollowRevisionPrefill {
    static func expression(displayedSHA: String, firstParentSHAs: [String]) -> String? {
        guard let offset = firstParentSHAs.firstIndex(of: displayedSHA) else { return nil }
        return offset == 0 ? "HEAD" : "HEAD~\(offset)"
    }
}
