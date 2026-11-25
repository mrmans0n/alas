import AlasCore
import AppKit
import SwiftUI
import Virtualization

struct ProjectVMBaseWindow: View {
    static let sceneID = "project-macos-base"

    let state: AppState
    let projectID: String
    @ObservedObject private var installer: GoldenImageInstaller
    @Environment(\.designScale) private var scale
    @Environment(\.theme) private var theme
    @Environment(\.scenePhase) private var scenePhase
    @State private var display = VZVirtualMachineView()
    @State private var sharedDisplay = VZVirtualMachineView()
    @State private var selection: ProjectVMBaseStore.State?
    @State private var sharedIntent: WorktreeVMManager.ProjectDraftMode?
    @State private var confirm: Confirmation?
    @State private var slots: SlotChoice?
    @State private var busy = false
    @State private var startingElsewhere: String?
    @State private var errorMessage: String?

    private enum Confirmation: Identifiable {
        case discard(UUID), rebuild(UUID), remove(UUID)

        var id: UUID {
            switch self { case .discard(let id), .rebuild(let id), .remove(let id): id }
        }

        var title: String {
            switch self {
            case .discard: "Discard this draft?"
            case .rebuild: "Replace this draft from the shared base?"
            case .remove: "Remove the project base?"
            }
        }

        var message: String {
            switch self {
            case .discard: "The draft's changes are deleted. The saved project base stays in use."
            case .rebuild: "Use the current shared macOS image and guest setup script. The saved base stays in use until you save the new draft."
            case .remove: "New macOS VMs and Reset from scratch will use the default again. Existing VMs are unchanged."
            }
        }
    }

    private enum BootTarget { case draft(UUID), shared(String) }
    private struct SlotChoice {
        let target: BootTarget
        let candidates: [String]
    }

    init(state: AppState, projectID: String) {
        self.state = state
        self.projectID = projectID
        _installer = ObservedObject(wrappedValue: state.goldenImageInstaller)
    }

    private var vms: WorktreeVMManager { state.vmManager }
    private var project: ProjectConfig? {
        guard WorktreeVMManager.isSupported else { return nil }
        return state.projects.first { $0.id == projectID && $0.host == nil && !$0.isFolder }
    }

    var body: some View {
        VStack(spacing: 0) {
            if let project {
                header(project)
                if let message = errorMessage ?? selection?.draft.flatMap({ vms.projectDraftSetupErrors[$0.id] }) {
                    VMCallout(message: message, onDismiss: { errorMessage = nil })
                }
                if let slots {
                    slotCard(slots)
                } else if sharedIntent != nil {
                    sharedSetup
                } else if let draft = selection?.draft {
                    draftContent(draft)
                } else {
                    emptyContent
                }
            } else {
                VMEmptyStateCard(icon: "desktopcomputer", title: "Project unavailable",
                                 subtitle: "A project base needs a local Git project and a Mac with Apple silicon.")
            }
        }
        .frame(minWidth: 640, minHeight: 440)
        .background(theme.color("bg"))
        .navigationTitle(project.map { "\($0.name) · macOS Base" } ?? "Project macOS Base")
        .task(id: projectID) {
            refresh()
            if project != nil { prepare(.customize) }
        }
        .onChange(of: vms.projectBaseRevision) { refresh() }
        .onChange(of: scenePhase) { if scenePhase == .active { refresh(); installer.reloadFromDisk(); continueIfSealed() } }
        .onChange(of: installer.phase) { continueIfSealed() }
        .alert(confirm?.title ?? "", isPresented: Binding(get: { confirm != nil }, set: { if !$0 { confirm = nil } }),
               presenting: confirm) { action in
            Button(actionLabel(action), role: .destructive) { execute(action) }
            Button("Cancel", role: .cancel) {}
        } message: { action in
            Text(action.message)
        }
    }

