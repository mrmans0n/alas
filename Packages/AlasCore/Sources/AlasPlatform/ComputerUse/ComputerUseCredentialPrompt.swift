import Foundation

/// Whether a system password prompt is showing inside an app. LocalAuthentication draws its
/// prompt ("… is trying to unlock …") as a remote view in a sheet of the requesting app's own
/// window, so the app looks like any other: the prompt is told by the processes that draw it and
/// by a secure text field in one of the app's sheets or untitled windows.
public enum ComputerUseCredentialPrompt {
    /// The processes behind system credential prompts. coreautha
    /// (`com.apple.LocalAuthentication.UIAgent`) stays running long after its prompts are gone.
    public static let processBundleIDs: Set<String> = [
        "com.apple.LocalAuthentication.UIAgent",
        "com.apple.LocalAuthenticationRemoteService",
        "com.apple.SecurityAgent",
        "com.apple.coreautha",
    ]

    /// The ones started for a prompt, which count without a readable sheet.
    public static let promptProcessBundleIDs: Set<String> = [
        "com.apple.LocalAuthenticationRemoteService",
        "com.apple.SecurityAgent",
    ]

    /// `hasUntitledWindow`: the app has an untitled on-screen window, as every sheet is.
    /// `secureFieldInSheet`: a secure text field in one of its sheets or untitled windows; nil when
    /// they couldn't be read. Then only a prompt process that is running tells.
    public static func isShowing(
        runningBundleIDs: Set<String>, hasUntitledWindow: Bool, secureFieldInSheet: Bool?
    ) -> Bool {
        guard hasUntitledWindow, !runningBundleIDs.isDisjoint(with: processBundleIDs) else { return false }
        if let secureFieldInSheet { return secureFieldInSheet }
        return !runningBundleIDs.isDisjoint(with: promptProcessBundleIDs)
    }

    /// Whether the sheets are worth reading: nothing else can make `isShowing` true.
    public static func needsSheetRead(runningBundleIDs: Set<String>, hasUntitledWindow: Bool) -> Bool {
        hasUntitledWindow && !runningBundleIDs.isDisjoint(with: processBundleIDs)
    }
}
