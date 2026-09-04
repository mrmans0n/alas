import Foundation

/// Mutable Workspace definition only. Existing checkout snapshots are not an
/// input to this model, so a definition save cannot alter them.
struct WorkspaceDefinitionDialogModel: Equatable {
    var name: String
    var executionLocation: ExecutionLocation { didSet { removeIneligibleMembers() } }
    private(set) var members: [WorkspaceMember]
    let projects: [ProjectConfig]
    private let editingWorkspace: Workspace?

    init(name: String = "", executionLocation: ExecutionLocation, projects: [ProjectConfig]) {
        self.name = name
        self.executionLocation = executionLocation.normalized
        self.members = []
        self.projects = projects
        self.editingWorkspace = nil
    }

    init(editing workspace: Workspace, projects: [ProjectConfig]) {
        self.name = workspace.name
        self.executionLocation = workspace.executionLocation
        self.members = workspace.members
        self.projects = projects
        self.editingWorkspace = workspace
    }

    var trimmedName: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }
    var saveTitle: String { editingWorkspace == nil ? "Create Workspace" : "Save for Future Checkouts" }

    var eligibleProjects: [ProjectConfig] {
        projects.filter { project in
            Self.location(of: project) == executionLocation && !members.contains(where: { $0.projectID == project.id })
        }
    }

    @discardableResult
    mutating func add(project: ProjectConfig) -> Bool {
        guard Self.location(of: project) == executionLocation, !members.contains(where: { $0.projectID == project.id }) else { return false }
        members.append(.init(projectID: project.id, fallbackProjectName: project.name, fallbackRepositoryRoot: project.path))
        return true
    }

    mutating func removeMember(id: UUID) { members.removeAll { $0.id == id } }

    mutating func moveMember(from source: Int, to destination: Int) {
        guard members.indices.contains(source), (0...members.count).contains(destination) else { return }
        let member = members.remove(at: source)
        members.insert(member, at: min(destination, members.count))
    }

    func definition(now: Date = .now) -> Workspace {
        Workspace(
            id: editingWorkspace?.id ?? UUID(), name: trimmedName, executionLocation: executionLocation,
            createdAt: editingWorkspace?.createdAt ?? now, updatedAt: now, members: members,
            configuration: editingWorkspace?.configuration ?? .init()
        )
    }

    private mutating func removeIneligibleMembers() {
        let availableProjects = projects
        let location = executionLocation
        members.removeAll { member in
            guard let project = availableProjects.first(where: { $0.id == member.projectID }) else { return true }
            return Self.location(of: project) != location
        }
    }

    private static func location(of project: ProjectConfig) -> ExecutionLocation { project.host.map(ExecutionLocation.ssh) ?? .local }
}
