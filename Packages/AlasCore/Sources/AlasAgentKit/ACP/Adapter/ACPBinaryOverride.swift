import Foundation
import AlasFoundation
import AlasModel
import AlasPlatform
import AlasFeatures
import AlasCode

public enum ACPBinaryOverride: Sendable {
    public static func normalized(
        _ override: String,
        remoteHome: String?,
        treatsHomeAsRemote: Bool = false
    ) -> String? {
        let trimmed = override.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }
        if trimmed.hasPrefix("~/") {
            if let remoteHome {
                let home = remoteHome.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
                guard !home.isEmpty else { return treatsHomeAsRemote ? nil : trimmed }
                return "/\(home)/\(trimmed.dropFirst(2))"
            }
            guard treatsHomeAsRemote == false else { return trimmed }
        }
        return (trimmed as NSString).expandingTildeInPath
    }
}
