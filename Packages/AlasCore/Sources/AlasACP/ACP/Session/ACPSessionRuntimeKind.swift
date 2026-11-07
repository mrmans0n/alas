public enum ACPSessionRuntimeKind: Equatable, Sendable {
    case v1
    case v2FreshPreview
    case unsupported(String)

    public init(rawValue: String) {
        switch rawValue {
        case "v1": self = .v1
        case "v2FreshPreview": self = .v2FreshPreview
        default: self = .unsupported(rawValue)
        }
    }

    public var rawValue: String {
        switch self {
        case .v1: "v1"
        case .v2FreshPreview: "v2FreshPreview"
        case .unsupported(let value): value
        }
    }
}
