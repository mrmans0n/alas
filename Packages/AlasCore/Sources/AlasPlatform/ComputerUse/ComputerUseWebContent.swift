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
        /// The app has no such attribute (`kAXErrorAttributeUnsupported`).
        case unsupported
        /// Anything else: the app busy, or not answering yet. Nothing is known.
        case failed
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
        /// The app has no such attribute: set this one instead, at once.
        case fallBack(String)
        /// Nothing to ask with: no wait.
        case giveUp
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
                ? .fallBack(enhancedUserInterface) : .giveUp
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

    /// How deep and how wide the wait's read of the window looks for a web area with content: the
    /// page's web area sits a few levels under the browser's toolbar.
    public static let probeDepth = 10
    public static let probeNodes = 400

    /// Once the web content shows, how long it is left to fill in before the window is read.
    public static let contentSettle: Duration = .milliseconds(500)

    /// Whether to read the window again after `waited` since the wake, read time included: it
    /// shows no web area with content yet (`hasWebContent`) and the deadline hasn't passed. A
    /// read cut short counts only for what it holds.
    public static func keepsWaiting(root: ComputerUseAXNode, waited: Duration, deadline: Duration = contentDeadline) -> Bool {
        !hasWebContent(root) && waited < deadline
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
    /// content: no web area, or one without anything in it yet, also in a read cut short.
    public static func needsWake(
        acceptsManualAccessibility: Bool, bundleID: String?, wakesAgain: Bool, root: ComputerUseAXNode
    ) -> Bool {
        guard wakesAgain, acceptsManualAccessibility || chromeBundleIDs.contains(bundleID ?? "") else { return false }
        return !hasWebContent(root)
    }

    /// A web area with something in it.
    public static func hasWebContent(_ node: ComputerUseAXNode) -> Bool {
        (node.role == "AXWebArea" && !node.children.isEmpty) || node.children.contains(where: hasWebContent)
    }
}
