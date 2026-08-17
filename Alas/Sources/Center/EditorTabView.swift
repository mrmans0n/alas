import SwiftUI
import AppKit

private struct LSPStatusProbes {
    struct Manager: EditorLSPStatusResolver.ManagerProbe {
        let inner: WorkspaceLSPManager
        @MainActor
        func documentStatus(forFile fileURL: URL, worktreeRoot: URL) -> WorkspaceLSPManager.DocumentStatus {
            inner.documentStatus(forFile: fileURL, worktreeRoot: worktreeRoot)
        }
    }

    struct Availability: EditorLSPStatusResolver.AvailabilityProbe {
        let manager: WorkspaceLSPManager
        let registry: LanguageServerRegistry
        @MainActor
        func status(forLanguage language: String) -> LanguageServerAvailability.Status? {
            manager.availabilityStatus(forLanguage: language)
        }
        func command(forLanguage language: String) -> String? {
            registry.allEntries().first(where: { $0.language == language })?.command
        }
    }

    struct Registry: EditorLSPStatusResolver.RegistryProbe {
        let inner: LanguageServerRegistry
        func language(forFileExtension ext: String) -> String? {
            inner.language(forFileExtension: ext)
        }
    }
}

private enum EditorFindPresentation: Equatable {
    case hidden
    case find
    case replace
}

struct EditorTabView: View {
    let worktree: Worktree
    let worktreePath: URL
    let relativePath: String
    let worktreeId: String
    let tabId: TabID
    let revealLine: Int?
    var revealEndLine: Int? = nil
    let revealCharacter: Int?
    let revealRevision: Int?
    let appState: AppState
    let externalAbsolutePath: String?
    var externalEditable: Bool = false
    let originatingRelativePath: String?
    let onRevealInFiles: (String) -> Void
    @Environment(\.theme) var theme
    @Environment(\.openWindow) private var openWindow

