import SwiftUI
import Virtualization

/// A worktree's VM tab: golden image setup, VM creation, start and stop, and
/// the live screen. Closing the tab leaves the VM running.
struct VirtualMachineTabView: View {
    let state: AppState
    let tab: VirtualMachineTabState
    @ObservedObject private var installer: GoldenImageInstaller

    /// Registry and disk facts, read on appear and after actions rather than
    /// on every render: reading the registry takes a file lock.
    @State private var hasVM = false
    @State private var goldenAvailable = false
    @State private var loaded = false

    /// Outcome of the last start request, until the user acts on it.
    @State private var elsewhere: RunningElsewhere?
    @State private var choice: SlotChoice?
    @State private var errorMessage: String?
    @State private var finishingSetup = false

    private struct RunningElsewhere {
        let target: StartTarget
        let label: String
    }

    private struct SlotChoice {
        let target: StartTarget
        let candidates: [String]
    }

    private enum StartTarget {
        case worktree(String)
        case golden(build: String)

        var id: String {
            switch self {
            case .worktree(let id): id
            case .golden(let build): WorktreeVMManager.goldenIDPrefix + build
            }
        }
    }

    /// Thrown when Stop is pressed while the VM boots; the Stopped screen
    /// already says what happened.
    private static let stoppedWhileStartingMessage = "The VM was stopped while it was starting"

    init(state: AppState, tab: VirtualMachineTabState) {
        self.state = state
        self.tab = tab
        _installer = ObservedObject(wrappedValue: state.goldenImageInstaller)
    }

    private var vms: WorktreeVMManager { state.vmManager }
    private var worktreeID: String { tab.ownerKey }

