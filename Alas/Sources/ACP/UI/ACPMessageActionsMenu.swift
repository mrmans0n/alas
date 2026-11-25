import AppKit

/// The per-message "…" menu, shared by the SwiftUI gutter button and the
/// native CoreText rows so both offer identical actions.
@MainActor
enum ACPMessageActionsMenu {
    struct Input {
        /// The message's raw Markdown, read when the menu opens and again when
        /// an item runs, so streaming text is never stale.
        let markdown: () -> String
        let createdAt: Date?
        let checkpointID: CheckpointID?
        let forkBoundary: ACPForkMessageBoundary?
        let forkTargets: [ACPSessionForkTarget]
        let onQuote: (String) -> Void
        let onFork: (ACPForkMessageBoundary, String) -> Void
        let onRestoreCheckpoint: (CheckpointID) -> Void
        let messageMenuItems: () -> [ACPMessageMenuItem]
    }

    /// Target of one menu item. `NSMenuItem.target` is weak, so the item keeps
    /// the box alive through `representedObject`.
    private final class ActionBox: NSObject {
        let run: () -> Void
        init(_ run: @escaping () -> Void) { self.run = run }
        @objc func fire(_ sender: NSMenuItem) { run() }
    }

    private static func item(
        _ title: String, image: NSImage? = nil, run: @escaping () -> Void
    ) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: #selector(ActionBox.fire(_:)), keyEquivalent: "")
        let box = ActionBox(run)
        item.target = box
        item.representedObject = box
        item.image = image
        return item
    }

    static func make(_ input: Input) -> NSMenu {
        let menu = NSMenu()
        if let createdAt = input.createdAt {
            let timestampItem = NSMenuItem(
                title: ACPMessageTimestampFormatter.string(for: createdAt), action: nil, keyEquivalent: ""
            )
            timestampItem.isEnabled = false
            menu.addItem(timestampItem)
            menu.addItem(.separator())
        }
        if let checkpointID = input.checkpointID {
            menu.addItem(item("Restore files to before this request") {
                input.onRestoreCheckpoint(checkpointID)
            })
            menu.addItem(.separator())
        }
        menu.addItem(item("Copy message") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(input.markdown(), forType: .string)
        })
        if ACPMessageQuote.canQuote(input.markdown()) {
            menu.addItem(item("Quote") {
                let markdown = input.markdown()
                guard ACPMessageQuote.canQuote(markdown) else { return }
                input.onQuote(markdown)
            })
        }
        if let boundary = input.forkBoundary, !input.forkTargets.isEmpty {
            menu.addItem(.separator())
            let forkItem = NSMenuItem(title: "Fork from here", action: nil, keyEquivalent: "")
            let submenu = NSMenu()
            for target in input.forkTargets {
                let entry = item(
                    target.displayName,
                    image: AgentLogoView.menuImage(assetName: target.logoAssetName, size: 14)
                ) {
                    input.onFork(boundary, target.id)
                }
                if target.isSameAgent {
                    entry.badge = NSMenuItemBadge(string: "Current")
                }
                submenu.addItem(entry)
            }
            forkItem.submenu = submenu
            menu.addItem(forkItem)
        }
        let extras = input.messageMenuItems()
        if !extras.isEmpty {
            menu.addItem(.separator())
            for extra in extras {
                menu.addItem(item(
                    extra.title,
                    image: extra.icon.flatMap { NSImage(systemSymbolName: $0, accessibilityDescription: nil) }
                ) {
                    extra.run(input.markdown())
                })
            }
        }
        return menu
    }
}

/// Editing an earlier user message in place: the agent cuts its conversation
/// back to before the message, the transcript follows, and the message's text
/// returns to the composer to be changed and sent again.
@MainActor
enum ACPMessageEdit {
    static func confirmAndRewind(manager: ACPSessionManager, session: ACPSession, messageID: UUID, text: String) {
        let alert = NSAlert()
        alert.messageText = "Edit this message?"
        alert.informativeText = "This message and everything after it are removed from the conversation, "
            + "and its text returns to the composer. Files are not reverted."
        alert.addButton(withTitle: "Edit")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        Task {
            let result = await manager.rewind(sessionID: session.id, beforeUserMessage: messageID)
            if case .rewound = result {
                session.replaceComposerDraft(.init(segments: [.text(text)]))
            } else {
                session.lastError = failureMessage(result)
            }
        }
    }

    static func failureMessage(_ result: ACPSessionRewindResult) -> String? {
        switch result {
        case .rewound:
            nil
        case .refused(.busy), .notIdle:
            "The message can't be edited while the agent is working or prompts are queued."
        case .refused(.backgroundWork):
            "The message can't be edited while a background task or subagent runs."
        case .refused(.beforeCompaction):
            "The message is before the last compaction, so the agent can't go back to it. Fork from it instead."
        case .refused(.clearedContext):
            "The agent's context was cleared after this message. Fork from it instead."
        case .refused(.providerRefused), .refused(.persistFailed), .refused(.other):
            "The agent could not go back to this message. The conversation is unchanged."
        case .unavailable:
            "This message can't be edited in place."
        case .failed(let message):
            "Editing the message failed: \(message)"
        }
    }
}
