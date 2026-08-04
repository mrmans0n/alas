import AppKit

struct FileSystemApplication: Identifiable, Equatable {
    let url: URL
    let name: String
    let isDefault: Bool

    var id: String { url.standardizedFileURL.path }
    var menuTitle: String { isDefault ? "\(name) (default)" : name }

    @MainActor var icon: NSImage {
        NSWorkspace.shared.icon(forFile: url.path)
    }
}

enum FileSystemOpen {
    @MainActor static func open(url: URL) {
        NSWorkspace.shared.open(url)
    }

    @MainActor static func open(url: URL, with application: FileSystemApplication) {
        NSWorkspace.shared.open(
            [url],
            withApplicationAt: application.url,
            configuration: NSWorkspace.OpenConfiguration(),
            completionHandler: nil
        )
    }

    @MainActor static func reveal(url: URL) {
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    @MainActor static func applications(for url: URL) -> [FileSystemApplication] {
        let workspace = NSWorkspace.shared
        return orderedApplications(
            candidateURLs: workspace.urlsForApplications(toOpen: url),
            defaultApplicationURL: workspace.urlForApplication(toOpen: url),
            displayName: applicationDisplayName(for:)
        )
    }

    static func orderedApplications(
        candidateURLs: [URL],
        defaultApplicationURL: URL?,
        displayName: (URL) -> String
    ) -> [FileSystemApplication] {
        let defaultURL = defaultApplicationURL?.standardizedFileURL
        var uniqueURLs: [String: URL] = [:]
        for url in candidateURLs + [defaultApplicationURL].compactMap({ $0 }) {
            let standardized = url.standardizedFileURL
            if uniqueURLs[standardized.path] == nil {
                uniqueURLs[standardized.path] = standardized
            }
        }
        return uniqueURLs.values
            .map { url in
                FileSystemApplication(
                    url: url,
                    name: displayName(url),
                    isDefault: url == defaultURL
                )
            }
            .sorted { lhs, rhs in
                if lhs.isDefault != rhs.isDefault { return lhs.isDefault }
                let order = lhs.name.localizedStandardCompare(rhs.name)
                if order != .orderedSame { return order == .orderedAscending }
                return lhs.url.path.localizedStandardCompare(rhs.url.path) == .orderedAscending
            }
    }

    private static func applicationDisplayName(for url: URL) -> String {
        let values = try? url.resourceValues(forKeys: [.localizedNameKey])
        let rawName = values?.localizedName ?? url.lastPathComponent
        return rawName.hasSuffix(".app") ? String(rawName.dropLast(4)) : rawName
    }
}
