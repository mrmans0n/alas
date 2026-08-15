import Foundation
import Observation

@Observable
@MainActor
final class IssueAutocompleteModel {
    enum State: Equatable {
        case idle
        case loading
        case loaded([CodeHostIssueSuggestion])
        case failed(String)
    }

    typealias Load = @Sendable (String, Int) async throws -> [CodeHostIssueSuggestion]

    private(set) var state: State = .idle
    private(set) var reference = ""
    private(set) var selectedIndex = 0
    private(set) var dismissedReference: String?
    private var projectID: String?
    private var generation = 0
    private var task: Task<Void, Never>?
    private let load: Load

    init(load: @escaping Load) {
        self.load = load
    }

    var filteredSuggestions: [CodeHostIssueSuggestion] {
        guard case .loaded(let suggestions) = state,
              let query = Self.query(in: reference)
        else {
            return []
        }
        guard !query.isEmpty else { return suggestions }
        let numeric = query.allSatisfy(\.isNumber)
        return suggestions.filter {
            (numeric && String($0.number).hasPrefix(query))
                || $0.title.localizedCaseInsensitiveContains(query)
        }
    }

    var isPresented: Bool {
        Self.query(in: reference) != nil && dismissedReference != reference
    }

    static func query(in reference: String) -> String? {
        guard reference.hasPrefix("#") else { return nil }
        return String(reference.dropFirst()).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func referenceChanged(_ reference: String, projectID: String) {
        let referenceChanged = self.reference != reference
        let projectChanged = self.projectID != projectID

        self.reference = reference
        selectedIndex = 0

        if referenceChanged {
            dismissedReference = nil
        }

        if projectChanged {
            task?.cancel()
            task = nil
            generation &+= 1
            self.projectID = projectID
            state = .idle
        }

        guard Self.query(in: reference) != nil else { return }
        guard state == .idle else { return }

        startLoad(projectID: projectID)
    }

    func moveSelection(_ delta: Int) {
        guard !filteredSuggestions.isEmpty else {
            selectedIndex = 0
            return
        }
        let lastIndex = filteredSuggestions.count - 1
        selectedIndex = min(lastIndex, max(0, selectedIndex + delta))
    }

    func acceptSelection() -> String? {
        let suggestions = filteredSuggestions
        guard suggestions.indices.contains(selectedIndex) else { return nil }
        let accepted = "#\(suggestions[selectedIndex].number)"
        reference = accepted
        selectedIndex = 0
        dismiss()
        return accepted
    }

    func dismiss() {
        dismissedReference = reference
    }

    func cancel() {
        task?.cancel()
        task = nil
        generation &+= 1
        state = .idle
    }

    func waitForCurrentLoadForTesting() async {
        await task?.value
    }

    private func startLoad(projectID: String) {
        generation &+= 1
        let capturedGeneration = generation
        state = .loading

        task = Task { [load] in
            do {
                let suggestions = try await load(projectID, 50)
                guard !Task.isCancelled,
                      self.accepts(capturedGeneration, projectID: projectID)
                else {
                    return
                }
                self.state = .loaded(suggestions)
            } catch {
                guard !Task.isCancelled,
                      self.accepts(capturedGeneration, projectID: projectID)
                else {
                    return
                }
                self.state = .failed(error.localizedDescription)
            }
        }
    }

    private func accepts(_ capturedGeneration: Int, projectID: String) -> Bool {
        generation == capturedGeneration && self.projectID == projectID
    }
}
