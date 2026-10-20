import Foundation
import Observation
import AlasFoundation
import AlasModel
import AlasPlatform
import AlasFeatures
import AlasCode
import AlasACP

/// What the catalog offers for one entry, given what is installed.
public enum PluginCatalogRow: Equatable, Sendable {
    case install(PluginCatalogIndex.Version)
    case installed
    case update(PluginCatalogIndex.Version)
    /// A plugin with this id that the catalog did not put there; it wins, and the catalog leaves it alone.
    case installedLocally
    case incompatible

    /// The catalog installs into a folder named after the id. A plugin is the catalog's only if it sits
    /// there and its files are byte-for-byte a published version.
    /// `quarantined`: something the catalog does not own holds this plugin: duplicates of it, or anything at its
    /// catalog path that is not exactly a release (a broken folder, a symlink, a release with added files).
    public init(entry: PluginCatalogIndex.Entry, installed: PluginManager.Plugin?, quarantined: Bool = false) {
        if quarantined {
            self = .installedLocally
            return
        }
        guard let installed else {
            self = entry.newestCompatible.map(PluginCatalogRow.install) ?? .incompatible
            return
        }
        guard installed.isCatalogFolder, entry.versions.contains(where: { $0.hash == installed.hash }) else {
            self = .installedLocally
            return
        }
        if let newest = entry.newestCompatible, newest.hash != installed.hash,
           PluginCatalogIndex.isOlder(installed.manifest.version, than: newest.version) {
            self = .update(newest)
        } else {
            self = .installed
        }
    }
}
