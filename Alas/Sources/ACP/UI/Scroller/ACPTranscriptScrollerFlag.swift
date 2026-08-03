import Foundation

/// Runtime switch between the legacy SwiftUI transcript ScrollView and the
/// AppKit-backed scroller. Defaults on for dev builds, off for release,
/// overridable either way with:
///   defaults write io.nlopez.alas alas.transcript.appkitScroller -bool NO
enum ACPTranscriptScrollerFlag {
    static let defaultsKey = "alas.transcript.appkitScroller"

    static var isEnabled: Bool {
        let override = UserDefaults.standard.object(forKey: defaultsKey) as? Bool
        #if DEBUG
        return resolve(override: override, isDebugBuild: true)
        #else
        return resolve(override: override, isDebugBuild: false)
        #endif
    }

    nonisolated static func resolve(override: Bool?, isDebugBuild: Bool) -> Bool {
        override ?? isDebugBuild
    }
}
