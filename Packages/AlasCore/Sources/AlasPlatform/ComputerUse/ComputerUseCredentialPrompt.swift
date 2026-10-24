import Foundation

/// Whether a system password prompt is showing inside an app. LocalAuthentication draws its
/// prompt ("… is trying to unlock …") as a remote view in a sheet of the requesting app's own
/// window, so the app looks like any other: the prompt is told by the process that draws it and
/// by a secure text field in one of the app's sheets or untitled windows.
public enum ComputerUseCredentialPrompt {
    /// The processes started for a system credential prompt: LocalAuthentication's remote view
    /// host, which started with the prompt seen live, and the SecurityAgent of admin and keychain
    /// dialogs. coreautha (`com.apple.LocalAuthentication.UIAgent`) doesn't count: it stays
    /// running for days after its prompts are gone.
    public static let promptProcessBundleIDs: Set<String> = [
        "com.apple.LocalAuthenticationRemoteService",
        "com.apple.SecurityAgent",
    ]

    /// `hasUntitledWindow`: the app has an untitled on-screen window, as every sheet is.
    /// `secureFieldInSheet`: a secure text field in one of its sheets or untitled windows; nil when
    /// they couldn't be read (or weren't, past a listing's probe budget), which counts as one.
    public static func isShowing(
        runningBundleIDs: Set<String>, hasUntitledWindow: Bool, secureFieldInSheet: Bool?
    ) -> Bool {
        needsSheetRead(runningBundleIDs: runningBundleIDs, hasUntitledWindow: hasUntitledWindow)
            && secureFieldInSheet != false
    }

    /// What `computer_apps` says about an app's prompt.
    public enum Listing: String, Equatable, Sendable {
        /// No prompt can be showing, or the sheets were read and hold no secure field.
        case clear
        case showing
        /// A prompt may be showing, but the listing's probe budget ran out before the app's turn.
        case unchecked
    }

    /// `probed`: the listing reached the app within its probe budget, so `secureFieldInSheet`
    /// is what its read found (nil: unreadable or cut short, which counts as showing). An app the
    /// budget never reached isn't claimed to show a prompt; its windows are still withheld.
    public static func listing(
        runningBundleIDs: Set<String>, hasUntitledWindow: Bool, probed: Bool, secureFieldInSheet: Bool?
    ) -> Listing {
        guard needsSheetRead(runningBundleIDs: runningBundleIDs, hasUntitledWindow: hasUntitledWindow) else { return .clear }
        guard probed else { return .unchecked }
        return isShowing(runningBundleIDs: runningBundleIDs, hasUntitledWindow: hasUntitledWindow,
                         secureFieldInSheet: secureFieldInSheet) ? .showing : .clear
    }

    /// Whether the sheets are worth reading: without a prompt process or an untitled window,
    /// nothing can make `isShowing` true.
    public static func needsSheetRead(runningBundleIDs: Set<String>, hasUntitledWindow: Bool) -> Bool {
        hasUntitledWindow && !runningBundleIDs.isDisjoint(with: promptProcessBundleIDs)
    }
}
