import Foundation

/// Chromium and Electron windows read as empty groups until the app builds its web content's
/// Accessibility tree, which it starts on request and finishes a moment later.
public enum ComputerUseWebContent {
    /// Chromium browsers. Like Electron apps they are asked with `AXManualAccessibility` first;
    /// one whose window still shows no web content gets `AXEnhancedUserInterface` (what VoiceOver
    /// sets) as the second resort.
    public static let chromeBundleIDs: Set<String> = [
        "com.google.Chrome", "com.google.Chrome.beta", "com.google.Chrome.dev", "com.google.Chrome.canary",
        "org.chromium.Chromium", "com.microsoft.edgemac", "com.microsoft.edgemac.Beta", "com.microsoft.edgemac.Dev",
        "com.microsoft.edgemac.Canary", "com.brave.Browser", "com.brave.Browser.beta", "com.brave.Browser.nightly",
        "com.vivaldi.Vivaldi", "company.thebrowser.Browser", "com.operasoftware.Opera",
    ]

    public static let manualAccessibility = "AXManualAccessibility"
    public static let enhancedUserInterface = "AXEnhancedUserInterface"

    /// Whether a Chromium browser whose window still shows no web content after the wait for
    /// `manualAccessibility` is asked once more, with `enhancedUserInterface`. That one is app-wide
    /// and slows window moves under window managers, so it is the second resort, and is undone after.
    public static func needsEnhancedUserInterface(bundleID: String?, root: ComputerUseAXNode, cut: ComputerUseReadCut?) -> Bool {
        chromeBundleIDs.contains(bundleID ?? "") && !showsContent(root: root, cut: cut)
    }

    /// The longest a first contact waits for the web content, from the wake.
    public static let contentDeadline: Duration = .milliseconds(1500)

    /// Whether to read the window again after `waited` since the wake, read time included: its
    /// web content isn't there yet (`showsContent`) and the deadline hasn't passed.
    public static func keepsWaiting(
        root: ComputerUseAXNode, cut: ComputerUseReadCut?, waited: Duration, deadline: Duration = contentDeadline
    ) -> Bool {
        !showsContent(root: root, cut: cut) && waited < deadline
    }

    /// Whether the wait after the `manualAccessibility` wake sets it once more, `waited` since the
    /// wake: from halfway to the deadline, once (`reasserted`). An app may still be starting up
    /// when first asked, and miss it.
    public static func reasserts(waited: Duration, reasserted: Bool, deadline: Duration = contentDeadline) -> Bool {
        !reasserted && waited >= deadline / 2
    }

    /// The longest `computer_open_app` waits for a launched web app's front window to show content.
    public static let openDeadline: Duration = .seconds(3)

    /// Whether a read can count as showing the window's content: a web area with something in it,
    /// or a read that left elements unread (`cut`, or `childrenUnread` past its depth), which may
    /// hold the content. Only a complete read without content asks for more.
    public static func showsContent(root: ComputerUseAXNode, cut: ComputerUseReadCut?) -> Bool {
        cut != nil || hasWebContent(root) || hasUnreadChildren(root)
    }

    static func hasUnreadChildren(_ node: ComputerUseAXNode) -> Bool {
        node.childrenUnread || node.children.contains(where: hasUnreadChildren)
    }

    /// Whether Alas turned an attribute on, and so turns it off again at stop, turn end and
    /// session end: it didn't read as true before (`before`, nil when unreadable) and the set took.
    public static func restores(before: Bool?, setSucceeded: Bool) -> Bool {
        before != true && setSucceeded
    }

    /// Whether a read is worth repeating after asking for the web content's tree: the app is a
    /// Chromium or Electron one (`acceptsManualAccessibility`, or a Chromium browser by bundle id),
    /// this is the first such try for it, and the window showed no web content: no web area, or
    /// one without anything in it yet, also in a read cut short.
    public static func needsWake(
        acceptsManualAccessibility: Bool, bundleID: String?, alreadyWoken: Bool, root: ComputerUseAXNode,
        cut: ComputerUseReadCut? = nil
    ) -> Bool {
        guard !alreadyWoken, acceptsManualAccessibility || chromeBundleIDs.contains(bundleID ?? "") else { return false }
        // A read cut short still wakes the app: only content it shows makes the wake needless.
        return !hasWebContent(root)
    }

    /// A web area with something in it.
    public static func hasWebContent(_ node: ComputerUseAXNode) -> Bool {
        (node.role == "AXWebArea" && !node.children.isEmpty) || node.children.contains(where: hasWebContent)
    }
}
