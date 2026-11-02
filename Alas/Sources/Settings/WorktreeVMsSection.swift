import AlasCore
import SwiftUI

/// Settings › Worktrees › Virtual Machines: the disk base images, worktree VMs, orphaned VMs
/// and downloaded installers use, with Delete, Clean up and Remove.
struct WorktreeVMsSection: View {
    @Bindable var state: AppState
    @ObservedObject private var installer: GoldenImageInstaller
    @ObservedObject private var linuxInstaller: LinuxGoldenInstaller
    @Environment(\.theme) var theme
    @State private var bundles: [VMBundleSummary] = []
    @State private var orphans: [VMBundleSummary] = []
    @State private var installerBytes: Int64 = 0
    @State private var loaded = false
    /// Why the VM registry couldn't be read; the lists are hidden meanwhile.
    @State private var loadError: String?
    @State private var errorMessage: String?
    @State private var confirmingGolden: VMBundleSummary?
    @State private var confirmingVM: VMBundleSummary?
    @State private var confirmingCleanUp = false
    @State private var confirmingRemoveInstallers = false

    init(state: AppState) {
        self.state = state
        _installer = ObservedObject(wrappedValue: state.goldenImageInstaller)
        _linuxInstaller = ObservedObject(wrappedValue: state.linuxGoldenInstaller)
    }

    private var vms: WorktreeVMManager { state.vmManager }

