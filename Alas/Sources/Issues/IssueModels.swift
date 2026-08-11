import Foundation

enum CodeHostIssueState: String, Codable, Equatable, Sendable {
    case open
    case closed
    case unknown
}

struct CodeHostIssueIdentity: Codable, Equatable, Sendable {
    let provider: CodeHostKind
    let host: String
    let repositorySlug: String
    let number: Int

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.provider == rhs.provider
            && lhs.host.caseInsensitiveCompare(rhs.host) == .orderedSame
            && lhs.repositorySlug.caseInsensitiveCompare(rhs.repositorySlug) == .orderedSame
            && lhs.number == rhs.number
    }
}

struct CodeHostIssueSnapshot: Codable, Equatable, Sendable {
    let identity: CodeHostIssueIdentity
    let canonicalURL: URL
    let title: String
    let body: String
    let state: CodeHostIssueState
    let labels: [String]
    let assignees: [String]
    let providerUpdatedAt: Date?
    let capturedAt: Date
    var refreshError: String?

    init(
        identity: CodeHostIssueIdentity,
        canonicalURL: URL,
        title: String,
        body: String,
        state: CodeHostIssueState,
        labels: [String],
        assignees: [String],
        providerUpdatedAt: Date?,
        capturedAt: Date,
        refreshError: String?
    ) {
        self.identity = identity
        self.canonicalURL = canonicalURL
        self.title = title
        self.body = body
        self.state = state
        self.labels = labels
        self.assignees = assignees
        self.providerUpdatedAt = providerUpdatedAt
        self.capturedAt = capturedAt
        self.refreshError = refreshError
    }

    init?(source: IssueSnapshot) {
        guard let repositoryLocator = source.repositoryLocator,
              let displayReference = source.displayReference,
              displayReference.first == "#",
              let number = Int(displayReference.dropFirst())
        else {
            return nil
        }

        self.init(
            identity: .init(
                provider: repositoryLocator.provider,
                host: repositoryLocator.host,
                repositorySlug: repositoryLocator.repositorySlug,
                number: number
            ),
            canonicalURL: source.canonicalURL,
            title: source.title,
            body: source.body,
            state: .init(rawValue: source.state.rawValue) ?? .unknown,
            labels: source.labels,
            assignees: source.assignees,
            providerUpdatedAt: source.providerUpdatedAt,
            capturedAt: source.capturedAt,
            refreshError: source.refreshError
        )
    }
}

struct IssueProviderID: RawRepresentable, Codable, Hashable, Sendable {
    let rawValue: String

    static let github = Self(rawValue: "github")
    static let gitlab = Self(rawValue: "gitlab")
    static let manual = Self(rawValue: "manual")
}

struct IssueIdentity: Codable, Hashable, Sendable {
    let providerID: IssueProviderID
    let stableID: String
}

enum IssueContentOrigin: String, Codable, Equatable, Sendable {
    case provider
    case manual
}

enum IssueState: String, Codable, Equatable, Sendable {
    case open
    case closed
    case unknown
}

struct IssueRepositoryLocator: Codable, Equatable, Sendable {
    let provider: CodeHostKind
    let host: String
    let repositorySlug: String
}

struct IssueSnapshot: Codable, Equatable, Sendable {
    let identity: IssueIdentity
    let canonicalURL: URL
    let providerLabel: String
    let displayReference: String?
    let repositoryLocator: IssueRepositoryLocator?
    let title: String
    let body: String
    let state: IssueState
    let labels: [String]
    let assignees: [String]
    let providerUpdatedAt: Date?
    let capturedAt: Date
    var refreshError: String?
    let contentOrigin: IssueContentOrigin
    let isEditable: Bool
    let isRefreshable: Bool

    init(
        identity: IssueIdentity,
        canonicalURL: URL,
        providerLabel: String,
        displayReference: String?,
        repositoryLocator: IssueRepositoryLocator?,
        title: String,
        body: String,
        state: IssueState,
        labels: [String],
        assignees: [String],
        providerUpdatedAt: Date?,
        capturedAt: Date,
        refreshError: String?,
        contentOrigin: IssueContentOrigin,
        isEditable: Bool,
        isRefreshable: Bool
    ) {
        self.identity = identity
        self.canonicalURL = canonicalURL
        self.providerLabel = providerLabel
        self.displayReference = displayReference
        self.repositoryLocator = repositoryLocator
        self.title = title
        self.body = body
        self.state = state
        self.labels = labels
        self.assignees = assignees
        self.providerUpdatedAt = providerUpdatedAt
        self.capturedAt = capturedAt
        self.refreshError = refreshError
        self.contentOrigin = contentOrigin
        self.isEditable = isEditable
        self.isRefreshable = isRefreshable
    }

    init(codeHostIssue issue: CodeHostIssueSnapshot) {
        let providerID: IssueProviderID = switch issue.identity.provider {
        case .github: .github
        case .gitlab: .gitlab
        }
        self.init(
            identity: .init(
                providerID: providerID,
                stableID: "\(issue.identity.host)/\(issue.identity.repositorySlug)#\(issue.identity.number)".lowercased()
            ),
            canonicalURL: issue.canonicalURL,
            providerLabel: issue.identity.provider.displayName,
            displayReference: "#\(issue.identity.number)",
            repositoryLocator: .init(
                provider: issue.identity.provider,
                host: issue.identity.host,
                repositorySlug: issue.identity.repositorySlug
            ),
            title: issue.title,
            body: issue.body,
            state: .init(rawValue: issue.state.rawValue) ?? .unknown,
            labels: issue.labels,
            assignees: issue.assignees,
            providerUpdatedAt: issue.providerUpdatedAt,
            capturedAt: issue.capturedAt,
            refreshError: issue.refreshError,
            contentOrigin: .provider,
            isEditable: false,
            isRefreshable: true
        )
    }
}
