import AppKit
import Observation
import SwiftUI

@MainActor
final class CodeActionsFeature {
    private weak var textView: CodeTextView?
    private let tabs: TabsManager
    private let root: URL
    private let edits: RenameFeature
    private let synchronize: (NSRange) async -> (LSPClient, EditorRequestContext)?
    private let isCurrent: (EditorRequestContext) -> Bool
    private let diagnostics: () -> [LSPDiagnostic]
    private var popover: NSPopover?
    private var task: Task<Void, Never>?
    private var generation = UUID()
    private let presentation = CodeActionEditPresentation()

    init(textView: CodeTextView, tabs: TabsManager, root: URL,
         synchronize: @escaping (NSRange) async -> (LSPClient, EditorRequestContext)?,
         isCurrent: @escaping (EditorRequestContext) -> Bool,
         diagnostics: @escaping () -> [LSPDiagnostic]) {
        self.textView = textView
        self.tabs = tabs
        self.root = root
        self.synchronize = synchronize
        self.isCurrent = isCurrent
        self.diagnostics = diagnostics
        edits = RenameFeature(textView: textView, tabs: tabs, root: root, synchronize: synchronize, isCurrent: isCurrent)
    }

    func cancel() {
        generation = UUID()
        task?.cancel()
        task = nil
        popover?.close()
        popover = nil
        presentation.cancel()
    }

    /// `diagnosticContext` is the original server diagnostic selected from
    /// details UI. It intentionally bypasses display-range reconstruction so
    /// opaque data and wire coordinates reach `textDocument/codeAction`.
    func show(range: NSRange, only: [String]? = nil, diagnosticContext: [LSPDiagnostic]? = nil) {
        cancel()
        let id = generation
        task = Task { [weak self] in
            guard let self, let (client, context) = await synchronize(range), id == generation,
                  isCurrent(context), let textView else { return }
            let generations = tabs.workspaceEditGenerations(host: context.document.host, worktreeID: context.document.worktreeID)
            let selectedDiagnostics = diagnosticContext ?? Self.diagnostics(diagnostics(), intersecting: context.range)
            do {
                let actions = try await client.codeActions(uri: context.document.uri, range: context.range, diagnostics: selectedDiagnostics, only: only)
                guard !Task.isCancelled, id == generation, isCurrent(context), textView.window != nil else { return }
                let model = CodeActionPickerModel(actions: actions)
                let popover = NSPopover()
                popover.behavior = .applicationDefined
                popover.contentViewController = NSHostingController(rootView: CodeActionPicker(model: model, select: { [weak self] action in
                    guard let self else { return }
                    self.popover?.close()
                    self.popover = nil
                    self.task = Task { await self.run(action, client: client, context: context, generations: generations, id: id) }
                }, organizeImports: { [weak self] in self?.show(range: range, only: ["source.organizeImports"], diagnosticContext: diagnosticContext) }, cancel: { [weak self] in self?.cancel() }))
                self.popover = popover
                popover.show(relativeTo: textView.symbolAnchorRect(for: range) ?? .zero, of: textView, preferredEdge: .maxY)
            } catch { showStatus(RenameFeature.message(for: error)) }
        }
    }

    static func diagnostics(_ diagnostics: [LSPDiagnostic], intersecting range: LSPRange) -> [LSPDiagnostic] {
        func precedes(_ a: LSPPosition, _ b: LSPPosition) -> Bool {
            a.line < b.line || a.line == b.line && a.character < b.character
        }
        return diagnostics.filter { !precedes($0.range.end, range.start) && !precedes(range.end, $0.range.start) }
    }

    /// Called only for a chosen row. Preview failure, cancellation and stale context stop the command.
    static func perform(_ action: LSPCodeAction, isCurrent: () -> Bool,
                        apply: (LSPWorkspaceEdit) async -> LSPApplyEditResult,
                        execute: (LSPCommand) async throws -> Void) async throws -> LSPApplyEditResult {
        guard !Task.isCancelled, isCurrent() else { return .cancelled }
        if let disabled = action.disabled { return .init(applied: false, failureReason: disabled.reason) }
        if let edit = action.edit {
            let result = await apply(edit)
            guard result.applied else { return result }
        }
        guard !Task.isCancelled, isCurrent() else { return .cancelled }
        if let command = action.command { try await execute(command) }
        guard !Task.isCancelled else { return .cancelled }
        return .init(applied: true)
    }