    var body: some View {
        SettingsGroup(title: "Virtual Machines") {
            if let errorMessage {
                Text(errorMessage)
                    .font(.system(size: 12)).foregroundColor(theme.color("warn"))
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.bottom, 10)
            }
            if let loadError {
                Text("Couldn't read the VM registry: \(Self.sentence(loadError))")
                    .font(.system(size: 12.5)).foregroundColor(theme.color("warn"))
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.vertical, 10)
            } else if !loaded {
                Spinner().frame(width: 16, height: 16).padding(.vertical, 10)
            } else if bundles.isEmpty && !showsCleanUp {
                Text("No base images or VMs yet.")
                    .font(.system(size: 12.5)).foregroundColor(theme.color("fg-dim"))
                    .padding(.vertical, 10)
            }
            ForEach(bundles) { bundle in
                bundleRow(bundle)
            }
            if showsCleanUp { cleanUpRow }
            if installerBytes > 0 { installersRow }
            Text("Clones share blocks with their base image, so these sizes can add up to more than the disk used.")
                .font(.system(size: 11.5)).foregroundColor(theme.color("fg-dim"))
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 12)
        }
        .task { await refresh() }
        .alert("Delete this base image?", isPresented: present($confirmingGolden), presenting: confirmingGolden) { golden in
            Button("Delete", role: .destructive) { deleteGolden(golden) }
            Button("Cancel", role: .cancel) {}
        } message: { _ in
            Text("New worktree VMs need a base image, which is downloaded and set up again.")
        }
        .alert("Delete this worktree's VM?", isPresented: present($confirmingVM), presenting: confirmingVM) { vm in
            Button("Delete", role: .destructive) { deleteVM(vm) }
            Button("Cancel", role: .cancel) {}
        } message: { _ in
            Text("Its disk and everything inside it are removed.")
        }
        .alert("Clean up orphaned VMs?", isPresented: $confirmingCleanUp) {
            Button("Clean up", role: .destructive, action: cleanUp)
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(cleanUpMessage)
        }
        .alert("Remove downloaded installers?", isPresented: $confirmingRemoveInstallers) {
            Button("Remove", role: .destructive, action: removeInstallers)
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Setting up a base image again downloads them again.")
        }
    }

    // MARK: - Rows

    @ViewBuilder
    private func bundleRow(_ bundle: VMBundleSummary) -> some View {
        let elsewhere = bundle.runningElsewhere != nil
        let note = elsewhere ? " (running in another Alas)" : bundle.fromOtherBuild ? " (another Alas version's)" : ""
        diskRow(title: title(of: bundle) + note, bytes: bundle.allocatedBytes) {
            AlasButton(title: "Delete", compact: true) { askToDelete(bundle) }
                .vmDisabled(elsewhere || bundle.fromOtherBuild || bundle.runningHere
                    || (bundle.kind == .golden && installBusy(bundle.guest)))
        }
    }

    private var cleanUpRow: some View {
        let title = orphans.isEmpty
            ? "Leftovers of interrupted resets"
            : "\(orphans.count) orphaned VM\(orphans.count == 1 ? "" : "s") (worktree gone)"
        return diskRow(title: title, bytes: cleanUpBytes, tint: theme.color("warn")) {
            AlasButton(title: "Clean up", compact: true) { confirmingCleanUp = true }
        }
    }

    private var installersRow: some View {
        HStack(spacing: 6) {
            Text("Downloaded installers: \(Self.format(installerBytes))")
            Text("·")
            Button("Remove") { confirmingRemoveInstallers = true }
                .buttonStyle(.plain)
                .foregroundColor(theme.color("accent"))
                .vmDisabled(installBusy(.macOS) || installBusy(.linux))
        }
        .font(.system(size: 12.5))
        .foregroundColor(theme.color("fg-dim"))
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(Divider().opacity(0.5), alignment: .top)
    }

    private func diskRow(
        title: String, bytes: Int64, tint: Color? = nil, @ViewBuilder action: () -> some View
    ) -> some View {
        HStack(spacing: 12) {
            Text(title)
                .font(.system(size: 12.5, weight: .medium))
                .foregroundColor(tint ?? theme.color("fg"))
                .lineLimit(1).truncationMode(.middle)
            Spacer(minLength: 12)
            Text(Self.format(bytes))
                .font(.system(size: 12.5).monospacedDigit())
                .foregroundColor(tint ?? theme.color("fg-dim"))
            action()
        }
        .padding(.vertical, 8)
        .overlay(Divider().opacity(0.5), alignment: .top)
    }

    // MARK: - Names

    private func title(of bundle: VMBundleSummary) -> String {
        switch (bundle.kind, bundle.guest) {
        case (.golden, .macOS):
            return "macOS base image \(bundle.name)"
        case (.golden, .linux):
            return bundle.name == LinuxGoldenImage.serial
                ? "Ubuntu base image \(LinuxGoldenImage.release) · \(bundle.name)"
                : "Ubuntu base image \(bundle.name)"
        case (.worktree, _):
            let name = bundle.worktreeID.flatMap { state.projectAndWorktree(withWorktreeId: $0)?.worktree.name }
            return "\(name ?? bundle.name) · \(bundle.guest == .linux ? "Linux" : "macOS")"
        }
    }

    private var showsCleanUp: Bool { !orphans.isEmpty || leftoverBytes > 0 }
    private var leftoverBytes: Int64 { bundles.reduce(0) { $0 + $1.leftoverBytes } }
    private var cleanUpBytes: Int64 { orphans.reduce(leftoverBytes) { $0 + $1.allocatedBytes } }

    private var cleanUpMessage: String {
        var lines = orphans.map { orphan in
            "\(orphan.worktreeID ?? orphan.name) · \(orphan.guest == .linux ? "Linux" : "macOS")"
        }
        if leftoverBytes > 0 { lines.append("Files left by interrupted resets") }
        return "These are deleted, with everything inside them:\n" + lines.joined(separator: "\n")
    }

    private func installBusy(_ guest: VMGuestOS) -> Bool {
        switch guest {
        case .macOS:
            switch installer.phase {
            case .downloading, .installing, .provisioning: true
            default: false
            }
        case .linux:
            switch linuxInstaller.phase {
            case .idle, .sealed, .failed: false
            default: true
            }
        }
    }

    private static func format(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    private func present<T>(_ item: Binding<T?>) -> Binding<Bool> {
        Binding(get: { item.wrappedValue != nil }, set: { if !$0 { item.wrappedValue = nil } })
    }

    // MARK: - Actions

    private func refresh() async {
        async let installers = vms.installerBytes()
        do {
            let use = try await vms.diskUse()
            (bundles, orphans, loadError) = (use.bundles, use.orphans, nil)
        } catch {
            (bundles, orphans, loadError) = ([], [], error.localizedDescription)
        }
        installerBytes = await installers
        loaded = true
    }

    private func askToDelete(_ bundle: VMBundleSummary) {
        errorMessage = nil
        switch bundle.kind {
        case .golden where bundle.clones > 0:
            errorMessage = "Couldn't delete the base image: Delete its worktree VMs first."
        case .golden:
            confirmingGolden = bundle
        case .worktree:
            confirmingVM = bundle
        }
    }

    private func deleteGolden(_ golden: VMBundleSummary) {
        do {
            try vms.deleteGolden(id: golden.id)
        } catch {
            errorMessage = "Couldn't delete the base image: \(Self.sentence(error.localizedDescription))"
        }
        installer.reloadFromDisk()
        linuxInstaller.reloadFromDisk()
        Task { await refresh() }
    }

    private func deleteVM(_ vm: VMBundleSummary) {
        guard let worktreeID = vm.worktreeID else { return }
        Task {
            if let reason = await vms.deleteVM(worktreeID: worktreeID, guest: vm.guest) {
                errorMessage = "Couldn't delete the VM: \(Self.sentence(reason))"
            }
            await refresh()
        }
    }

    private func cleanUp() {
        errorMessage = nil
        if let reason = vms.deleteOrphans(orphans.map(\.id)) {
            errorMessage = "Some VMs couldn't be cleaned up: \(Self.sentence(reason))"
        }
        Task { await refresh() }
    }

    private func removeInstallers() {
        errorMessage = nil
        do {
            try vms.removeInstallers()
        } catch {
            errorMessage = "Couldn't remove the installers: \(Self.sentence(error.localizedDescription))"
        }
        Task { await refresh() }
    }

    /// `text` ending in exactly one period.
    private static func sentence(_ text: String) -> String {
        text.hasSuffix(".") ? text : text + "."
    }
}
