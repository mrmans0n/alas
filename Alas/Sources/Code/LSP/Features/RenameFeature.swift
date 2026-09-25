import AppKit
import Observation
import SwiftUI

enum LSPPrepareRenameResult: Decodable, Equatable, Sendable {
    case range(LSPRange, placeholder: String?)
    case defaultBehavior(Bool)

    private enum CodingKeys: String, CodingKey { case range, placeholder, defaultBehavior }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if let value = try container.decodeIfPresent(Bool.self, forKey: .defaultBehavior) {
            self = .defaultBehavior(value)
        } else if let range = try container.decodeIfPresent(LSPRange.self, forKey: .range) {
            self = .range(range, placeholder: try container.decodeIfPresent(String.self, forKey: .placeholder))
        } else {
            self = try .range(LSPRange(from: decoder), placeholder: nil)
        }
    }
}

@MainActor
final class RenameFeature {
    enum Error: LocalizedError {
        case rejected, stale, invalidRange
        var errorDescription: String? {
            switch self {
            case .rejected: "The language server cannot rename this symbol."
            case .stale: "The document changed. Run the command again."
            case .invalidRange: "The language server returned an invalid symbol range."
            }
        }
    }

    struct PreparedSymbol: Equatable {
        let name: String
        let range: NSRange
    }

    private weak var textView: CodeTextView?
    private let tabs: TabsManager
    private let root: URL
    private let synchronize: (NSRange) async -> (LSPClient, EditorRequestContext)?
    private let isCurrent: (EditorRequestContext) -> Bool
    private var popover: NSPopover?
    private var sheet: NSWindow?
    private var task: Task<Void, Never>?
    private var requestID = UUID()

    init(textView: CodeTextView, tabs: TabsManager, root: URL,
         synchronize: @escaping (NSRange) async -> (LSPClient, EditorRequestContext)?,
         isCurrent: @escaping (EditorRequestContext) -> Bool) {
        self.textView = textView
        self.tabs = tabs
        self.root = root
        self.synchronize = synchronize
        self.isCurrent = isCurrent
    }

    static func preparedSymbol(_ result: LSPPrepareRenameResult?, text: String, fallbackRange: NSRange) throws -> PreparedSymbol {
        guard let result else { throw Error.rejected }
        let range: NSRange
        let placeholder: String?
        switch result {
        case .defaultBehavior(true): range = fallbackRange
        placeholder = nil
        case .defaultBehavior(false): throw Error.rejected
        case .range(let value, let name):
            let start = try LSPPositionCodec.offset(value.start, in: text)
            let end = try LSPPositionCodec.offset(value.end, in: text)
            guard start < end else { throw Error.invalidRange }
            range = NSRange(location: start, length: end - start)
            placeholder = name
        }
        guard range.location != NSNotFound, range.location >= 0, range.length > 0,
              NSMaxRange(range) <= (text as NSString).length else { throw Error.invalidRange }
        return PreparedSymbol(name: placeholder ?? (text as NSString).substring(with: range), range: range)
    }

    static func formattingOptions(text: String) -> LSPFormattingOptions {
        let unit = IndentationHelper.indentUnit(in: text)
        return LSPFormattingOptions(tabSize: unit == "\t" ? 4 : unit.count, insertSpaces: unit != "\t")
    }

    static func message(for error: any Swift.Error) -> String {
        if case LSPError.responseError(let response) = error { return response.message }
        return error.localizedDescription
    }

    private func showStatus(_ message: String, severity: InAppNotificationSeverity = .error) {
        textView?.showCommandStatus(message, severity: severity)
    }

    func cancel() {
        requestID = UUID()
        task?.cancel()
        popover?.close()
        popover = nil
    }

    func awaitRequestForTesting() async {
        await task?.value
    }

