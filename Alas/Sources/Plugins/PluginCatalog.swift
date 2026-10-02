import Foundation
import Observation

/// `index.json` from mrmans0n/alas-plugins: every published version of every plugin there.
struct PluginCatalogIndex: Decodable, Sendable, Equatable {
    struct Version: Decodable, Sendable, Equatable {
        let version: String
        let api: Int
        let capabilities: [String]
        let manifest: URL
        /// Missing for versions published for the WebAssembly runtime, which Alas can no longer load.
        let entry: URL?
        /// `PluginTrust.hash` of the two files, so a download is verified before it is written.
        let hash: String
    }

    struct Entry: Decodable, Sendable, Equatable, Identifiable {
        let id: String
        let name: String
        let summary: String?
        let homepage: URL?
        let versions: [Version]

        /// The newest version this Alas can run.
        var newestCompatible: Version? {
            versions.filter { $0.api == PluginManifest.supportedAPIVersion && $0.entry != nil }
                .max { PluginCatalogIndex.isOlder($0.version, than: $1.version) }
        }
    }

    static let supportedFormat = 1

    let format: Int
    let plugins: [Entry]

    /// Dotted numeric versions, compared part by part; a missing part counts as 0.
    static func isOlder(_ a: String, than b: String) -> Bool {
        let lhs = a.split(separator: ".").map { Int($0) ?? 0 }, rhs = b.split(separator: ".").map { Int($0) ?? 0 }
        for index in 0..<max(lhs.count, rhs.count) {
            let l = index < lhs.count ? lhs[index] : 0, r = index < rhs.count ? rhs[index] : 0
            if l != r { return l < r }
        }
        return false
    }
}

/// What the catalog offers for one entry, given what is installed.
enum PluginCatalogRow: Equatable {
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
    init(entry: PluginCatalogIndex.Entry, installed: PluginManager.Plugin?, quarantined: Bool = false) {
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

enum PluginCatalogError: Error, Equatable, CustomStringConvertible {
    case unsupportedFormat
    case hashMismatch
    case wrongPlugin(String)
    case tooLarge
    case installedLocally
    case invalidDownload(String)

    var description: String {
        switch self {
        case .unsupportedFormat: "The catalog needs a newer version of Alas."
        case .hashMismatch: "The download does not match the catalog, so it was not installed."
        case .wrongPlugin(let id): "The download is a different plugin (\(id)), so it was not installed."
        case .tooLarge: "The download is too large."
        case .installedLocally: "A local copy of this plugin is linked in, so the catalog leaves it alone."
        case .invalidDownload(let reason): "The download is not a valid plugin, so it was not installed: \(reason)"
        }
    }
}

/// Fetches the index. Installing goes through `PluginManager`, which owns the plugins folder.
@MainActor
@Observable
final class PluginCatalog {
    enum State: Equatable {
        case idle
        case loading
        case loaded(PluginCatalogIndex)
        case failed(String)
    }

    static let indexURL = URL(string: "https://raw.githubusercontent.com/mrmans0n/alas-plugins/main/index.json")!
    static let refreshInterval: Duration = .seconds(600)
    nonisolated static let maxDownloadBytes = 8 << 20

    private(set) var state: State = .idle
    @ObservationIgnored let fetch: @Sendable (URL) async throws -> Data
    @ObservationIgnored private var lastLoad: ContinuousClock.Instant?

    init(fetch: @escaping @Sendable (URL) async throws -> Data = { try await PluginCatalog.download($0) }) {
        self.fetch = fetch
    }

    var index: PluginCatalogIndex? {
        if case .loaded(let index) = state { index } else { nil }
    }

    /// Loads the index unless it loaded recently; `force` always loads.
    func refresh(force: Bool = false) async {
        if state == .loading { return }
        if !force, index != nil, let lastLoad, ContinuousClock.now - lastLoad < Self.refreshInterval { return }
        state = .loading
        do {
            let index = try JSONDecoder().decode(PluginCatalogIndex.self, from: try await fetch(Self.indexURL))
            guard index.format == PluginCatalogIndex.supportedFormat else { throw PluginCatalogError.unsupportedFormat }
            state = .loaded(index)
            lastLoad = .now
        } catch let error as PluginCatalogError {
            state = .failed(error.description)
        } catch {
            state = .failed("Could not load the plugin catalog: \(error.localizedDescription)")
        }
    }

    nonisolated static func download(_ url: URL) async throws -> Data {
        // Never from the local URL cache: an index cached there would hide a release just published. The timeout is
        // the whole transfer's budget, so a server trickling bytes cannot keep one going.
        let request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 60)
        let data: Data, response: HTTPURLResponse
        do {
            (data, response) = try await boundedFetch(request, maxBytes: maxDownloadBytes)
        } catch URLError.dataLengthExceedsMaximum {
            throw PluginCatalogError.tooLarge
        }
        guard (200..<300).contains(response.statusCode) else { throw URLError(.badServerResponse) }
        return data
    }
}
