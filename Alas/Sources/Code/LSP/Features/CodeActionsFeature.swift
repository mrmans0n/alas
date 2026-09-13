import AppKit
import Observation
import SwiftUI

@MainActor
final class CodeActionsFeature {
    private weak var textView: CodeTextView?
    private let tabs: TabsManager
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

    func show(range: NSRange, only: [String]? = nil) {
        cancel()
        let id = generation
        task = Task { [weak self] in
            guard let self, let (client, context) = await synchronize(range), id == generation,
                  isCurrent(context), let textView else { return }
            let generations = tabs.workspaceEditGenerations(host: context.document.host, worktreeID: context.document.worktreeID)
            let selectedDiagnostics = Self.diagnostics(diagnostics(), intersecting: context.range)
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
                }, organizeImports: { [weak self] in self?.show(range: range, only: ["source.organizeImports"]) }, cancel: { [weak self] in self?.cancel() }))
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

    private func apply(_ edit: LSPWorkspaceEdit, session: CodeActionContext, client: LSPClient, id: UUID) async -> LSPApplyEditResult {
        guard !Task.isCancelled, isCurrent(session, id: id), !session.isApplying else { return .cancelled }
        session.isApplying = true
        defer { session.isApplying = false }
        do {
            let original = session.context
            let plan = try await edits.prepare(edit, context: original, generations: session.generations)
            guard !Task.isCancelled, id == generation, isCurrent(original), let textView else { return .cancelled }
            let expectedText = plan.finalSnapshots[original.document]?.content ?? Data(textView.string.utf8)
            let model = edits.makePreviewModel(plan: plan, context: original)
            let accepted = await presentation.present(model, parent: textView.window, forcePreview: true)
            guard accepted else { return .init(applied: false, failureReason: model.errorMessage ?? "Workspace edit preview cancelled.") }
            // Our edit may have advanced the initiating buffer. Rebind only to the same server/document
            // and only while its content still equals the plan we just applied.
            guard !Task.isCancelled, id == generation, Data(textView.string.utf8) == expectedText,
                  let refreshed = await synchronize(NSRange(location: 0, length: 0)), refreshed.0 === client,
                  refreshed.1.document == original.document, refreshed.1.serverGeneration == original.serverGeneration,
                  Data(textView.string.utf8) == expectedText, isCurrent(refreshed.1) else { return .cancelled }
            session.context = refreshed.1
            session.generations = tabs.workspaceEditGenerations(host: original.document.host, worktreeID: original.document.worktreeID)
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
    private var continuation: CheckedContinuation<Bool, Never>?
    private var window: NSWindow?
    private var closeObserver: NSObjectProtocol?
    private var model: WorkspaceEditPreviewModel?

    func cancel() { model?.cancel()
    finish(false) }

    func present(_ model: WorkspaceEditPreviewModel, parent: NSWindow?, forcePreview: Bool) async -> Bool {
        guard !Task.isCancelled else { return false }
        if !forcePreview, !model.plan.requiresPreview { return await model.apply() }
        guard continuation == nil, let parent, parent.attachedSheet == nil else { return false }
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                self.continuation = continuation
                self.model = model
                let window = NSWindow(contentViewController: NSHostingController(rootView: WorkspaceEditPreview(model: model) { [weak self] in
                    self?.finish(model.didApply)
                }))
                self.window = window
                closeObserver = NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: parent, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated { self?.cancel() }
                }
                parent.beginSheet(window) { [weak self] _ in self?.finish(model.didApply) }
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.cancel() }
        }
    }

    private func finish(_ applied: Bool) {
        let pending = continuation
        continuation = nil
        if let closeObserver { NotificationCenter.default.removeObserver(closeObserver) }
        closeObserver = nil
        model = nil
        let sheet = window
        window = nil
        if let sheet { sheet.sheetParent?.endSheet(sheet) }
        pending?.resume(returning: applied)
    }
}

@MainActor @Observable
private final class CodeActionPickerModel {
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

private struct CodeActionPicker: View {
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