    var body: some View {
        VStack(spacing: 0) {
            if let errorMessage {
                HStack(alignment: .top) {
                    Image(systemName: "exclamationmark.triangle")
                    Text(errorMessage).textSelection(.enabled)
                    Spacer(minLength: 0)
                    Button("Dismiss", systemImage: "xmark") { self.errorMessage = nil }
                        .labelStyle(.iconOnly)
                        .buttonStyle(.borderless)
                }
                .font(.system(size: 12)).padding(10)
                .background(Color.yellow.opacity(0.12))
                Divider()
            }
            VStack(spacing: 0) { content }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .task { refresh() }
        .onChange(of: installer.phase) { _, _ in refresh() }
        .task(id: awaitingSetupBuild) {
            guard let build = awaitingSetupBuild,
                  vms.runningGolden() == nil,
                  !vms.isStarting(StartTarget.golden(build: build).id)
            else { return }
            start(.golden(build: build))
        }
    }

    private var awaitingSetupBuild: String? {
        if case .awaitingSetup(let build) = installer.phase { return build }
        return nil
    }

    @ViewBuilder
    private var content: some View {
        if let running = vms.running(worktreeID) {
            header("Running") {
                Button("Stop") { stop(worktreeID) }
            }
            VMDisplaySurface(view: state.tabs.vmView(ownerKey: worktreeID), virtualMachine: running.vm)
        } else if vms.isStarting(worktreeID) {
            ContentUnavailableView {
                Label("Starting VM", systemImage: "desktopcomputer")
            } description: {
                ProgressView().controlSize(.small)
            } actions: {
                Button("Stop") { stop(worktreeID) }
            }
        } else if let choice {
            choiceView(choice)
        } else if let elsewhere {
            ContentUnavailableView {
                Label("Running in another Alas (\(elsewhere.label))", systemImage: "desktopcomputer")
            } actions: {
                Button("Start") { start(elsewhere.target) }
            }
        } else if let build = awaitingSetupBuild {
            goldenSetupView(build: build)
        } else if !loaded {
            ProgressView().controlSize(.small)
        } else if installerIsBusy || !goldenAvailable {
            setupView
        } else if !hasVM {
            ContentUnavailableView {
                Label("No VM for this worktree", systemImage: "desktopcomputer")
            } actions: {
                Button("Create VM", action: createVM)
                    .buttonStyle(.borderedProminent)
            }
        } else {
            ContentUnavailableView {
                Label("Stopped", systemImage: "desktopcomputer")
            } actions: {
                Button("Start") { start(.worktree(worktreeID)) }
                    .buttonStyle(.borderedProminent)
            }
        }
    }

    private var installerIsBusy: Bool {
        switch installer.phase {
        case .downloading, .installing: true
        default: false
        }
    }

    // MARK: - Screens

    private var setupView: some View {
        ContentUnavailableView {
            Label("Set up a macOS VM", systemImage: "desktopcomputer")
        } description: {
            switch installer.phase {
            case .downloading(let fraction):
                progress("Downloading macOS", fraction: fraction)
            case .installing(let fraction):
                progress("Installing macOS", fraction: fraction)
            case .failed(let message):
                Text(message)
            default:
                EmptyView()
            }
        } actions: {
            if !installerIsBusy {
                Button("Set up") {
                    Task { await installer.start() }
                }
                .buttonStyle(.borderedProminent)
            }
        }
    }

    private func progress(_ title: String, fraction: Double) -> some View {
        VStack(spacing: 6) {
            Text(title)
            ProgressView(value: fraction).frame(width: 240)
        }
    }

    @ViewBuilder
    private func goldenSetupView(build: String) -> some View {
        header("Finish macOS setup, then click Done. Create a user that logs in automatically.") {
            Button("Done", action: finishGoldenSetup)
                .disabled(finishingSetup)
        }
        if let golden = vms.runningGolden() {
            VMDisplaySurface(view: state.tabs.vmView(ownerKey: worktreeID), virtualMachine: golden.vm)
        } else if vms.isStarting(StartTarget.golden(build: build).id) || finishingSetup {
            ProgressView().controlSize(.small)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ContentUnavailableView {
                Label("Stopped", systemImage: "desktopcomputer")
            } actions: {
                Button("Start") { start(.golden(build: build)) }
                    .buttonStyle(.borderedProminent)
            }
        }
    }

    @ViewBuilder
    private func choiceView(_ choice: SlotChoice) -> some View {
        if choice.candidates.isEmpty {
            ContentUnavailableView {
                Label("Both VM slots are in use by another Alas.", systemImage: "desktopcomputer")
            } actions: {
                Button("Cancel") { self.choice = nil }
            }
        } else {
            ContentUnavailableView {
                Label("Both VM slots are busy", systemImage: "desktopcomputer")
            } actions: {
                ForEach(choice.candidates, id: \.self) { candidate in
                    Button("Pause \(displayName(forCandidate: candidate))") {
                        start(choice.target, pausing: candidate)
                    }
                }
                Button("Cancel") { self.choice = nil }
            }
        }
    }

    private func header(_ title: String, @ViewBuilder trailing: () -> some View) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Text(title)
                    .font(.system(size: 12, weight: .medium))
                Spacer(minLength: 0)
                trailing()
            }
            .padding(8)
            Divider()
        }
    }

    private func displayName(forCandidate id: String) -> String {
        if id.hasPrefix(WorktreeVMManager.goldenIDPrefix) { return "macOS setup VM" }
        return state.projectAndWorktree(withWorktreeId: id)?.worktree.title
            ?? URL(fileURLWithPath: id).lastPathComponent
    }

    // MARK: - Actions

    private func refresh() {
        goldenAvailable = GoldenImageInstaller.availableGolden() != nil
        hasVM = vms.hasVM(worktreeID)
        loaded = true
    }

    private func createVM() {
        errorMessage = nil
        do {
            try vms.createVM(worktreeID: worktreeID)
        } catch {
            errorMessage = error.localizedDescription
        }
        refresh()
    }

    private func start(_ target: StartTarget, pausing other: String? = nil) {
        errorMessage = nil
        elsewhere = nil
        choice = nil
        Task {
            do {
                if let other {
                    _ = try await vms.startVM(worktreeID: target.id, pausing: other)
                } else {
                    let outcome = switch target {
                    case .worktree(let id): try await vms.startVM(worktreeID: id)
                    case .golden(let build): try await vms.startGolden(build: build)
                    }
                    switch outcome {
                    case .running:
                        break
                    case .runningElsewhere(let label):
                        elsewhere = RunningElsewhere(target: target, label: label)
                    case .needsUserChoice(let candidates):
                        choice = SlotChoice(target: target, candidates: candidates)
                    }
                }
            } catch {
                if error.localizedDescription != Self.stoppedWhileStartingMessage {
                    errorMessage = error.localizedDescription
                }
            }
            refresh()
        }
    }

    private func stop(_ id: String) {
        Task { await vms.stopVM(worktreeID: id) }
    }

    private func finishGoldenSetup() {
        errorMessage = nil
        finishingSetup = true
        Task {
            await vms.stopGolden()
            do {
                try installer.markSetupDone()
            } catch {
                errorMessage = error.localizedDescription
            }
            finishingSetup = false
            refresh()
        }
    }
}
