import Foundation

/// Opens URLs in the user's apps. `PlatformServices.install()` sets the
/// `NSWorkspace` implementation at launch; until then nothing opens.
@MainActor
struct URLOpening {
    /// Launches the app that handles `url` without opening the URL itself.
    var launchHandler: (URL) async -> Bool
    var open: (URL) -> Void

    static var shared = URLOpening(launchHandler: { _ in false }, open: { _ in })
}
