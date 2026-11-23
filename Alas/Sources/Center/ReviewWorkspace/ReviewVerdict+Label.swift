extension ReviewVerdict {
    /// How review headers, banners and the Reviews list show the verdict.
    var displayLabel: String {
        switch self {
        case .approve: "Approved"
        case .requestChanges: "Changes requested"
        case .comment: "Commented"
        }
    }
}
