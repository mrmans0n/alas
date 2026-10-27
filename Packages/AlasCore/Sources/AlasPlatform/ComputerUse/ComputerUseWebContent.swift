import Foundation

/// Chromium and Electron windows read as empty groups until the app builds its web content's
/// Accessibility tree, which it starts on request and finishes a moment later.
public enum ComputerUseWebContent {
    /// Chromium browsers. Like Electron apps they are asked with `AXManualAccessibility`; one that
    /// doesn't have the attribute gets `AXEnhancedUserInterface` (what VoiceOver sets) instead.
    public static let chromeBundleIDs: Set<String> = [
        "com.google.Chrome", "com.google.Chrome.beta", "com.google.Chrome.dev", "com.google.Chrome.canary",
        "org.chromium.Chromium", "com.microsoft.edgemac", "com.microsoft.edgemac.Beta", "com.microsoft.edgemac.Dev",
        "com.microsoft.edgemac.Canary", "com.brave.Browser", "com.brave.Browser.beta", "com.brave.Browser.nightly",
        "com.vivaldi.Vivaldi", "company.thebrowser.Browser", "com.operasoftware.Opera",
    ]

    public static let manualAccessibility = "AXManualAccessibility"

    /// A Chromium browser (by bundle id) or an Electron app (one that took `manualAccessibility`).
    public static func isChromium(bundleID: String?, acceptsManualAccessibility: Bool) -> Bool {
        acceptsManualAccessibility || chromeBundleIDs.contains(bundleID ?? "")
    }
    public static let enhancedUserInterface = "AXEnhancedUserInterface"

    /// How setting an attribute went.
    public enum SetResult: Equatable, Sendable {
        case set
        /// The app won't take it: it has no such attribute, doesn't implement setting it, or
        /// can't be messaged. Asking again is pointless.
        case unsupported
        /// The app busy, or not answering yet (still starting): it may take it later.
        case failed
    }

    /// The `SetResult` of an `AXError`'s raw value: success; `cannotComplete` (-25204) and
    /// `failure` (-25200), which pass once an app is up, are worth another try; anything else
    /// (`attributeUnsupported` -25205, `notImplemented` -25208, `apiDisabled`, an invalid element)
    /// isn't.
    public static func setResult(_ error: Int32) -> SetResult {
        switch error {
        case 0: .set
        case -25204, -25200: .failed
        default: .unsupported
        }
    }

    /// A wake: how its set went, and whether Alas turned the attribute on (`restores`), so it is
    /// turned off again.
    public struct Wake: Equatable, Sendable {
        public var result: SetResult
        public var turnedOn: Bool
        /// The AXError's raw value when the set didn't take.
        public var error: Int32?

        public init(result: SetResult, turnedOn: Bool, error: Int32? = nil) {
            self.result = result
            self.turnedOn = turnedOn
            self.error = error
        }
    }

    /// What follows a set of `attribute` during a first contact.
    public enum NextSet: Equatable, Sendable {
        /// It took: wait for the content, asking again halfway.
        case accepted
        /// It failed in a way that may pass (an app still starting): set it again at the next
        /// poll, within the wait's deadline.
        case retry
        /// The app won't take it: set this one instead, at once.
        case fallBack(String)
        /// Nothing more to ask with: the wait for the content goes on without asking again (a
        /// browser also builds its tree as it is read).
        case waitOnly
    }

    /// After a set of `attribute` came to `result`: `manualAccessibility` falls back to
    /// `enhancedUserInterface` only in a Chromium browser that doesn't have it
    /// (`fallsBackToEnhancedUserInterface`).
    public static func next(after result: SetResult, of attribute: String, bundleID: String?) -> NextSet {
        switch result {
        case .set: .accepted
        case .failed: .retry
        case .unsupported:
            attribute == manualAccessibility && fallsBackToEnhancedUserInterface(after: .unsupported, bundleID: bundleID)
                ? .fallBack(enhancedUserInterface) : .waitOnly
        }
    }

    /// Whether a Chromium browser is asked with `enhancedUserInterface` after `manualAccessibility`:
    /// only when it doesn't have that attribute, as current Chrome doesn't. A failure that may
    /// pass isn't a reason: the app may just be starting, and is asked again (`next`). The
    /// attribute is app-wide and slows window moves under window managers, so it is undone after.
    public static func fallsBackToEnhancedUserInterface(after manual: SetResult, bundleID: String?) -> Bool {
        manual == .unsupported && chromeBundleIDs.contains(bundleID ?? "")
    }

    /// The longest a first contact waits for the web content, from the wake: Chrome builds its
    /// web tree seconds after a fresh launch.
    public static let contentDeadline: Duration = .seconds(4)

    /// How many elements the wait's look for a web area with content reads (`findsWebContent`):
    /// the page's web area sits under a toolbar of a few hundred.
    public static let probeNodes = 3000

