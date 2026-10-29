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
    @State private var record = WorktreeVMManager.RecordStatus()
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

    init(state: AppState, tab: VirtualMachineTabState) {
        self.state = state
        self.tab = tab
        _installer = ObservedObject(wrappedValue: state.goldenImageInstaller)
    }

    private var vms: WorktreeVMManager { state.vmManager }
    private var worktreeID: String { tab.ownerKey }

    private var screen: VMTabScreen {
        VMTabScreen.resolve(
            runningHere: vms.running(worktreeID) != nil,
            startingHere: vms.isStarting(worktreeID),
            slotChoice: choice?.candidates,
            runningElsewhere: elsewhere?.label ?? record.runningElsewhere,
            loaded: loaded,
            hasVM: record.hasVM,
            goldenAvailable: goldenAvailable,
            installerPhase: installer.phase
        )
    }

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
        .task(id: awaitingSetupBuild) {
            refresh()
            autoStartGoldenOnce()
        }
        // Progress ticks change the phase constantly; only a change of kind
        // can change what the registry or disk say.
        .onChange(of: phaseKind) { _, _ in refresh() }
    }

    private var awaitingSetupBuild: String? {
        if case .awaitingSetup(let build) = installer.phase { return build }
        return nil
    }

    private var phaseKind: String {
        switch installer.phase {
        case .idle: "idle"
        case .downloading: "downloading"
        case .installing: "installing"
        case .awaitingSetup(let build): "awaiting:\(build)"
        case .sealed(let build): "sealed:\(build)"
        case .failed: "failed"
        }
    }

    @ViewBuilder
    private var content: some View {
        switch screen {
        case .running:
            header("Running") {
                Button("Stop") { stop(worktreeID) }
            }
            VMDisplaySurface(view: state.tabs.vmView(ownerKey: worktreeID), virtualMachine: vms.running(worktreeID)?.vm)
        case .starting:
            ContentUnavailableView {
                Label("Starting VM", systemImage: "desktopcomputer")
            } description: {
                ProgressView().controlSize(.small)
            } actions: {
                Button("Stop") { stop(worktreeID) }
            }
        case .slotChoice:
            if let choice { choiceView(choice) }
        case .runningElsewhere(let label):
            ContentUnavailableView {
                Label("Running in another Alas (\(label))", systemImage: "desktopcomputer")
            } actions: {
                Button("Start") { start(elsewhere?.target ?? .worktree(worktreeID)) }
            }
        case .goldenSetup(let build):
            goldenSetupView(build: build)
        case .loading:
            ProgressView().controlSize(.small)
        case .setup:
            setupView
        case .createVM:
            ContentUnavailableView {
                Label("No VM for this worktree", systemImage: "desktopcomputer")
            } actions: {
                Button("Create VM", action: createVM)
                    .buttonStyle(.borderedProminent)
            }
        case .stopped:
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
            Button("Done") { finishGoldenSetup(build: build) }
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
        // Another Alas process may have sealed or replaced the golden image.
        installer.reloadFromDisk()
        goldenAvailable = vms.availableGolden() != nil
        record = vms.recordStatus(worktreeID)
        loaded = true
    }

    /// Boots the golden VM by itself once per setup; afterwards the Start
    /// button does.
    private func autoStartGoldenOnce() {
        guard case .goldenSetup(let build) = screen,
              vms.runningGolden() == nil,
              !vms.isStarting(StartTarget.golden(build: build).id),
              vms.claimGoldenAutoStart(build: build)
        else { return }
        start(.golden(build: build))
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
            } catch is WorktreeVMManager.StoppedWhileStarting {
                // Stop was pressed during boot; the Stopped screen says so.
            } catch {
                errorMessage = error.localizedDescription
            }
            refresh()
        }
    }

    private func stop(_ id: String) {
        Task { await vms.stopVM(worktreeID: id) }
    }

    /// Seals the golden image only after macOS shut itself down; a VM that
    /// had to be forced off may have an inconsistent disk.
    private func finishGoldenSetup(build: String) {
        errorMessage = nil
        finishingSetup = true
        Task {
            switch await vms.shutDownGoldenForSealing(build: build) {
            case .clean:
                do {
                    try installer.markSetupDone()
                } catch {
                    errorMessage = error.localizedDescription
                }
            case .stillRunning:
                errorMessage = "Shut down macOS from the Apple menu, then click Done."
            case .forcedOff:
                errorMessage = "macOS was powered off without shutting down. Start it, shut down macOS from the Apple menu, then click Done."
            }
            finishingSetup = false
            refresh()
        }
    }
}