    private func run(_ action: LSPCodeAction, client: LSPClient, context: EditorRequestContext,
                     generations: [EditorDocumentID: WorkspaceEditBufferGeneration], id: UUID) async {
        let session = CodeActionContext(context: context, generations: generations)
        do {
            guard id == generation, isCurrent(context), !Task.isCancelled else { return }
            let resolved: LSPCodeAction
            if !action.isCommand, await client.supportsCodeActionResolve {
                resolved = try await client.resolveCodeAction(action)
            } else { resolved = action }
            let result = try await Self.perform(resolved, isCurrent: {
                self.isCurrent(session, id: id)
            }, apply: { edit in
                await self.apply(edit, session: session, client: client, id: id)
            }, execute: { command in
                let token = try await client.beginCommandSession { [weak self] edit in
                    guard let self else { return .cancelled }
                    return await self.apply(edit, session: session, client: client, id: id)
                }
                do {
                    try Task.checkCancellation()
                    guard self.isCurrent(session, id: id) else { throw CancellationError() }
                    try await client.executeCommand(command)
                    try await client.finishCommandSession(token)
                } catch {
                    await client.endCommandSession(token)
                    throw error
                }
            })
            showStatus(result.failureReason ?? (result.applied ? "Code action completed" : "Code action cancelled"))
        } catch { showStatus(RenameFeature.message(for: error)) }
    }

    private func showStatus(_ message: String) {
        guard let textView, textView.window != nil else { return }
        textView.showCommandStatus(message)
    }

    private func isCurrent(_ session: CodeActionContext, id: UUID) -> Bool {
        id == generation && isCurrent(session.context)
            && tabs.workspaceEditGenerations(host: session.context.document.host, worktreeID: session.context.document.worktreeID) == session.generations
    }

    static func validatedGenerations(
        captured: [EditorDocumentID: WorkspaceEditBufferGeneration],
        current: [EditorDocumentID: WorkspaceEditBufferGeneration],
        applied: [EditorDocumentID: WorkspaceFileSnapshot],
        actual: [EditorDocumentID: WorkspaceFileSnapshot]
    ) throws -> [EditorDocumentID: WorkspaceEditBufferGeneration] {
        let edited = Set(applied.keys)
        let untouched = captured.filter { !edited.contains($0.key) }
        guard current.filter({ !edited.contains($0.key) }) == untouched else { throw RenameFeature.Error.stale }
        let editedOwners = Set(captured.filter { edited.contains($0.key) }.values.map(\.identity))
        var refreshed = untouched
        for (document, expected) in applied {
            guard let snapshot = actual[document], WorkspaceEditExecutor.matches(snapshot, expected) else {
                throw WorkspaceEditAccessError.conflict(document)
            }
            if let generation = current[document] {
                guard expected.isOpen, editedOwners.contains(generation.identity),
                      generation.edit == expected.bufferGeneration,
                      generation.watch == expected.fileWatchGeneration else { throw WorkspaceEditAccessError.conflict(document) }
                refreshed[document] = generation
            } else if expected.isOpen { throw WorkspaceEditAccessError.conflict(document) }
        }
        return refreshed
    }

    private func apply(_ edit: LSPWorkspaceEdit, session: CodeActionContext, client: LSPClient, id: UUID) async -> LSPApplyEditResult {
        guard !Task.isCancelled, isCurrent(session, id: id), !session.isApplying else { return .cancelled }
        session.isApplying = true
        defer { session.isApplying = false }
        do {
            let original = session.context
            let plan = try await edits.prepare(edit, context: original, generations: session.generations)
            guard !Task.isCancelled, id == generation, isCurrent(original), let textView else { return .cancelled }
            let expectedText = plan.finalSnapshots[original.document]?.content ?? Data(textView.sourceString.utf8)
            let model = edits.makePreviewModel(plan: plan, context: original)
            let accepted = await presentation.present(model, parent: textView.window, forcePreview: true)
            guard accepted else { return .init(applied: false, failureReason: model.errorMessage ?? "Workspace edit preview cancelled.") }
            guard let operationID = model.appliedOperationID else { return .cancelled }
            let coordinator = tabs.workspaceEditUndoCoordinator(forWorktreeId: original.document.worktreeID, worktreeRoot: root)
            let record = try coordinator.journal.record(operationID)
            guard record.status == .applied else { return .cancelled }
            var applied: [EditorDocumentID: WorkspaceFileSnapshot] = [:]
            for entry in record.entries {
                guard entry.state == .confirmed, let observed = entry.observedAfter else { return .cancelled }
                for snapshot in observed { applied[snapshot.document] = snapshot }
            }
            let generations = tabs.workspaceEditGenerations(host: original.document.host, worktreeID: original.document.worktreeID)
            let access = HostWorkspaceEditFileAccess(tabs: tabs) { [root] document in
                document.host == original.document.host && document.worktreeID == original.document.worktreeID ? root : nil
            }
            var actual: [EditorDocumentID: WorkspaceFileSnapshot] = [:]
            for document in applied.keys { actual[document] = try await access.snapshot(document) }
            let refreshedGenerations = try Self.validatedGenerations(captured: session.generations, current: generations,
                                                                     applied: applied, actual: actual)
            // Only executor-confirmed edits may advance captured generations. Preserve every
            // untouched owner and reject changes during snapshots or synchronization as well.
            guard !Task.isCancelled, id == generation, Data(textView.sourceString.utf8) == expectedText,
                  let refreshed = await synchronize(NSRange(location: 0, length: 0)), refreshed.0 === client,
                  refreshed.1.document == original.document, refreshed.1.serverGeneration == original.serverGeneration,
                  Data(textView.sourceString.utf8) == expectedText, isCurrent(refreshed.1),
                  tabs.workspaceEditGenerations(host: original.document.host, worktreeID: original.document.worktreeID) == refreshedGenerations else { return .cancelled }
            session.context = refreshed.1
            session.generations = refreshedGenerations
            return .init(applied: true)
        } catch { return .init(applied: false, failureReason: RenameFeature.message(for: error)) }
    }
}