    @State private var findPresentation: EditorFindPresentation = .hidden
    @State private var findController = EditorFindController()
    @State private var findText: String = ""
    @State private var replaceText: String = ""
    @State private var isCaseSensitive: Bool = false
    @State private var findStatusText: String = ""
    @State private var findHighlightRenderer = EditorFindHighlightRenderer()
    @State private var activeTextView: CodeTextView? = nil
    @State private var fallbackEscapeHandler: (() -> Bool)? = nil
    @FocusState private var findFieldFocused: Bool
    @FocusState private var replaceFieldFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            BreadcrumbView(
                relativePath: breadcrumbRelativePath,
                onRevealInFiles: onRevealInFiles,
                menuItems: { index, pathPrefix in
                    let isLast = index == breadcrumbRelativePath.split(separator: "/").count - 1
                    let isRemote = worktreePath.isRemoteAlasPath
                    if isLast {
                        return .file(BreadcrumbFileMenu(
                            onViewAtHEAD: externalAbsolutePath == nil
                                ? { appState.openFileSnapshotAtHEAD(relativePath: relativePath, worktreeId: worktreeId) }
                                : nil,
                            onCompareWithHEAD: externalAbsolutePath == nil
                                ? { appState.openDiffTab(
                                    forFileInWorktree: worktree,
                                    relativePath: relativePath,
                                    originalPath: nil,
                                    compareWithHEAD: true
                                  ) }
                                : nil,
                            onFileHistory: externalAbsolutePath == nil
                                ? { appState.openFileHistory(relativePath: relativePath, worktreeId: worktreeId) }
                                : nil,
                            onCopyRelativePath: externalAbsolutePath == nil ? { Clipboard.copy(relativePath) } : nil,
                            onCopyFullPath: { Clipboard.copy(absoluteFilePath) },
                            onRevealInFinder: isRemote ? nil : { FileSystemOpen.reveal(url: absoluteFileURL) },
                            onOpenWithSystem: isRemote ? nil : { FileSystemOpen.open(url: absoluteFileURL) }
                        ))
                    } else {
                        let folderURL: URL
                        if externalAbsolutePath != nil {
                            folderURL = URL(fileURLWithPath: pathPrefix)
                        } else {
                            folderURL = worktreePath.appendingPathComponent(pathPrefix)
                        }
                        return .folder(BreadcrumbFolderMenu(
                            onRevealInFinder: isRemote ? nil : { FileSystemOpen.reveal(url: folderURL) },
                            onFocusInFiles: externalAbsolutePath == nil ? { onRevealInFiles(pathPrefix) } : nil,
                            onCopyFullPath: { Clipboard.copy(folderURL.path) }
                        ))
                    }
                },
                trailing: AnyView(statusBadge)
            )
            if isBinary {
                binaryPlaceholder
            } else {
                if Self.shouldShowConflictBanner(
                    externalAbsolutePath: externalAbsolutePath,
                    externalEditable: externalEditable
                ) {
                    EditorConflictBanner(buffer: conflictBannerBuffer)
                }
                InstallNudgeBanner(appState: appState, absolutePath: nudgeAbsolutePath)
                BlockedNudgeBanner(appState: appState, absolutePath: nudgeAbsolutePath)
                if findPresentation != .hidden {
                    EditorFindBarView(
                        findText: $findText,
                        replaceText: $replaceText,
                        isCaseSensitive: $isCaseSensitive,
                        findFieldFocused: $findFieldFocused,
                        replaceFieldFocused: $replaceFieldFocused,
                        showsReplace: findPresentation == .replace,
                        statusText: findStatusText,
                        canReplace: canReplaceMatches,
                        onFindChanged: refreshFindFromUserInput,
                        onToggleCaseSensitive: toggleCaseSensitive,
                        onFind: navigateFind,
                        onReplace: replaceCurrentMatch,
                        onReplaceAll: replaceAllMatches,
                        onDone: closeFindBar
                    )
                }
                CodeEditorView(
                    worktreeId: worktreeId,
                    worktreeRoot: worktreePath,
                    relativePath: relativePath,
                    tabId: tabId,
                    revealLine: revealLine,
                    revealEndLine: revealEndLine,
                    revealCharacter: revealCharacter,
                    revealRevision: revealRevision,
                    appState: appState,
                    externalAbsolutePath: externalAbsolutePath,
                    externalEditable: externalEditable,
                    originatingRelativePath: originatingRelativePath,
                    fontFamily: appState.config.code.fontFamily,
                    fontSize: appState.config.code.fontSize,
                    showLineNumbers: appState.config.code.showLineNumbers,
                    textRendering: CodeEditorTextRenderingConfiguration(code: appState.config.code),
                    onTextViewAttached: { attachFindController(to: $0) },
                    onTextViewDetached: { detachFindController(from: $0) }
                )
            }
        }
        .background(theme.color("bg-1"))
        .onDisappear {
            clearFindHighlights()
            activeTextView?.escapeHandler = nil
            fallbackEscapeHandler = nil
            findPresentation = .hidden
            findStatusText = ""
            findController.textView = nil
            activeTextView = nil
        }
        .onReceive(NotificationCenter.default.publisher(for: .alasShowFindReplace)) { notification in
            handleFindRequest(notification)
        }
        .onReceive(NotificationCenter.default.publisher(for: NSText.didChangeNotification)) { notification in
            guard let textView = notification.object as? CodeTextView,
                  textView === activeTextView else { return }
            handleEditorTextChanged()
        }
    }

    private func attachFindController(to textView: CodeTextView) {
        clearFindHighlights()
        if activeTextView !== textView {
            activeTextView?.escapeHandler = fallbackEscapeHandler
            fallbackEscapeHandler = textView.escapeHandler
        }
        activeTextView = textView
        findController.textView = textView
        findHighlightRenderer.attach(textView: textView)
        installEscapeHandler(on: textView)
        let selection: EditorFindController.RefreshSelection =
            findPresentation == .hidden || findText.isEmpty ? .none : .nearestFromSelection
        refreshFindMatches(selecting: selection)
    }

    private func detachFindController(from textView: CodeTextView?) {
        if let textView, activeTextView !== textView { return }
        clearFindHighlights()
        activeTextView?.escapeHandler = nil
        fallbackEscapeHandler = nil
        activeTextView = nil
        findController.textView = nil
    }

    private func handleFindRequest(_ notification: Notification) {
        guard appState.tabs.activeTabId(forWorktree: worktreeId) == tabId else { return }

        let request = notification.object as? EditorFindRequest ?? .showReplace
        switch request {
        case .showFind:
            showFindBar(.find, prefillFromSelection: true)
            focusFindField()
        case .showReplace:
            showFindBar(.replace, prefillFromSelection: true)
            if findText.isEmpty {
                focusFindField()
            } else {
                focusReplaceField()
            }
        case .findNext:
            if findPresentation == .hidden {
                showFindBarForNavigation()
            }
            navigateFind(.next)
        case .findPrevious:
            if findPresentation == .hidden {
                showFindBarForNavigation()
            }
            navigateFind(.previous)
        }
    }

    private func showFindBar(_ presentation: EditorFindPresentation, prefillFromSelection: Bool) {
        if prefillFromSelection, let selectedText = selectedSingleLineText() {
            findText = selectedText
        }

        findPresentation = presentation
        refreshFindMatches(selecting: findText.isEmpty ? .none : .nearestFromSelection)
    }

    private func showFindBarForNavigation() {
        findPresentation = .find
        refreshFindMatches(selecting: .none)
    }

    private func refreshFindFromUserInput() {
        refreshFindMatches(selecting: findText.isEmpty ? .none : .nearestFromSelection)
    }

    private func toggleCaseSensitive() {
        refreshFindMatches(selecting: findText.isEmpty ? .none : .nearestFromSelection)
    }

    private func navigateFind(_ direction: EditorFindBarView.FindDirection) {
        syncFindController()
        guard !findText.isEmpty else {
            findController.refreshMatches(selecting: .none)
            updateFindStatus()
            focusFindField()
            return
        }

        let anchor = navigationAnchor(for: direction)
        findController.refreshMatches(selecting: .none)
        guard findController.matchCount > 0 else {
            updateFindStatus()
            return
        }

        if let anchor {
            selectMatch(around: anchor, direction: direction)
        } else {
            switch direction {
            case .previous:
                _ = findController.selectPrevious()
            case .next:
                _ = findController.selectNext()
            }
        }
        updateFindStatus()
    }

    private func replaceCurrentMatch() {
        syncFindController()
        guard activeTextView?.isEditable == true else {
            findStatusText = findText.isEmpty ? "" : "Read-only"
            renderFindHighlights()
            return
        }
        let didReplace = findController.replaceCurrent()
        if didReplace {
            updateFindStatus()
        } else {
            findStatusText = findText.isEmpty ? "" : "No matches"
            renderFindHighlights()
        }
    }

    private func replaceAllMatches() {
        syncFindController()
        guard activeTextView?.isEditable == true else {
            findStatusText = findText.isEmpty ? "" : "Read-only"
            renderFindHighlights()
            return
        }
        let count = findController.replaceAll()
        if count == 0 {
            findStatusText = findText.isEmpty ? "" : "No matches"
        } else if count == 1 {
            findStatusText = "Replaced 1 match"
        } else {
            findStatusText = "Replaced \(count) matches"
        }
        renderFindHighlights()
    }

    private func closeFindBar() {
        findPresentation = .hidden
        findStatusText = ""
        clearFindHighlights()
        findFieldFocused = false
        replaceFieldFocused = false
        activeTextView?.window?.makeFirstResponder(activeTextView)
    }

    private func refreshFindMatches(selecting selection: EditorFindController.RefreshSelection) {
        syncFindController()
        findController.refreshMatches(selecting: selection)
        updateFindStatus()
    }

    private func syncFindController() {
        findController.findString = findText
        findController.replacementString = replaceText
        findController.isCaseSensitive = isCaseSensitive
    }

    private var canReplaceMatches: Bool {
        findController.canReplace && activeTextView?.isEditable == true
    }

    private func handleEditorTextChanged() {
        guard findPresentation != .hidden else { return }
        syncFindController()
        _ = findController.countMatches()
        updateFindStatus()
    }

    private func updateFindStatus() {
        guard !findText.isEmpty else {
            findStatusText = ""
            clearFindHighlights()
            return
        }
        guard findController.matchCount > 0 else {
            findStatusText = "No matches"
            clearFindHighlights()
            return
        }
        if let activeMatchNumber = findController.activeMatchNumber {
            findStatusText = "\(activeMatchNumber) of \(findController.matchCount)"
        } else {
            findStatusText = ""
        }
        renderFindHighlights()
    }

    private func installEscapeHandler(on textView: CodeTextView) {
        let fallbackEscapeHandler = fallbackEscapeHandler
        textView.escapeHandler = {
            if findPresentation != .hidden {
                closeFindBar()
                return true
            }
            return fallbackEscapeHandler?() ?? false
        }
    }

    private func renderFindHighlights() {
        guard findPresentation != .hidden, !findText.isEmpty else {
            clearFindHighlights()
            return
        }
        findHighlightRenderer.render(
            matches: findController.matches,
            activeIndex: findController.activeMatchIndex,
            inactiveColor: NSColor.systemYellow.withAlphaComponent(0.28),
            activeColor: NSColor.systemOrange.withAlphaComponent(0.38)
        )
    }

    private func clearFindHighlights() {
        findHighlightRenderer.clear()
    }

    private func navigationAnchor(for direction: EditorFindBarView.FindDirection) -> Int? {
        guard let textView = activeTextView else { return nil }
        let selection = textView.selectedRange()
        let textLength = (textView.string as NSString).length
        guard selection.location != NSNotFound,
              selection.location >= 0,
              NSMaxRange(selection) <= textLength else { return nil }

        switch direction {
        case .previous:
            return selection.location
        case .next:
            return NSMaxRange(selection)
        }
    }

    private func selectMatch(around location: Int, direction: EditorFindBarView.FindDirection) {
        guard !findController.matches.isEmpty else { return }

        let index: Int
        switch direction {
        case .previous:
            index = findController.matches.lastIndex { $0.location < location }
                ?? findController.matches.count - 1
        case .next:
            index = findController.matches.firstIndex { $0.location >= location }
                ?? 0
        }
        _ = findController.selectMatch(at: index)
    }

    private func selectedSingleLineText() -> String? {
        guard let textView = activeTextView else { return nil }
        guard textView.selectedRanges.count == 1 else { return nil }
        let selectedRange = textView.selectedRange()
        guard selectedRange.location != NSNotFound, selectedRange.length > 0 else { return nil }

        let text = textView.string as NSString
        guard selectedRange.location >= 0, NSMaxRange(selectedRange) <= text.length else { return nil }

        let selectedText = text.substring(with: selectedRange)
        guard !selectedText.isEmpty,
              selectedText.rangeOfCharacter(from: .newlines) == nil else { return nil }
        return selectedText
    }

    private func focusFindField() {
        replaceFieldFocused = false
        findFieldFocused = true
    }

    private func focusReplaceField() {
        findFieldFocused = false
        replaceFieldFocused = true
    }

    private var nudgeAbsolutePath: String {
        absoluteFilePath
    }

    static func shouldShowConflictBanner(externalAbsolutePath: String?, externalEditable: Bool) -> Bool {
        externalAbsolutePath == nil || externalEditable
    }

    private var conflictBannerBuffer: EditorBuffer {
        if let externalAbsolutePath {
            return appState.tabs.externalBuffer(
                worktreeId: worktreeId,
                tabId: tabId,
                absoluteURL: URL(fileURLWithPath: externalAbsolutePath),
                worktreeRoot: worktreePath,
                originatingFileURL: originatingRelativePath.map { worktreePath.appendingPathComponent($0) },
                editable: externalEditable
            )
        }
        return appState.tabs.buffer(
            worktreeId: worktreeId,
            tabId: tabId,
            worktreeRoot: worktreePath,
            relativePath: relativePath
        )
    }

    private var breadcrumbRelativePath: String {
        externalAbsolutePath ?? relativePath
    }

    private var absoluteFilePath: String {
        if let abs = externalAbsolutePath { return abs }
        return worktreePath.appendingPathComponent(relativePath).path
    }

    private var absoluteFileURL: URL {
        URL(fileURLWithPath: absoluteFilePath)
    }

    private var isBinary: Bool {
        if externalAbsolutePath != nil {
            return appState.tabs.peekExternalBuffer(tabId: tabId)?.loadKind == .notUTF8
        }
        return appState.tabs.peekBuffer(tabId: tabId)?.loadKind == .notUTF8
    }

    private var binaryPlaceholder: some View {
        VStack(spacing: 12) {
            Image(systemName: "doc.fill")
                .font(.system(size: 30))
                .foregroundColor(theme.color("fg-faint"))
            Text((breadcrumbRelativePath as NSString).lastPathComponent)
                .font(.system(size: 15, weight: .semibold))
                .foregroundColor(theme.color("fg"))
            Text("Binary file")
                .font(.system(size: 12))
                .foregroundColor(theme.color("fg-dim"))
            if !worktreePath.isRemoteAlasPath {
                HStack(spacing: 10) {
                    Button("Open with System") { FileSystemOpen.open(url: absoluteFileURL) }
                    Button("Reveal in Finder") { FileSystemOpen.reveal(url: absoluteFileURL) }
                }
                .padding(.top, 4)
            }
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var statusBadge: some View {
        // External editor tabs (SDK files, opened via cmd-click) don't
        // support runtime override: `EditorBuffer.applyEffectiveLanguageToLSP`
        // bails for `isExternal == true`, so the override wouldn't actually
        // re-route LSP traffic. We also avoid calling `tabs.externalBuffer`
        // here because it has side effects (startWatching, ensureExternalLSPOpen)
        // that would refire on every breadcrumb re-render. The override
        // picker is hidden via `supportsOverride: false` so the user isn't
        // offered a no-op action.
        let isExternal = externalAbsolutePath != nil
        let buffer: EditorBuffer? = isExternal ? nil : appState.tabs.buffer(
            worktreeId: worktreeId, tabId: tabId,
            worktreeRoot: worktreePath, relativePath: relativePath
        )
        let absolutePath = externalAbsolutePath ?? worktreePath.appendingPathComponent(relativePath).path
        let registry = appState.lsp.activeRegistry
        let resolver = EditorLSPStatusResolver(
            manager: LSPStatusProbes.Manager(inner: appState.lsp),
            availability: LSPStatusProbes.Availability(manager: appState.lsp, registry: registry),
            registry: LSPStatusProbes.Registry(inner: registry)
        )
        // Touch `stateTick` so SwiftUI re-renders on holder transitions even
        // when the buffer-side state hasn't changed.
        _ = appState.lsp.stateTick

        let status = resolver.resolve(
            absolutePath: absolutePath,
            override: buffer?.languageOverride,
            worktreeRoot: worktreePath
        )

        // Compute the override picker's language list only when the popover
        // opens, not on every breadcrumb re-render. Filtering installed
        // languages involves PATH walks and (for sourcekit-lsp) an `xcrun`
        // subprocess — too expensive for a view body that runs many times
        // per second.
        let manager = appState.lsp
        let availableLanguagesProvider: @MainActor () -> [(language: String, displayName: String)] = {
            registry.allEntries()
                .filter { manager.availabilityStatus(forLanguage: $0.language) == .available }
                .map { ($0.language, RecommendedLanguageCatalog.entry(forLanguage: $0.language)?.displayName ?? $0.language) }
                .sorted { $0.displayName < $1.displayName }
        }

        let openFilesUsingLanguage: Int = status.language == nil
            ? 0
            : appState.lsp.openFilesUsing(forFile: URL(fileURLWithPath: absolutePath), worktreeRoot: worktreePath)

        return EditorLSPStatusBadge(
            status: status,
            supportsOverride: !isExternal,
            availableLanguages: availableLanguagesProvider,
            openFilesUsingLanguage: openFilesUsingLanguage,
            onRestart: {
                guard let lang = status.language else { return }
                let fileURL = URL(fileURLWithPath: absolutePath)
                Task { @MainActor in
                    await appState.lsp.restartHolder(
                        forFile: fileURL,
                        worktreeRoot: worktreePath,
                        languageId: lang
                    )
                }
            },
            onOverride: { newLanguage in
                buffer?.languageOverride = newLanguage
            },
            onOpenSettings: {
                appState.pendingSettingsSection = .code
                openWindow(id: "settings")
            },
            onInstall: {
                // The existing InstallNudgeBanner below the breadcrumb already
                // handles inline install flows; from the badge popover we
                // surface the install entry via Settings → Code.
                appState.pendingSettingsSection = .code
                openWindow(id: "settings")
            }
        )
    }
}
