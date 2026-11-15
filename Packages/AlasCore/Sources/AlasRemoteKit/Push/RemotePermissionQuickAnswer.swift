import Foundation

/// Picks the option an Allow or Deny action on a permission alert answers with.
public enum RemotePermissionQuickAnswer {
    /// The first once-only option of the wanted side, else the first persistent one; nil never guesses.
    public static func optionId(in payload: RemotePermissionPayload, allow: Bool) -> String? {
        let kinds = allow ? ["allow_once", "allow_always"] : ["reject_once", "reject_always"]
        for kind in kinds {
            if let option = payload.options.first(where: { $0.kind == kind }) { return option.optionId }
        }
        return nil
    }
}
