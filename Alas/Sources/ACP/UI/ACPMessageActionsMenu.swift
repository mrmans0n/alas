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
