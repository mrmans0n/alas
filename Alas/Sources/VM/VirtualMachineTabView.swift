import AlasCore
import AppKit
import SwiftUI
import Virtualization

/// A worktree's VM tab for one guest: golden image setup, VM creation, start
/// and stop, and the live screen. Closing the tab leaves the VM running. A
/// Linux tab builds its image unattended, has no customizing, and updates
/// its helper without restarting the VM.
struct VirtualMachineTabView: View {
    let state: AppState
    let tab: VirtualMachineTabState
    @ObservedObject private var installer: GoldenImageInstaller
    @ObservedObject private var linuxInstaller: LinuxGoldenInstaller

    /// Registry and disk facts, read on appear and after actions rather than
    /// on every render: reading the registry takes a file lock.
    @State private var record = WorktreeVMManager.RecordStatus()
    @State private var goldenAvailable = false
    @State private var loaded = false
    /// The VM disk's allocated size, formatted; read off the main actor on refresh.
    @State private var diskSize: String?
    /// The latest disk size read; a newer refresh cancels it.
    @State private var diskSizeLoad: Task<Void, Never>?

    /// Outcome of the last start request, until the user acts on it.
    @State private var elsewhere: RunningElsewhere?
    @State private var choice: SlotChoice?
    @State private var errorMessage: String?
    @State private var finishingSetup = false
    @State private var confirmingCustomize = false
    /// A Stop of the VM running here is in progress.
    @State private var stopping = false
    @State private var confirmingDelete = false
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
        case worktree(String, VMGuestOS)
        case golden(build: String)

