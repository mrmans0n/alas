import Foundation

public enum CodeHostIssueState: String, Codable, Equatable, Sendable {
    case open
    case closed
    case unknown
}

public struct CodeHostIssueIdentity: Codable, Equatable, Sendable {
    public let provider: CodeHostKind
    public let host: String
    public let repositorySlug: String
    public let number: Int

    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.provider == rhs.provider
            && lhs.host.caseInsensitiveCompare(rhs.host) == .orderedSame
            && lhs.repositorySlug.caseInsensitiveCompare(rhs.repositorySlug) == .orderedSame
            && lhs.number == rhs.number
    }

    public init(provider: CodeHostKind, host: String, repositorySlug: String, number: Int) {
        self.provider = provider
        self.host = host
        self.repositorySlug = repositorySlug
        self.number = number
    }
}

public struct CodeHostIssueSnapshot: Codable, Equatable, Sendable {
    public let identity: CodeHostIssueIdentity
    public let canonicalURL: URL
    public let title: String
    public let body: String
    public let state: CodeHostIssueState
    public let labels: [String]
    public let assignees: [String]
    public let providerUpdatedAt: Date?
    public let capturedAt: Date
    public var refreshError: String?
    public let nativeType: String?

    public init(
        identity: CodeHostIssueIdentity,
        canonicalURL: URL,
        title: String,
        body: String,
        state: CodeHostIssueState,
        labels: [String],
        assignees: [String],
        providerUpdatedAt: Date?,
        capturedAt: Date,
        refreshError: String?,
        nativeType: String? = nil
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
        self.nativeType = nativeType
    }

    public init?(source: IssueSnapshot) {
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
            refreshError: source.refreshError,
            nativeType: source.nativeType
        )
    }
}

public struct IssueProviderID: RawRepresentable, Codable, Hashable, Sendable {
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    public static let github = Self(rawValue: "github")
    public static let gitlab = Self(rawValue: "gitlab")
    public static let manual = Self(rawValue: "manual")
}

public struct IssueIdentity: Codable, Hashable, Sendable {
    public let providerID: IssueProviderID
    public let stableID: String

    public init(providerID: IssueProviderID, stableID: String) {
        self.providerID = providerID
        self.stableID = stableID
    }
}

public enum IssueContentOrigin: String, Codable, Equatable, Sendable {
    case provider
    case manual
}

public enum IssueState: String, Codable, Equatable, Sendable {
    case open
    case closed
    case unknown
}

public struct IssueRepositoryLocator: Codable, Equatable, Sendable {
    public let provider: CodeHostKind
    public let host: String
    public let repositorySlug: String

    public init(provider: CodeHostKind, host: String, repositorySlug: String) {
        self.provider = provider
        self.host = host
        self.repositorySlug = repositorySlug
    }
}

public struct IssueSnapshot: Codable, Equatable, Sendable {
    public let identity: IssueIdentity
    public let canonicalURL: URL
    public let providerLabel: String
    public let displayReference: String?
    public let repositoryLocator: IssueRepositoryLocator?
    public let title: String
    public let body: String
    public let state: IssueState
    public let labels: [String]
    public let assignees: [String]
    public let providerUpdatedAt: Date?
    public let capturedAt: Date
    public var refreshError: String?
    public let contentOrigin: IssueContentOrigin
    public let isEditable: Bool
    public let isRefreshable: Bool
    public let nativeType: String?

    public init(
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
        isRefreshable: Bool,
        nativeType: String? = nil
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
        self.nativeType = nativeType
    }

    public init(codeHostIssue issue: CodeHostIssueSnapshot) {
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
            isRefreshable: true,
            nativeType: issue.nativeType
        )
    }
}
