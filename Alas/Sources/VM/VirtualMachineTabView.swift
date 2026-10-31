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
    @State private var confirmingCustomize = false
    /// A Stop of the VM running here is in progress.
    @State private var stopping = false
    /// The VM whose Update helper awaits confirmation.
    @State private var confirmingHelperUpdate: String?

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
            customizingHere: vms.customizingFrom == worktreeID,
            goldenAvailable: goldenAvailable,
            installerPhase: installer.phase,
            helper: helperUpdate(worktreeID),
            goldenHelper: customizedGoldenID.map(helperUpdate) ?? .none
        )
    }

    private func helperUpdate(_ id: String) -> VMTabScreen.HelperUpdate {
        if vms.updatingHelpers.contains(id) { return .updating }
        return vms.helpersNeedingUpdate.contains(id) ? .available : .none
    }

    /// The golden awaiting setup when Customize reopened it. A golden
    /// awaiting its first setup has no `alas` account or helper to update.
    private var customizedGoldenID: String? {
        guard let build = awaitingSetupBuild, vms.isGoldenCustomized(build: build) else { return nil }
        return StartTarget.golden(build: build).id
    }

    /// The VM running here whose helper this tab checks: its own, or the
    /// customized golden it shows setup for.
    private var helperCheckTarget: String? {
        switch screen {
        case .running: worktreeID
        case .goldenSetup:
            customizedGoldenID.flatMap { vms.running($0) != nil ? $0 : nil }
        default: nil
        }
    }

    /// The error to show: this tab's own, else a failed helper update of a VM it shows.
    private var bannerMessage: String? {
        errorMessage ?? vms.helperUpdateFailures[worktreeID]
            ?? awaitingSetupBuild.flatMap { vms.helperUpdateFailures[StartTarget.golden(build: $0).id] }
    }

    var body: some View {
        VStack(spacing: 0) {
            if screen != .loading { statusBar }
            if let bannerMessage {
                VMCallout(message: bannerMessage, onDismiss: dismissBanner)
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
        .task(id: helperCheckTarget) { await checkHelper(helperCheckTarget) }
        .alert("Customize the base image?", isPresented: $confirmingCustomize) {
            Button("Customize", action: customizeBaseImage)
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("New VMs will use your changes. Existing VMs are not affected.")
        }
        .alert("Update the helper?", isPresented: Binding(
            get: { confirmingHelperUpdate != nil },
            set: { if !$0 { confirmingHelperUpdate = nil } }
        ), presenting: confirmingHelperUpdate) { id in
            Button("Update") { updateHelper(id) }
            Button("Cancel", role: .cancel) {}
        } message: { _ in
            Text("This restarts the VM; unsaved work inside it is lost.")
        }
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
        case .provisioning(let step): "provisioning:\(step)"
        case .awaitingSetup(let build): "awaiting:\(build)"
        case .sealed(let build): "sealed:\(build)"
        case .failed: "failed"
        }
    }

    // MARK: - Status bar

    @ViewBuilder
    private var statusBar: some View {
        switch screen {
        case .running(let canUpdateHelper):
            VMStatusBar(
                tone: stopping ? .busy : .running,
                title: stopping ? "Stopping" : "Running",
                details: canUpdateHelper ? ["helper needs an update"] : []
            ) {
                ToolbarBtn(icon: "stop.fill", tooltip: "Stop VM", metrics: .vmStatusBar) { stop(worktreeID) }
                    .vmDisabled(stopping)
                overflowMenu(updateHelper: canUpdateHelper ? worktreeID : nil)
            }
        case .starting:
            VMStatusBar(tone: .busy, title: "Starting")
        case .slotChoice:
            VMStatusBar(tone: .attention, title: "No VM slot free")
        case .runningElsewhere(let label):
            VMStatusBar(tone: .running, title: "Running in \(label)")
        case .goldenSetup(let build, let canUpdateHelper):
            goldenStatusBar(build: build, canUpdateHelper: canUpdateHelper)
        case .updatingHelper:
            VMStatusBar(tone: .busy, title: "Updating the helper")
        case .loading:
            EmptyView()
        case .setup:
            setupStatusBar
        case .createVM:
            VMStatusBar(tone: .off, title: "No VM")
        case .stopped:
            VMStatusBar(tone: .off, title: "Stopped") {
                overflowMenu(customize: canCustomize)
            }
        case .stoppedWhileCustomizing:
            VMStatusBar(tone: .off, title: "Stopped", details: ["base image being customized"])
        }
    }

    @ViewBuilder
    private var setupStatusBar: some View {
        switch installer.phase {
        case .downloading(let fraction):
            VMStatusBar(tone: .busy, title: "Preparing macOS", details: ["downloading \(percent(fraction))"])
        case .installing(let fraction):
            VMStatusBar(tone: .busy, title: "Preparing macOS", details: ["installing \(percent(fraction))"])
        case .provisioning:
            VMStatusBar(tone: .busy, title: "Preparing macOS")
        case .failed:
            VMStatusBar(tone: .attention, title: "Needs attention")
        case .idle, .sealed, .awaitingSetup:
            VMStatusBar(tone: .off, title: "No base image")
        }
    }

    private func goldenStatusBar(build: String, canUpdateHelper: Bool) -> some View {
        let customized = vms.isGoldenCustomized(build: build)
        let running = vms.runningGolden() != nil
        let tone: VMStatusTone = installer.failureNote != nil ? .attention : running ? .running : .off
        let title = customized ? "Customizing the base image"
            : installer.failureNote != nil ? "Needs attention" : "Setting up macOS"
        return VMStatusBar(tone: tone, title: title, details: ["macOS \(build)", running ? "running" : "off"]) {
            overflowMenu(updateHelper: canUpdateHelper ? StartTarget.golden(build: build).id : nil)
                .vmDisabled(finishingSetup)
        }
    }

    private func percent(_ fraction: Double) -> String {
        "\(Int((min(max(fraction, 0), 1) * 100).rounded()))%"
    }

    /// The ⋯ menu of rare actions; nothing when none applies.
    @ViewBuilder
    private func overflowMenu(updateHelper id: String? = nil, customize: Bool = false) -> some View {
        if id != nil || customize {
            ToolbarMenuButton(
                iconName: "ellipsis", metrics: .vmStatusBar, restingColorToken: "fg-muted", help: "More VM actions"
            ) {
                if let id {
                    Button("Update helper…") { confirmingHelperUpdate = id }
                }
                if customize {
                    Button("Customize base image…") { confirmingCustomize = true }
                }
            }
        }
    }

    // MARK: - Screens

    @ViewBuilder
    private var content: some View {
        switch screen {
        case .running:
            VMDisplaySurface(view: state.tabs.vmView(ownerKey: worktreeID), virtualMachine: vms.running(worktreeID)?.vm)
        case .starting:
            VMEmptyStateCard(icon: "desktopcomputer", title: "Starting the VM", subtitle: "macOS is booting.", busy: true) {
                EmptyView()
            } actions: {
                AlasButton(title: "Stop") { stop(worktreeID) }
            }
        case .slotChoice:
            if let choice { choiceView(choice) }
        case .runningElsewhere(let label):
            VMEmptyStateCard(
                icon: "desktopcomputer", title: "Running in another Alas",
                subtitle: "\(label) is running this VM. Stop it there to use it here."
            ) {
                EmptyView()
            } actions: {
                AlasButton(title: "Start VM", icon: "play.fill", style: .primary) {
                    start(elsewhere?.target ?? .worktree(worktreeID))
                }
            }
        case .goldenSetup(let build, _):
            goldenSetupView(build: build)
        case .updatingHelper:
            VMEmptyStateCard(
                icon: "desktopcomputer", title: "Updating the helper",
                subtitle: "The VM restarts with the new helper.", busy: true)
        case .loading:
            Spinner().frame(width: 16, height: 16)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .setup:
            setupView
        case .createVM:
            VMEmptyStateCard(
                icon: "desktopcomputer", title: "No VM for this worktree",
                subtitle: "Create one from the base image. Agents can drive it with computer use while your desktop stays untouched."
            ) {
                EmptyView()
            } actions: {
                AlasButton(title: "Create VM", icon: "plus", style: .primary, action: createVM)
            }
        case .stopped:
            VMEmptyStateCard(
                icon: "desktopcomputer", title: "This worktree's VM is off",
                subtitle: "Agents can drive it with computer use once it's running. Your desktop stays untouched."
            ) {
                EmptyView()
            } actions: {
                AlasButton(title: "Start VM", icon: "play.fill", style: .primary) { start(.worktree(worktreeID)) }
            }
        case .stoppedWhileCustomizing:
            VMEmptyStateCard(
                icon: "desktopcomputer", title: "This worktree's VM is off",
                subtitle: "The base image is being customized. Finish customizing it here, or start this VM."
            ) {
                EmptyView()
            } actions: {
                AlasButton(title: "Start VM", icon: "play.fill", style: .primary) { start(.worktree(worktreeID)) }
                AlasButton(title: "Finish customizing") { vms.finishCustomizing(from: worktreeID) }
            }
        }
    }

    /// Only with a sealed golden settled: unsealing it while another image
    /// installs or awaits setup would leave two images awaiting setup.
    private var canCustomize: Bool {
        switch installer.phase {
        case .idle, .sealed: goldenAvailable
        case .downloading, .installing, .provisioning, .awaitingSetup, .failed: false
        }
    }

    @ViewBuilder
    private var setupView: some View {
        if let position = VMSetupSteps.position(of: installer.phase) {
            VMEmptyStateCard(
                icon: "desktopcomputer", title: "Setting up the base image",
                subtitle: "This happens once. Every worktree VM starts from it."
            ) {
                VMSetupSteps(current: position.current, fraction: position.fraction)
            }
        } else {
            if case .failed(let message) = installer.phase {
                VMCallout(title: "macOS setup couldn't finish", message: message)
            }
            VMEmptyStateCard(
                icon: "desktopcomputer", title: "Set up a macOS VM",
                subtitle: "Alas downloads macOS once and prepares a base image. Every worktree VM starts from it."
            ) {
                EmptyView()
            } actions: {
                AlasButton(title: "Set up", style: .primary) {
                    Task { await installer.start() }
                }
            }
        }
    }

    @ViewBuilder
    private func goldenSetupView(build: String) -> some View {
        let customized = vms.isGoldenCustomized(build: build)
        if let note = installer.failureNote {
            VMCallout(title: "Automatic setup stopped", message: note)
        }
        VMCallout(tone: .info, title: customized ? "Customize the base image" : "Finish the setup by hand") {
            VMNumberedSteps(steps: customized ? Self.customizeSteps : Self.manualSetupSteps)
                .padding(.top, 2)
        } actions: {
            // Not for a golden the user runs, which it would force off, nor
            // one reopened by Customize, which is for the user's own changes.
            if !customized {
                AlasButton(title: "Set up automatically", compact: true) {
                    Task { await installer.start() }
                }
                .vmDisabled(finishingSetup || vms.isGoldenRunning(build: build))
            }
            AlasButton(title: "Done", style: .primary, compact: true) { finishGoldenSetup(build: build) }
                .vmDisabled(finishingSetup)
        }
        if let golden = vms.runningGolden() {
            VMDisplaySurface(view: state.tabs.vmView(ownerKey: worktreeID), virtualMachine: golden.vm)
        } else if vms.isStarting(StartTarget.golden(build: build).id) || finishingSetup {
            Spinner().frame(width: 16, height: 16)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            VMEmptyStateCard(
                icon: "desktopcomputer", title: "The setup VM is off",
                subtitle: customized ? "Start it to make your changes." : "Start it to finish setting up macOS."
            ) {
                EmptyView()
            } actions: {
                AlasButton(title: "Start VM", icon: "play.fill", style: .primary) { start(.golden(build: build)) }
            }
        }
    }

    private static let manualSetupSteps = [
        "Create a user that logs in automatically.",
        "Install the helper: open My Shared Files › helper › Install Alas VM Guest.",
        "Allow it in Accessibility and Screen Recording.",
        "Shut down macOS from the Apple menu, then click Done.",
    ]

    private static let customizeSteps = [
        "Make your changes in the VM.",
        "Shut down macOS from the Apple menu, then click Done. New VMs start from your changes.",
    ]

    @ViewBuilder
    private func choiceView(_ choice: SlotChoice) -> some View {
        if choice.candidates.isEmpty {
            VMEmptyStateCard(
                icon: "rectangle.on.rectangle", title: "Both VM slots are in use by another Alas",
                subtitle: "Stop a VM there, then start this one again."
            ) {
                EmptyView()
            } actions: {
                AlasButton(title: "Cancel") { self.choice = nil }
            }
        } else {
            VMEmptyStateCard(
                icon: "rectangle.on.rectangle", title: "Both VM slots are busy",
                subtitle: "macOS runs two VMs at a time. Pause one to start this VM."
            ) {
                EmptyView()
            } actions: {
                ForEach(choice.candidates, id: \.self) { candidate in
                    AlasButton(title: "Pause \(displayName(forCandidate: candidate))") {
                        start(choice.target, pausing: candidate)
                    }
                }
                AlasButton(title: "Cancel", style: .subtle) { self.choice = nil }
            }
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
        // Only for Customize: a golden awaiting setup otherwise stays off so
        // "Set up automatically" can run; the manual flow starts it by hand.
        guard case .goldenSetup(let build, _) = screen,
              vms.isGoldenCustomized(build: build),
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

    /// Reopens the golden image; the tab then shows golden setup, whose Done
    /// seals it again.
    private func customizeBaseImage() {
        errorMessage = nil
        do {
            try vms.unsealGoldenForCustomizing(from: worktreeID)
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

    private func dismissBanner() {
        errorMessage = nil
        vms.dismissHelperUpdateFailure(worktreeID)
        if let build = awaitingSetupBuild { vms.dismissHelperUpdateFailure(StartTarget.golden(build: build).id) }
    }

    /// Asks the helper of a VM running here whether it is installed and
    /// current. A freshly booted guest starts it only after logging in, so
    /// a missing helper is asked again for a while before Update helper shows.
    private func checkHelper(_ id: String?) async {
        guard let id else { return }
        let deadline = ContinuousClock.now + .seconds(120)
        while !Task.isCancelled, let client = vms.guestClient(for: id) {
            let result: Result<VMGuestHello, VMGuestClient.Failure>
            do {
                result = .success(try await client.status())
            } catch {
                result = .failure(error as? VMGuestClient.Failure ?? .stopped)
            }
            guard !Task.isCancelled else { return }
            let notUpYet = switch result {
            case .failure(.helperMissing), .failure(.helperUnresponsive): true
            default: false
            }
            guard notUpYet, ContinuousClock.now < deadline else {
                vms.noteHelperCheck(id, result)
                return
            }
            try? await Task.sleep(for: .seconds(10))
        }
    }

    private func updateHelper(_ id: String) {
        errorMessage = nil
        Task {
            await vms.updateHelper(id)
            refresh()
        }
    }

    private func stop(_ id: String) {
        let ownVM = id == worktreeID && vms.running(id) != nil
        if ownVM { stopping = true }
        Task {
            await vms.stopVM(worktreeID: id)
            if ownVM { stopping = false }
            refresh()
        }
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
                    // An interrupted helper update may have left sshd on.
                    try await vms.turnOffLeftoverSSH(id: StartTarget.golden(build: build).id)
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