@MainActor
private final class CodeActionContext {
    var context: EditorRequestContext
    var generations: [EditorDocumentID: WorkspaceEditBufferGeneration]
    var isApplying = false
    init(context: EditorRequestContext, generations: [EditorDocumentID: WorkspaceEditBufferGeneration]) {
        self.context = context
        self.generations = generations
    }
}

@MainActor
final class CodeActionEditPresentation {
    typealias ShowSheet = (WorkspaceEditPreviewModel, NSWindow, @escaping () -> Void, @escaping () -> Void) -> (() -> Void)
    private let showSheet: ShowSheet
    private var continuation: CheckedContinuation<Bool, Never>?
    private var dismissSheet: (() -> Void)?
    private var model: WorkspaceEditPreviewModel?
    private var activeID: UUID?

    var isPresenting: Bool { continuation != nil }

    init(showSheet: @escaping ShowSheet = CodeActionEditPresentation.showNativeSheet) {
        self.showSheet = showSheet
    }

    func cancel() {
        guard let id = activeID else { return }
        cancel(id: id)
    }

    private func cancel(id: UUID) {
        guard activeID == id else { return }
        model?.cancel()
        finish(id: id, applied: false)
    }

    func present(_ model: WorkspaceEditPreviewModel, parent: NSWindow?, forcePreview: Bool) async -> Bool {
        guard !Task.isCancelled else { return false }
        if !forcePreview, !model.plan.requiresPreview { return await model.apply() }
        guard continuation == nil, let parent, parent.attachedSheet == nil else { return false }
        let id = UUID()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                guard !Task.isCancelled else { continuation.resume(returning: false)
                return }
                activeID = id
                self.continuation = continuation
                self.model = model
                let dismiss = showSheet(model, parent, { [weak self] in
                    self?.finish(id: id, applied: model.didApply)
                }, { [weak self] in self?.cancel(id: id) })
                if activeID == id { dismissSheet = dismiss } else { dismiss() }
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.cancel(id: id) }
        }
    }

    private func finish(id: UUID, applied: Bool) {
        guard activeID == id else { return }
        activeID = nil
        let pending = continuation
        continuation = nil
        model = nil
        let dismiss = dismissSheet
        dismissSheet = nil
        dismiss?()
        pending?.resume(returning: applied)
    }

    private static func showNativeSheet(model: WorkspaceEditPreviewModel, parent: NSWindow,
                                        close: @escaping () -> Void, cancelled: @escaping () -> Void) -> () -> Void {
        let window = NSWindow(contentViewController: NSHostingController(rootView: WorkspaceEditPreview(model: model, close: close, cancel: cancelled)))
        let observer = NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: parent, queue: .main) { _ in
            MainActor.assumeIsolated { cancelled() }
        }
        parent.beginSheet(window) { _ in cancelled() }
        return {
            NotificationCenter.default.removeObserver(observer)
            window.sheetParent?.endSheet(window)
        }
    }
}

@MainActor @Observable
final class CodeActionPickerModel {
    struct Row: Identifiable {
        let id = UUID()
        let action: LSPCodeAction
    }
    let rows: [Row]
    var query = ""
    init(actions: [LSPCodeAction]) { rows = actions.map { Row(action: $0) } }
    var filtered: [Row] {
        rows.filter { query.isEmpty || $0.action.title.localizedCaseInsensitiveContains(query) || ($0.action.kind ?? "").localizedCaseInsensitiveContains(query) }
    }
}

struct CodeActionPicker: View {
    @Bindable var model: CodeActionPickerModel
    let select: (LSPCodeAction) -> Void
    let organizeImports: () -> Void
    let cancel: () -> Void
    @FocusState private var searchFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            TextField("Search code actions", text: $model.query).textFieldStyle(.roundedBorder).focused($searchFocused)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 6) {
                    ForEach(model.filtered) { row in
                        Button { select(row.action) } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(row.action.title + (row.action.isPreferred == true ? " · Preferred" : ""))
                                if let reason = row.action.disabled?.reason { Text(reason).font(.caption).foregroundStyle(.secondary) }
                                else if let kind = row.action.kind { Text(kind).font(.caption).foregroundStyle(.secondary) }
                            }.frame(maxWidth: .infinity, alignment: .leading)
                        }.buttonStyle(.plain).disabled(row.action.disabled != nil).padding(4)
                    }
                    if model.filtered.isEmpty { Text("No code actions").foregroundStyle(.secondary) }
                }
            }.frame(maxHeight: 280)
            HStack {
                Button("Organize Imports", action: organizeImports)
                Spacer()
                Button("Cancel", action: cancel).keyboardShortcut(.cancelAction)
            }
        }.padding(12).frame(width: 380).onAppear { searchFocused = true }
    }
}