    func rename(range: NSRange) {
        cancel()
        let id = requestID
        task = Task { [weak self] in
            guard let self, let request = await synchronize(range), let textView,
                  id == requestID, isCurrent(request.1) else { return }
            let text = textView.sourceString
            let generations = tabs.workspaceEditGenerations(host: request.1.document.host, worktreeID: request.1.document.worktreeID)
            let fallback = (text as NSString).rangeOfWord(at: range.location)
            do {
                let preparation: LSPPrepareRenameResult?
                if await request.0.supportsPrepareRename {
                    preparation = try await request.0.prepareRename(uri: request.1.document.uri, position: request.1.range.start)
                } else {
                    preparation = .defaultBehavior(true)
                }
                guard id == requestID, !Task.isCancelled, isCurrent(request.1) else { return }
                let symbol = try Self.preparedSymbol(preparation, text: text, fallbackRange: fallback)
                let model = RenameNameModel(name: symbol.name)
                let popover = NSPopover()
                popover.behavior = .applicationDefined
                popover.contentViewController = NSHostingController(rootView: RenameNameView(model: model, cancel: { [weak self] in self?.cancel() }, submit: { [weak self] in
                    guard let self, !model.isRequesting else { return }
                    model.isRequesting = true
                    model.errorMessage = nil
                    self.task = Task { [weak self] in
                        guard let self else { return }
                        defer { model.isRequesting = false }
                        do {
                            guard id == requestID, isCurrent(request.1) else { throw Error.stale }
                            let edit = try await request.0.rename(uri: request.1.document.uri, position: request.1.range.start, newName: model.name)
                            guard id == requestID, !Task.isCancelled else { return }
                            guard let edit else { model.errorMessage = "The language server returned no rename changes."
                            return }
                            let plan = try await prepare(edit, context: request.1, generations: generations)
                            self.popover?.close()
                            self.popover = nil
                            await presentOrApply(plan, context: request.1)
                        } catch { model.errorMessage = Self.message(for: error) }
                    }
                }))
                guard textView.window != nil else { return }
                self.popover = popover
                popover.show(relativeTo: textView.symbolAnchorRect(for: symbol.range) ?? .zero, of: textView, preferredEdge: .maxY)
            } catch { showStatus(Self.message(for: error)) }
        }
    }

    func format(range: NSRange, selectionOnly: Bool) {
        cancel()
        let id = requestID
        task = Task { [weak self] in
            guard let self, let request = await synchronize(range), let textView,
                  id == requestID, isCurrent(request.1) else { return }
            let generations = tabs.workspaceEditGenerations(host: request.1.document.host, worktreeID: request.1.document.worktreeID)
            let options = Self.formattingOptions(text: textView.sourceString)
            do {
                let edits = try await selectionOnly
                    ? request.0.rangeFormatting(uri: request.1.document.uri, range: request.1.range, options: options)
                    : request.0.formatting(uri: request.1.document.uri, options: options)
                guard id == requestID, !Task.isCancelled else { return }
                let plan = try await prepare(.init(changes: [request.1.document.uri: edits]), context: request.1, generations: generations)
                await presentOrApply(plan, context: request.1)
            } catch { showStatus(Self.message(for: error)) }
        }
    }

    func prepare(_ edit: LSPWorkspaceEdit, context: EditorRequestContext,
                         generations: [EditorDocumentID: WorkspaceEditBufferGeneration]) async throws -> WorkspaceEditPlan {
        guard isCurrent(context) else { throw Error.stale }
        let access = HostWorkspaceEditFileAccess(tabs: tabs) { [root] document in
            document.host == context.document.host && document.worktreeID == context.document.worktreeID ? root : nil
        }
        try access.validateRequestGenerations(generations)
        let documents = try Self.documents(in: edit, context: context)
        try WorkspaceEditSnapshotBudget.validateTargetCount(documents.count)
        var budget = WorkspaceEditSnapshotBudget()
        var snapshots: [EditorDocumentID: WorkspaceFileSnapshot] = [:]
        for document in documents {
            let snapshot = try await access.snapshot(document)
            guard !snapshot.isOpen || generations[document] != nil else { throw Error.stale }
            try budget.retain(snapshot)
            snapshots[document] = snapshot
        }
        guard !Task.isCancelled, isCurrent(context) else { throw Error.stale }
        try access.validateRequestGenerations(generations)
        return try WorkspaceEditPlanner.plan(edit: edit, context: context, snapshots: snapshots)
    }