    /// Whether a web area with content is among `root`'s descendants, looked for breadth first
    /// through at most `budget` elements, reading only each one's role and children, and stopping
    /// at the first web area with children; a menu bar is skipped. False once `halted` (a
    /// deadline, a stop), or when the budget runs out first.
    public static func findsWebContent<Element>(
        from root: Element, budget: Int, role: (Element) -> String?, children: (Element) -> [Element],
        halted: () -> Bool = { false }
    ) -> Bool {
        var level = [root]
        var read = 0
        while !level.isEmpty {
            var next: [Element] = []
            for element in level {
                read += 1
                guard read <= budget, !halted() else { return false }
                let role = role(element)
                if halted() { return false }
                if role == "AXMenuBar" { continue }
                let below = children(element)
                if role == "AXWebArea", !below.isEmpty { return true }
                next += below
            }
            level = next
        }
        return false
    }

    /// Once the web content shows, how long it is left to fill in before the window is read.
    public static let contentSettle: Duration = .milliseconds(500)

    /// Whether to look at the window again after `waited` since the wake, look time included:
    /// it shows no web area with content yet (`showsContent`) and the deadline hasn't passed. A
    /// look cut short counts only for what it found.
    public static func keepsWaiting(showsContent: Bool, waited: Duration, deadline: Duration = contentDeadline) -> Bool {
        !showsContent && waited < deadline
    }

    /// Whether the wait after the wake sets the attribute once more, `waited` since the wake:
    /// from halfway to the deadline, once (`reasserted`). An app may still be starting up when
    /// first asked, and miss it.
    public static func reasserts(waited: Duration, reasserted: Bool, deadline: Duration = contentDeadline) -> Bool {
        !reasserted && waited >= deadline / 2
    }

    /// What a process's first contact came to: its web content showed, or the wait gave up.
    public enum FirstContact: Equatable, Sendable {
        case complete
        case timedOut(attempts: Int, at: Date)
    }

    /// Tries after a timeout, and the wait between them.
    public static let firstContactAttempts = 3
    public static let firstContactRetry: TimeInterval = 30

    /// Whether a process is woken (again): never tried, or timed out fewer than
    /// `firstContactAttempts` times and at least `firstContactRetry` ago. One whose content
    /// showed isn't.
    public static func wakesAgain(after last: FirstContact?, now: Date) -> Bool {
        switch last {
        case nil: true
        case .complete: false
        case .timedOut(let attempts, let at): attempts < firstContactAttempts && now.timeIntervalSince(at) >= firstContactRetry
        }
    }

    /// Whether a process's first contact is kept when the turn's end turns its
    /// `enhancedUserInterface` off again: a timeout is, so its count of tries carries over; a
    /// success isn't, so the next turn's first contact may ask again (once a probe finds no content).
    public static func keepsAfterRestore(_ contact: FirstContact) -> Bool {
        if case .timedOut = contact { true } else { false }
    }

    /// Whether Alas turned an attribute on, and so turns it off again at stop, turn end and
    /// session end: it didn't read as true before (`before`, nil when unreadable) and the set took.
    public static func restores(before: Bool?, setSucceeded: Bool) -> Bool {
        before != true && setSucceeded
    }

    /// Whether to wake the app: a Chromium or Electron one (`acceptsManualAccessibility`, or a
    /// Chromium browser by bundle id), due a try (`wakesAgain`), whose window showed no web
    /// content (`showsContent`, `hasWebContent`): no web area, or one without anything in it
    /// yet, also in a read cut short.
    public static func needsWake(
        acceptsManualAccessibility: Bool, bundleID: String?, wakesAgain: Bool, showsContent: Bool
    ) -> Bool {
        wakesAgain && (acceptsManualAccessibility || chromeBundleIDs.contains(bundleID ?? "")) && !showsContent
    }

    /// Whether a read of a Chromium or Electron window (`chromium`) may have come back without
    /// the web content it has: nothing cut it short (`cut`, which explains a missing page on its
    /// own), and it shows no web area with content (`showsContent`). Chrome tears a window's web
    /// tree down after input that comes with no Accessibility reads, and builds it again a couple
    /// of seconds after the next read, so a read right after a drag finds the toolbar only. The
    /// caller then looks past the read's depth limit (`probeNodes`); if that finds no content
    /// either, the read is cut by `ComputerUseReadCut.webContentMissing`.
    public static func mayLackContent(chromium: Bool, showsContent: Bool, cut: ComputerUseReadCut?) -> Bool {
        chromium && !showsContent && cut == nil
    }

    /// A web area with something in it.
    public static func hasWebContent(_ node: ComputerUseAXNode) -> Bool {
        (node.role == "AXWebArea" && !node.children.isEmpty) || node.children.contains(where: hasWebContent)
    }
}
