func shouldShowChangeSummary(additions: Int, deletions: Int) -> Bool {
    additions > 0 || deletions > 0
}