    static func documents(in edit: LSPWorkspaceEdit, context: EditorRequestContext) throws -> Set<EditorDocumentID> {
        var uris = Set(edit.changes?.keys.map { $0 } ?? [])
        for change in edit.documentChanges ?? [] {
            switch change {
            case .textDocument(let document, _): uris.insert(document.uri)
            case .create(let uri, _, _), .delete(let uri, _, _): uris.insert(uri)
            case .rename(let oldURI, let newURI, _, _): uris.formUnion([oldURI, newURI])
            }
        }
        return try Set(uris.map { uri in
            guard let url = URL(string: uri), url.isFileURL,
                  url.host == nil || url.host == "" || url.host == "localhost" else { throw WorkspaceEditPlanner.Error.unsupportedURI }
            return EditorDocumentID(host: context.document.host, worktreeID: context.document.worktreeID, uri: uri)
        })
    }

    func makePreviewModel(plan: WorkspaceEditPlan, context: EditorRequestContext,
                          reportOutcome: Bool = false) -> WorkspaceEditPreviewModel {
        let coordinator = tabs.workspaceEditUndoCoordinator(
            forWorktreeId: context.document.worktreeID,
            worktreeRoot: root,
            host: context.document.host
        )
        let notifications = textView?.notificationStore
        return WorkspaceEditPreviewModel(plan: plan) { [isCurrent] plan in
            let outcome: WorkspaceEditOutcome
            if isCurrent(context) {
                outcome = await coordinator.executor.apply(plan)
            } else {
                outcome = .conflict([context.document])
            }
            if case .applied(let id) = outcome {
                // The initiating editor owns an accessible undo entry even
                // when every edited target is unopened. Inverse writes still
                // come exclusively from the confirmed plan journal.
                let affected = Set(plan.steps.flatMap { [$0.document, $0.destination].compactMap { $0 } })
                coordinator.register(operationID: id, affectedDocuments: affected, initiatingDocument: context.document)
            }
            if reportOutcome {
                let error = WorkspaceEditPreviewModel.message(for: outcome)
                notifications?.post(error ?? "Changes applied", severity: error == nil ? .success : .error,
                                    worktreeID: context.document.worktreeID)
            }
            return outcome
        }
    }

    private func presentOrApply(_ plan: WorkspaceEditPlan, context: EditorRequestContext) async {
        guard plan.steps.contains(where: { $0.before.content != $0.after.content || $0.kind != .text }) else {
            showStatus("No changes", severity: .information)
            return
        }
        let model = makePreviewModel(plan: plan, context: context, reportOutcome: true)
        if plan.requiresPreview {
            guard let parent = textView?.window, parent.attachedSheet == nil else {
                showStatus("Close the current sheet and run the command again.")
                return
            }
            let window = NSWindow(contentViewController: NSHostingController(rootView: WorkspaceEditPreview(model: model) { [weak self, weak parent] in
                guard let window = parent?.attachedSheet else { return }
                parent?.endSheet(window)
                self?.sheet = nil
            }))
            sheet = window
            parent.beginSheet(window, completionHandler: nil)
        } else {
            _ = await model.apply()
        }
    }
}

@MainActor @Observable
final class RenameNameModel {
    var name: String
    var errorMessage: String?
    var isRequesting = false
    init(name: String) { self.name = name }
}

struct RenameNameView: View {
    @Bindable var model: RenameNameModel
    let cancel: () -> Void
    let submit: () -> Void
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Rename symbol").font(.headline)
            TextField("New name", text: $model.name).focused($focused).onSubmit { if canSubmit { submit() } }
                .disabled(model.isRequesting)
            if let error = model.errorMessage { Text(error).font(.caption).foregroundStyle(.red).textSelection(.enabled) }
            HStack {
                Button("Cancel", action: cancel).keyboardShortcut(.cancelAction)
                Spacer()
                if model.isRequesting { ProgressView().controlSize(.small) }
                Button("Rename", action: submit).keyboardShortcut(.defaultAction).disabled(!canSubmit)
            }
        }
        .padding(12).frame(width: 300)
        .onAppear { focused = true }
    }

    private var canSubmit: Bool { !model.isRequesting && !model.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
}
