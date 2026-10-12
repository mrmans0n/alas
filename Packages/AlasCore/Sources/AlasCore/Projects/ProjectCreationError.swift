import Foundation

public enum ProjectCreationError: LocalizedError, Equatable, Sendable {
    case projectPersistenceFailed
    case projectAlreadyExists
    case projectNotFound

    public var errorDescription: String? {
        switch self {
        case .projectPersistenceFailed:
            "Could not save the new project."
        case .projectAlreadyExists:
            "A project with this ID already exists."
        case .projectNotFound:
            "The project no longer exists."
        }
    }
}
