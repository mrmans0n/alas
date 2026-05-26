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
        let registry: LanguageServerRegistry
        let availability: LanguageServerAvailability
        func status(forLanguage language: String) -> LanguageServerAvailability.Status? {
            guard let entry = registry.allEntries().first(where: { $0.language == language }) else { return nil }
            return availability.status(for: entry)
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

struct EditorTabView: View {
    let worktreePath: URL
    let relativePath: String
    let worktreeId: String
    let tabId: TabID
    let revealLine: Int?
    let revealCharacter: Int?
    let appState: AppState
    let externalAbsolutePath: String?
    let originatingRelativePath: String?
    let onRevealInFiles: (String) -> Void
    @Environment(\.theme) var theme
    @Environment(\.openWindow) private var openWindow

    @State private var findBarVisible: Bool = false
    @State private var findController = EditorFindController()
    @State private var findText: String = ""
    @State private var replaceText: String = ""
    @State private var findBarMessage: String? = nil
    @State private var activeTextView: CodeTextView? = nil
    @FocusState private var findFieldFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            breadcrumb
            if externalAbsolutePath == nil {
                let buffer = appState.tabs.buffer(
                    worktreeId: worktreeId,
                    tabId: tabId,
                    worktreeRoot: worktreePath,
                    relativePath: relativePath
                )
                EditorConflictBanner(buffer: buffer)
            }
            InstallNudgeBanner(appState: appState, absolutePath: nudgeAbsolutePath)
            if findBarVisible {
                EditorFindBarView(
                    findText: $findText,
                    replaceText: $replaceText,
                    message: $findBarMessage,
                    findFieldFocused: $findFieldFocused,
                    onFind: { direction in
                        findController.findString = findText
                        guard !findText.isEmpty else { return }
                        guard let textView = activeTextView else { return }
                        let start: Int
                        switch direction {
                        case .previous:
                            start = textView.selectedRange().location
                        case .next:
                            start = textView.selectedRange().location + textView.selectedRange().length
                        }
                        let range: NSRange?
                        switch direction {
                        case .previous:
                            range = findController.previousMatchRange(upTo: start)
                        case .next:
                            range = findController.nextMatchRange(startingAt: start)
                        }
                        if let range {
                            textView.setSelectedRange(range)
                            textView.scrollRangeToVisible(range)
                        } else {
                            findBarMessage = "No matches"
                        }
                    },
                    onReplace: {
                        findController.findString = findText
                        findController.replacementString = replaceText
                        if findController.replaceCurrent() {
                            findBarMessage = nil
                        } else {
                            findBarMessage = "No matches"
                        }
                    },
                    onReplaceAll: {
                        findController.findString = findText
                        findController.replacementString = replaceText
                        let count = findController.replaceAll()
                        if count == 0 {
                            findBarMessage = "No matches"
                        } else if count == 1 {
                            findBarMessage = "Replaced 1 match"
                        } else {
                            findBarMessage = "Replaced \(count) matches"
                        }
                    },
                    onDone: {
                        findBarVisible = false
                        findBarMessage = nil
                    }
                )
            }
            CodeEditorView(
                worktreeId: worktreeId,
                worktreeRoot: worktreePath,
                relativePath: relativePath,
                tabId: tabId,
                revealLine: revealLine,
                revealCharacter: revealCharacter,
                appState: appState,
                externalAbsolutePath: externalAbsolutePath,
                originatingRelativePath: originatingRelativePath,
                fontFamily: appState.config.code.fontFamily,
                fontSize: appState.config.code.fontSize
            )
        }
        .background(theme.color("bg-1"))
        .onDisappear {
            findBarVisible = false
            findController.textView = nil
            activeTextView = nil
        }
        .onReceive(NotificationCenter.default.publisher(for: .codeEditorDidAttach)) { notification in
            guard let info = notification.userInfo,
                  let notifTabId = info["tabId"] as? TabID,
                  notifTabId == tabId,
                  let textView = info["textView"] as? CodeTextView else { return }
            activeTextView = textView
            findController.textView = textView
        }
        .onReceive(NotificationCenter.default.publisher(for: .codeEditorDidDetach)) { notification in
            guard let info = notification.userInfo,
                  let notifTabId = info["tabId"] as? TabID,
                  notifTabId == tabId else { return }
            activeTextView = nil
            findController.textView = nil
        }
        .onReceive(NotificationCenter.default.publisher(for: .alasShowFindReplace)) { _ in
            guard appState.tabs.activeTabId(forWorktree: worktreeId) == tabId else { return }
            findBarVisible = true
            findFieldFocused = true
        }
    }

    private var nudgeAbsolutePath: String {
        if let abs = externalAbsolutePath { return abs }
        return worktreePath.appendingPathComponent(relativePath).path
    }

    private var breadcrumb: some View {
        let components = relativePath.split(separator: "/")
        let lastIndex = components.count - 1
        return HStack(spacing: 6) {
            if components.isEmpty {
                Text("").font(.system(size: 11, design: .monospaced))
            } else {
                ForEach(Array(components.enumerated()), id: \.offset) { (i, comp) in
                    let pathPrefix = components[0...i].joined(separator: "/")
                    Text(String(comp))
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundColor(i == lastIndex ? theme.color("fg") : theme.color("fg-muted"))
                        .onTapGesture {
                            onRevealInFiles(String(pathPrefix))
                        }
                        .onHover { inside in
                            if inside {
                                NSCursor.pointingHand.push()
                            } else {
                                NSCursor.pointingHand.pop()
                            }
                        }
                    if i < lastIndex {
                        Text("/").foregroundColor(theme.color("fg-faint"))
                    }
                }
            }
            Spacer()
            statusBadge
        }
        .padding(.horizontal, 12).frame(height: 28)
        .background(theme.color("bg-1"))
        .overlay(Divider().opacity(0.5), alignment: .bottom)
    }

    private var statusBadge: some View {
        let buffer = appState.tabs.buffer(
            worktreeId: worktreeId, tabId: tabId,
            worktreeRoot: worktreePath, relativePath: relativePath
        )
        let absolutePath = externalAbsolutePath ?? worktreePath.appendingPathComponent(relativePath).path
        let registry = appState.lsp.activeRegistry
        let availability = LanguageServerAvailability()
        let resolver = EditorLSPStatusResolver(
            manager: LSPStatusProbes.Manager(inner: appState.lsp),
            availability: LSPStatusProbes.Availability(registry: registry, availability: availability),
            registry: LSPStatusProbes.Registry(inner: registry)
        )
        // Touch `stateTick` so SwiftUI re-renders on holder transitions even
        // when the buffer-side state hasn't changed.
        _ = appState.lsp.stateTick

        let status = resolver.resolve(
            absolutePath: absolutePath,
            override: buffer.languageOverride,
            worktreeRoot: worktreePath
        )

        // Compute the override picker's language list only when the popover
        // opens, not on every breadcrumb re-render. Filtering installed
        // languages involves PATH walks and (for sourcekit-lsp) an `xcrun`
        // subprocess — too expensive for a view body that runs many times
        // per second.
        let availableLanguagesProvider: () -> [(language: String, displayName: String)] = {
            let availability = LanguageServerAvailability()
            return registry.allEntries()
                .filter { availability.status(for: $0) == .available }
                .map { ($0.language, RecommendedLanguageCatalog.entry(forLanguage: $0.language)?.displayName ?? $0.language) }
                .sorted { $0.displayName < $1.displayName }
        }

        let openFilesUsingLanguage: Int
        if let lang = status.language {
            openFilesUsingLanguage = appState.lsp.openFilesUsing(language: lang, rootURL: worktreePath)
        } else {
            openFilesUsingLanguage = 0
        }

        return EditorLSPStatusBadge(
            status: status,
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
                buffer.languageOverride = newLanguage
            },
            onOpenSettings: {
                openWindow(id: "settings")
            },
            onInstall: {
                // The existing InstallNudgeBanner below the breadcrumb already
                // handles inline install flows; from the badge popover we
                // surface the install entry via Settings → Code.
                openWindow(id: "settings")
            }
        )
    }
}