    private func header(_ project: ProjectConfig) -> some View {
        VStack(alignment: .leading, spacing: scale.space[2]) {
            ProjectVMBaseStatusText(state: state, project: project, selection: selection)
            Text("Do not copy credentials to the guest disk. Future worktree VMs inherit its files.")
                .font(scale.metaFont).foregroundStyle(theme.color("warn"))
            HStack {
                if let draft = selection?.draft {
                    AlasButton(title: "Transfer Folder", compact: true) {
                        let url = vms.projectDraftTransferDirectory(draft.id)
                        do {
                            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
                            NSWorkspace.shared.activateFileViewerSelecting([url])
                        } catch { errorMessage = error.localizedDescription }
                    }
                    AlasButton(title: "Discard Draft…", style: .subtle, compact: true) { confirm = .discard(draft.id) }
                        .vmDisabled(busy)
                    AlasButton(title: "Rebuild from Shared Base…", style: .subtle, compact: true) { confirm = .rebuild(draft.id) }
                        .vmDisabled(busy || vms.isProjectDraftSettingUp(draft.id))
                    Spacer()
                    let elsewhere = vms.projectDraftRecordStatus(draftID: draft.id).runningElsewhere
                    AlasButton(title: busy ? "Working…" : "Save as Project Base", style: .primary, compact: true) {
                        perform { _ = try await vms.saveProjectBase(projectID: projectID, draftID: draft.id) }
                    }
                    .vmDisabled(busy || draft.setup != .ready || vms.isProjectDraftSettingUp(draft.id) || elsewhere != nil)
                } else {
                    AlasButton(title: "Rebuild from Shared Base", compact: true) { prepare(.rebuild(expectedDraft: nil)) }
                        .vmDisabled(busy || sharedIntent != nil)
                    Spacer()
                    if let base = selection?.base {
                        AlasButton(title: "Remove Project Base…", style: .subtle, compact: true) { confirm = .remove(base.id) }
                            .vmDisabled(busy)
                    }
                }
            }
        }
        .padding(scale.space[4])
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var emptyContent: some View {
        VMEmptyStateCard(icon: "desktopcomputer", title: busy ? "Preparing the draft" : "No open draft", busy: busy) {
            EmptyView()
        } actions: {
            AlasButton(title: "Customize", style: .primary) { prepare(.customize) }.vmDisabled(busy)
        }
    }

    @ViewBuilder
    private func draftContent(_ draft: ProjectVMBaseStore.Draft) -> some View {
        let recordID = VMIdentity.projectDraftRecordID(draft.id)
        let record = vms.projectDraftRecordStatus(draftID: draft.id)
        if vms.isProjectDraftSettingUp(draft.id) {
            VMCallout(tone: .info, title: "Running the guest setup script", message: "Save is available after the script succeeds.")
        } else if case .failed(let exitCode) = draft.setup {
            let detail = exitCode.map { "It exited with status \($0)." } ?? "It didn't finish."
            VMCallout(title: "Guest setup failed", message: "\(detail) Retry runs the same script on this disk without undoing its previous changes.") {} actions: {
                AlasButton(title: "Retry", compact: true) {
                    perform {
                        if vms.runningVMs[recordID] == nil { try await boot(.draft(draft.id)) }
                        if vms.runningVMs[recordID] != nil { try await vms.retryProjectDraftSetup(projectID: projectID, draftID: draft.id) }
                    }
                }.vmDisabled(busy || record.runningElsewhere != nil)
            }
        } else if draft.setup == .pending, vms.projectDraftSetupErrors[draft.id] != nil {
            AlasButton(title: "Retry Setup", compact: true) {
                perform { try await vms.retryProjectDraftSetup(projectID: projectID, draftID: draft.id) }
            }.vmDisabled(busy || record.runningElsewhere != nil)
        }
        if let vm = vms.runningVMs[recordID] {
            VMDisplaySurface(view: display, virtualMachine: vm.vm, onUserInput: { state.noteVMUserInput(recordID: recordID) })
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            let elsewhere = record.runningElsewhere ?? startingElsewhere
            VMEmptyStateCard(icon: "desktopcomputer", title: elsewhere.map { "Running in \($0)" } ?? "The project setup VM is off",
                             subtitle: "Its disk is kept until you save, discard, or rebuild the draft.",
                             busy: vms.isStarting(recordID)) {
                EmptyView()
            } actions: {
                AlasButton(title: "Start VM", icon: "play.fill", style: .primary) { perform { try await boot(.draft(draft.id)) } }
                    .vmDisabled(busy || record.runningElsewhere != nil)
            }
        }
    }

    private var sharedSetup: some View {
        VStack(spacing: 0) {
            HStack {
                Text("The shared macOS base is needed to create this draft.").font(scale.metaFont)
                Spacer()
                if VMSetupSteps.position(of: installer.phase) != nil {
                    AlasButton(title: "Cancel Setup", style: .subtle, compact: true) { installer.cancelSetup(); sharedIntent = nil }
                } else {
                    AlasButton(title: "Back", style: .subtle, compact: true) { sharedIntent = nil }
                }
            }
            .padding(scale.space[3])
            SharedMacOSSetupView(installer: installer, vms: vms, build: awaitingBuild, display: sharedDisplay, finishing: busy,
                start: { build in perform { try await boot(.shared(build)) } },
                finish: { build in perform {
                    try await SharedMacOSSetupView.finish(build: build, vms: vms, installer: installer)
                    if let intent = sharedIntent { try await prepareDraft(intent) }
                } })
        }
    }

    private var awaitingBuild: String? {
        if case .awaitingSetup(let build) = installer.phase { return build }
        return nil
    }

    private func slotCard(_ choice: SlotChoice) -> some View {
        VMEmptyStateCard(icon: "desktopcomputer", title: "Both macOS VM slots are in use",
                         subtitle: choice.candidates.isEmpty ? "Free a slot in the Alas window that owns a VM, then try again." : "Pause a VM to start this one.") {
            EmptyView()
        } actions: {
            ForEach(choice.candidates, id: \.self) { candidate in
                AlasButton(title: "Pause \(state.vmDisplayName(forRecordID: candidate))") {
                    perform { try await boot(choice.target, pausing: candidate) }
                }
            }
            AlasButton(title: "Cancel", style: .subtle) { slots = nil }
        }
    }

    private func boot(_ target: BootTarget, pausing candidate: String? = nil) async throws {
        slots = nil
        startingElsewhere = nil
        let result: VMStartOutcome
        switch target {
        case .draft(let draft): result = try await vms.startProjectDraft(projectID: projectID, draftID: draft, pausing: candidate)
        case .shared(let build):
            if let candidate {
                result = .running(try await vms.startVM(worktreeID: WorktreeVMManager.goldenIDPrefix + build, pausing: candidate))
            } else {
                result = try await vms.startGolden(build: build)
            }
        }
        switch result {
        case .running: break
        case .runningElsewhere(let label): startingElsewhere = label
        case .needsUserChoice(let candidates): slots = SlotChoice(target: target, candidates: candidates)
        }
        if case .shared = target, let startingElsewhere {
            errorMessage = "The shared macOS setup VM is running in \(startingElsewhere)."
        }
    }

    private func prepare(_ mode: WorktreeVMManager.ProjectDraftMode) {
        perform { try await prepareDraft(mode) }
    }

    private func prepareDraft(_ mode: WorktreeVMManager.ProjectDraftMode) async throws {
        guard let project else { return }
        switch try await vms.prepareProjectDraft(projectID: projectID, script: state.effectiveVMGuestSetupScript(for: project), mode: mode) {
        case .draft(let draft):
            sharedIntent = nil
            try await boot(.draft(draft.id))
        case .needsSharedBase:
            sharedIntent = mode
            installer.reloadFromDisk()
        }
    }

    private func continueIfSealed() {
        guard !busy, case .sealed = installer.phase, let intent = sharedIntent, vms.availableGolden() != nil else { return }
        prepare(intent)
    }

    private func refresh() {
        do { selection = try vms.projectBaseStatus(projectID: projectID) }
        catch { selection = nil; errorMessage = error.localizedDescription }
    }

    private func perform(_ action: @escaping @MainActor () async throws -> Void) {
        guard !busy else { return }
        busy = true
        errorMessage = nil
        Task {
            do { try await action() }
            catch { errorMessage = error.localizedDescription }
            refresh()
            busy = false
        }
    }

    private func actionLabel(_ action: Confirmation) -> String {
        switch action { case .discard: "Discard Draft"; case .rebuild: "Rebuild"; case .remove: "Remove Base" }
    }

    private func execute(_ action: Confirmation) {
        switch action {
        case .discard(let draft): perform { try await vms.discardProjectDraft(projectID: projectID, draftID: draft) }
        case .rebuild(let draft): prepare(.rebuild(expectedDraft: draft))
        case .remove(let base): perform { try vms.removeProjectBase(projectID: projectID, baseID: base) }
        }
    }
}

struct ProjectVMBaseStatusText: View {
    let state: AppState
    let project: ProjectConfig
    let selection: ProjectVMBaseStore.State?
    @Environment(\.designScale) private var scale
    @Environment(\.theme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: scale.space[1]) {
            if let selection {
                if let base = selection.base {
                    Text("Saved project base · \(base.savedAt.formatted(date: .abbreviated, time: .shortened))")
                    Text("New macOS VMs and Reset from scratch use this base without running the setup script.")
                    if let shared = WorktreeVMManager.currentGolden(.macOS, root: state.vmManager.root) {
                        if shared.build != base.provenance.sharedBuild || shared.sealedAt != base.provenance.sharedSealedAt {
                            Text("The shared macOS image has changed since this base was prepared.")
                        }
                    } else {
                        Text("The shared macOS image is unavailable. The saved project base still works.")
                    }
                    if VMCleanPoint.scriptHash(state.effectiveVMGuestSetupScript(for: project)) != base.provenance.scriptHash {
                        Text("The guest setup script has changed since this base was prepared.")
                    }
                } else {
                    Text("New macOS VMs use the default base and guest setup script.")
                }
                if selection.draft != nil { Text("Project base draft saved on this Mac.") }
            } else {
                Text("Project base status is unavailable.")
            }
        }
        .font(scale.metaFont)
        .foregroundStyle(theme.color("fg-muted"))
    }
}