        /// The registry id.
        var id: String {
            switch self {
            case .worktree(let id, let guest): VMIdentity.recordID(worktree: id, guest: guest)
            case .golden(let build): WorktreeVMManager.goldenIDPrefix + build
            }
        }
    }

    init(state: AppState, tab: VirtualMachineTabState) {
        self.state = state
        self.tab = tab
        _installer = ObservedObject(wrappedValue: state.goldenImageInstaller)
        _linuxInstaller = ObservedObject(wrappedValue: state.linuxGoldenInstaller)
    }

    private var vms: WorktreeVMManager { state.vmManager }
    private var worktreeID: String { tab.ownerKey }
    private var guest: VMGuestOS { tab.guest }
    private var isLinux: Bool { guest == .linux }
    /// The worktree VM's registry id, which helper state and slots use.
    private var recordID: String { VMIdentity.recordID(worktree: worktreeID, guest: guest) }
    private var guestName: String { isLinux ? "Ubuntu" : "macOS" }

    private var screen: VMTabScreen {
        VMTabScreen.resolve(
            guest: guest,
            runningHere: vms.running(worktreeID, guest: guest) != nil,
            startingHere: vms.isStarting(recordID),
            slotChoice: choice?.candidates,
            runningElsewhere: elsewhere?.label ?? record.runningElsewhere,
            loaded: loaded,
            hasVM: record.hasVM,
            customizingHere: vms.customizingFrom == worktreeID,
            goldenAvailable: goldenAvailable,
            installerPhase: installer.phase,
            linuxInstallerPhase: linuxInstaller.phase,
            helper: helperUpdate(recordID),
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
        case .running: recordID
        case .goldenSetup:
            customizedGoldenID.flatMap { vms.running($0) != nil ? $0 : nil }
        default: nil
        }
    }

    /// The error to show: this tab's own, else a failed helper update of a VM it shows.
    private var bannerMessage: String? {
        errorMessage ?? vms.helperUpdateFailures[recordID]
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
        // Starting or stopping changes the disk's size and the registry.
        .onChange(of: vms.running(worktreeID, guest: guest) != nil) { _, _ in refresh() }
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
            Text(isLinux
                ? "This reinstalls the helper from the share and restarts it; the VM keeps running."
                : "This restarts the VM; unsaved work inside it is lost.")
        }
        .alert("Delete this worktree's VM?", isPresented: $confirmingDelete) {
            Button("Delete", role: .destructive, action: deleteVM)
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Its disk and everything inside it are removed.")
        }
    }

    /// The macOS golden awaiting setup; never shown in a Linux tab.
    private var awaitingSetupBuild: String? {
        if !isLinux, case .awaitingSetup(let build) = installer.phase { return build }
        return nil
    }

    private var phaseKind: String {
        if isLinux {
            return switch linuxInstaller.phase {
            case .idle: "idle"
            case .downloading: "downloading"
            case .checking: "checking"
            case .converting: "converting"
            case .firstBoot: "firstBoot"
            case .verifying: "verifying"
            case .sealed(let serial): "sealed:\(serial)"
            case .failed: "failed"
            }
        }
        return switch installer.phase {
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
                details: (canUpdateHelper ? ["helper needs an update"] : []) + diskDetails
            ) {
                ToolbarBtn(icon: "stop.fill", tooltip: "Stop VM", metrics: .vmStatusBar) { stop(recordID) }
                    .vmDisabled(stopping)
                overflowMenu(updateHelper: canUpdateHelper ? recordID : nil, reveal: ownBundleURL, deletable: true)
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
            VMStatusBar(tone: .off, title: "Stopped", details: diskDetails) {
                overflowMenu(customize: canCustomize, reveal: ownBundleURL, deletable: true)
            }
        case .stoppedWhileCustomizing:
            VMStatusBar(tone: .off, title: "Stopped", details: ["base image being customized"] + diskDetails) {
                overflowMenu(reveal: ownBundleURL, deletable: true)
            }
        }
    }

    @ViewBuilder
    private var setupStatusBar: some View {
        if isLinux { linuxSetupStatusBar } else { macOSSetupStatusBar }
    }

    @ViewBuilder
    private var linuxSetupStatusBar: some View {
        switch linuxInstaller.phase {
        case .downloading(let fraction):
            preparingStatusBar("downloading \(percent(fraction))")
        case .checking:
            preparingStatusBar("checking download")
        case .converting(let fraction):
            preparingStatusBar("converting \(percent(fraction))")
        case .firstBoot, .verifying:
            preparingStatusBar(nil)
        case .failed:
            VMStatusBar(tone: .attention, title: "Needs attention")
        case .idle, .sealed:
            VMStatusBar(tone: .off, title: "No base image")
        }
    }

    @ViewBuilder
    private var macOSSetupStatusBar: some View {
        switch installer.phase {
        case .downloading(let fraction):
            preparingStatusBar("downloading \(percent(fraction))")
        case .installing(let fraction):
            preparingStatusBar("installing \(percent(fraction))")
        case .provisioning:
            preparingStatusBar(nil)
        case .failed:
            VMStatusBar(tone: .attention, title: "Needs attention")
        case .idle, .sealed, .awaitingSetup:
            VMStatusBar(tone: .off, title: "No base image")
        }
    }

    private func preparingStatusBar(_ progress: String?) -> some View {
        let version = isLinux ? "Ubuntu \(LinuxGoldenImage.release)" : installer.setupBuild.map { "macOS \($0)" }
        let cancelling = isLinux ? linuxInstaller.cancelling : installer.cancelling
        return VMStatusBar(
            tone: .busy, title: "Preparing \(guestName)",
            details: [version, progress].compactMap { $0 }
        ) {
            AlasButton(title: cancelling ? "Cancelling…" : "Cancel", style: .subtle, compact: true) {
                if isLinux { linuxInstaller.cancel() } else { installer.cancelSetup() }
            }
            .vmDisabled(cancelling)
        }
    }

    private var diskDetails: [String] { diskSize.map { [$0] } ?? [] }

    private var ownBundleURL: URL? { record.bundlePath.map { URL(fileURLWithPath: $0, isDirectory: true) } }

    private func goldenStatusBar(build: String, canUpdateHelper: Bool) -> some View {
        let customized = vms.isGoldenCustomized(build: build)
        let running = vms.runningGolden() != nil
        // Running it is how the user finishes by hand; the note stays in its callout.
        let needsAttention = installer.failureNote != nil && !running
        let tone: VMStatusTone = needsAttention ? .attention : running ? .running : .off
        let title = customized ? "Customizing the base image"
            : needsAttention ? "Needs attention" : "Setting up macOS"
        return VMStatusBar(tone: tone, title: title, details: ["macOS \(build)", running ? "running" : "off"]) {
            overflowMenu(
                updateHelper: canUpdateHelper && !finishingSetup ? StartTarget.golden(build: build).id : nil,
                reveal: vms.goldenBundleURL(build: build))
        }
    }

    private func percent(_ fraction: Double) -> String {
        "\(Int((min(max(fraction, 0), 1) * 100).rounded()))%"
    }

    /// The ⋯ menu of rare actions; nothing when none applies. `deletable`
    /// offers deleting this worktree's own VM.
    @ViewBuilder
    private func overflowMenu(
        updateHelper id: String? = nil, customize: Bool = false, reveal bundle: URL? = nil, deletable: Bool = false
    ) -> some View {
        if id != nil || customize || bundle != nil || deletable {
            ToolbarMenuButton(
                iconName: "ellipsis", metrics: .vmStatusBar, restingColorToken: "fg-muted", help: "More VM actions"
            ) {
                if let id {
                    Button("Update helper…") { confirmingHelperUpdate = id }
                }
                if customize {
                    Button("Customize base image…") { confirmingCustomize = true }
                }
                if let bundle {
                    Button("Reveal in Finder") { NSWorkspace.shared.activateFileViewerSelecting([bundle]) }
                }
                if deletable {
                    Divider()
                    Button("Delete VM…", role: .destructive) { confirmingDelete = true }
                }
            }
        }
    }

    // MARK: - Screens

    @ViewBuilder
    private var content: some View {
        switch screen {
        case .running:
            VMDisplaySurface(
                view: state.tabs.vmView(tabID: tab.id), virtualMachine: vms.running(worktreeID, guest: guest)?.vm)
        case .starting:
            VMEmptyStateCard(
                icon: "desktopcomputer", title: "Starting the VM", subtitle: "\(guestName) is booting.", busy: true
            ) {
                EmptyView()
            } actions: {
                AlasButton(title: "Stop") { stop(recordID) }
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
                    start(elsewhere?.target ?? .worktree(worktreeID, guest))
                }
            }
        case .goldenSetup(let build, _):
            goldenSetupView(build: build)
        case .updatingHelper:
            VMEmptyStateCard(
                icon: "desktopcomputer", title: "Updating the helper",
                subtitle: isLinux ? "Ubuntu installs the new helper and restarts it." : "The VM restarts with the new helper.",
                busy: true)
        case .loading:
            Spinner().frame(width: 16, height: 16)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .setup:
            setupView
        case .createVM:
            VMEmptyStateCard(
                icon: "desktopcomputer", title: "No VM for this worktree",
                subtitle: isLinux
                    ? "Create one from the Ubuntu image. Agents can run commands in it while your desktop stays untouched."
                    : "Create one from the base image. Agents can drive it with computer use while your desktop stays untouched."
            ) {
                EmptyView()
            } actions: {
                AlasButton(title: "Create VM", icon: "plus", style: .primary, action: createVM)
            }
        case .stopped:
            VMEmptyStateCard(
                icon: "desktopcomputer", title: "This worktree's VM is off",
                subtitle: isLinux
                    ? "Agents can run commands in it once it's running. Your desktop stays untouched."
                    : "Agents can drive it with computer use once it's running. Your desktop stays untouched."
            ) {
                EmptyView()
            } actions: {
                AlasButton(title: "Start VM", icon: "play.fill", style: .primary) { start(.worktree(worktreeID, guest)) }
            }
        case .stoppedWhileCustomizing:
            VMEmptyStateCard(
                icon: "desktopcomputer", title: "This worktree's VM is off",
                subtitle: "The base image is being customized. Finish customizing it here, or start this VM."
            ) {
                EmptyView()
            } actions: {
                AlasButton(title: "Start VM", icon: "play.fill", style: .primary) { start(.worktree(worktreeID, guest)) }
                AlasButton(title: "Finish customizing") { vms.finishCustomizing(from: worktreeID) }
            }
        }
    }

    /// Only with a sealed golden settled: unsealing it while another image
    /// installs or awaits setup would leave two images awaiting setup.
    private var canCustomize: Bool {
        if isLinux { return false }
        return switch installer.phase {
        case .idle, .sealed: goldenAvailable
        case .downloading, .installing, .provisioning, .awaitingSetup, .failed: false
        }
    }

    @ViewBuilder
    private var setupView: some View {
        if isLinux { linuxSetupView } else { macOSSetupView }
    }

    @ViewBuilder
    private var linuxSetupView: some View {
        if let position = VMSetupSteps.position(of: linuxInstaller.phase) {
            VMEmptyStateCard(
                icon: "desktopcomputer", title: "Setting up the Ubuntu image",
                subtitle: "This happens once. Every Linux VM starts from it."
            ) {
                VMSetupSteps(titles: linuxSetupTitles, current: position.current, fraction: position.fraction)
            }
        } else {
            if case .failed(let message) = linuxInstaller.phase {
                VMCallout(title: "Ubuntu setup couldn't finish", message: message)
            }
            VMEmptyStateCard(
                icon: "desktopcomputer", title: "Set up a Linux VM",
                subtitle: "Alas downloads Ubuntu once and prepares a base image. Every Linux VM starts from it."
            ) {
                EmptyView()
            } actions: {
                AlasButton(title: "Set up", style: .primary) {
                    Task { await linuxInstaller.start() }
                }
            }
        }
    }

    /// A cached or just downloaded image is checksummed before converting;
    /// the first step says so rather than sitting at its download progress.
    private var linuxSetupTitles: [String] {
        var titles = VMSetupSteps.linuxTitles
        if linuxInstaller.phase == .checking { titles[0] = "Checking download…" }
        return titles
    }

    @ViewBuilder
    private var macOSSetupView: some View {
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
            VMDisplaySurface(view: state.tabs.vmView(tabID: tab.id), virtualMachine: golden.vm)
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
        if isLinux {
            goldenAvailable = LinuxGoldenInstaller.availableGolden(root: vms.root) != nil
        } else {
            // Another Alas process may have sealed or replaced the golden image.
            installer.reloadFromDisk()
            goldenAvailable = vms.availableGolden() != nil
        }
        record = vms.recordStatus(worktreeID, guest: guest)
        loaded = true
        loadDiskSize()
    }

    /// Reads the allocated (not logical) size of the VM's sparse disk image
    /// off the main actor.
    private func loadDiskSize() {
        diskSizeLoad?.cancel()
        diskSizeLoad = nil
        guard let path = record.bundlePath else {
            diskSize = nil
            return
        }
        let disk = VMBundle(url: URL(fileURLWithPath: path, isDirectory: true)).diskImage
        diskSizeLoad = Task {
            let bytes = await Task.detached { Self.allocatedBytes(of: disk) }.value
            // A read that finishes after a newer refresh (a delete, say) is stale.
            guard !Task.isCancelled, record.bundlePath == path else { return }
            diskSize = bytes.map { ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) }
        }
    }

    private nonisolated static func allocatedBytes(of file: URL) -> Int64? {
        var info = stat()
        guard stat(file.path, &info) == 0 else { return nil }
        return Int64(info.st_blocks) * 512
    }

    private func deleteVM() {
        errorMessage = nil
        Task {
            if let reason = await vms.deleteVM(worktreeID: worktreeID, guest: guest) {
                let phrase = reason.hasSuffix(".") ? String(reason.dropLast()) : reason
                errorMessage = "Couldn't delete the VM: \(phrase)."
            }
            refresh()
        }
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
            try vms.createVM(worktreeID: worktreeID, guest: guest)
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
                    case .worktree(let id, let guest): try await vms.startVM(worktreeID: id, guest: guest)
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
        vms.dismissHelperUpdateFailure(recordID)
        if let build = awaitingSetupBuild { vms.dismissHelperUpdateFailure(StartTarget.golden(build: build).id) }
    }

    /// Asks the helper of a VM running here whether it is installed and
    /// current. A freshly booted guest starts it only after logging in, so
    /// a missing helper is asked again for a while before Update helper shows.
    private func checkHelper(_ id: String?) async {
        guard let id else { return }
        let deadline = ContinuousClock.now + .seconds(120)
        let vm = VMIdentity.parse(recordID: id)
        while !Task.isCancelled, let client = vms.guestClient(for: vm.worktree, guest: vm.guest) {
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

    /// `id` is a registry id: this tab's VM or a golden.
    private func stop(_ id: String) {
        let (worktree, guest) = VMIdentity.parse(recordID: id)
        let ownVM = id == recordID && vms.running(worktree, guest: guest) != nil
        if ownVM { stopping = true }
        Task {
            await vms.stopVM(worktreeID: worktree, guest: guest)
            if ownVM { stopping = false }
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
