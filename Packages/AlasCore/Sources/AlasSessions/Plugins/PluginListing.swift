import Foundation
import AlasACP

/// What a row in Settings → Plugins shows about a plugin: the installed manifest first, the catalog for what it leaves out.
public struct PluginListing: Equatable, Sendable {
    public let name: String
    public let version: String?
    public let summary: String?
    public let author: String?
    /// An SF Symbol name.
    public let icon: String?
    /// The release day of the installed version, or of the one Install would get; nil for a local build.
    public let released: Date?

    public init(installed: PluginManager.Plugin?, entry: PluginCatalogIndex.Entry?) {
        let manifest = installed?.manifest
        name = manifest?.name ?? entry?.name ?? ""
        summary = manifest?.summary ?? entry?.summary
        author = manifest?.author ?? entry?.author
        icon = manifest?.icon ?? entry?.icon
        if let installed {
            version = installed.manifest.version
            // Only a byte-for-byte release has a date; a local edit of version 1.0 was not released with it.
            released = entry?.versions.first { $0.hash == installed.hash }?.releasedDate
        } else {
            let offered = entry?.newestCompatible
            version = offered?.version
            released = offered?.releasedDate
        }
    }
}
