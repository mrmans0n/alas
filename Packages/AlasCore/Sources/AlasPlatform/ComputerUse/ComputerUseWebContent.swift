import Foundation

/// Chromium and Electron windows read as empty groups until the app builds its web content's
/// Accessibility tree, which it starts on request and finishes a moment later.
public enum ComputerUseWebContent {
    /// Chromium browsers, which build their tree for `AXEnhancedUserInterface` (what VoiceOver
    /// sets). Electron apps take `AXManualAccessibility` instead.
    public static let chromeBundleIDs: Set<String> = [
        "com.google.Chrome", "com.google.Chrome.beta", "com.google.Chrome.dev", "com.google.Chrome.canary",
        "org.chromium.Chromium", "com.microsoft.edgemac", "com.microsoft.edgemac.Beta", "com.microsoft.edgemac.Dev",
        "com.microsoft.edgemac.Canary", "com.brave.Browser", "com.brave.Browser.beta", "com.brave.Browser.nightly",
        "com.vivaldi.Vivaldi", "company.thebrowser.Browser", "com.operasoftware.Opera",
    ]

    public static let manualAccessibility = "AXManualAccessibility"
    public static let enhancedUserInterface = "AXEnhancedUserInterface"

    /// Whether a Chromium browser whose window still shows no web area after `manualAccessibility`
    /// and a re-read is asked once more, with `enhancedUserInterface`. That one is app-wide and
    /// slows window moves under window managers, so it is the second resort, and is undone after.
    public static func needsEnhancedUserInterface(bundleID: String?, root: ComputerUseAXNode) -> Bool {
        chromeBundleIDs.contains(bundleID ?? "") && !hasWebArea(root)
    }

    /// Whether Alas turned an attribute on, and so turns it off again at stop, turn end and
    /// session end: it didn't read as true before (`before`, nil when unreadable) and the set took.
    public static func restores(before: Bool?, setSucceeded: Bool) -> Bool {
        before != true && setSucceeded
    }

    /// Whether a read is worth repeating after asking for the web content's tree: the app is a
    /// Chromium or Electron one (`acceptsManualAccessibility`, or a Chromium browser by bundle id),
    /// this is the first such try for it, and the window showed no web area.
    public static func needsWake(
        acceptsManualAccessibility: Bool, bundleID: String?, alreadyWoken: Bool, root: ComputerUseAXNode
    ) -> Bool {
        guard !alreadyWoken, acceptsManualAccessibility || chromeBundleIDs.contains(bundleID ?? "") else { return false }
        return !hasWebArea(root)
    }

    static func hasWebArea(_ node: ComputerUseAXNode) -> Bool {
        node.role == "AXWebArea" || node.children.contains(where: hasWebArea)
    }
}
