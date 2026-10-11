import Foundation

/// Opens URLs in the user's apps. `PlatformServices.install()` sets the
/// `NSWorkspace` implementation at launch; until then nothing opens.
@MainActor
public struct URLOpening: Sendable {
    /// Launches the app that handles `url` without opening the URL itself.
    public var launchHandler: @Sendable (URL) async -> Bool
    public var open: (URL) -> Void

    public static var shared = URLOpening(launchHandler: { _ in false }, open: { _ in })

    public init(launchHandler: @escaping @Sendable (URL) async -> Bool, open: @escaping (URL) -> Void) {
        self.launchHandler = launchHandler
        self.open = open
    }
}
