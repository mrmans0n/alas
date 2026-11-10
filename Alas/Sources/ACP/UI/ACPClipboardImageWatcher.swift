import AppKit
import Observation

/// Tells the composer when the clipboard holds an image it could paste, so it
/// can offer a "Paste image ⌃V" chip.
///
/// macOS posts nothing when the clipboard changes, so this polls
/// `changeCount`, an integer read, and looks at the type list only when the
/// count moves. It never reads the clipboard's contents: on recent macOS that
/// shows the paste-privacy prompt.
@Observable
@MainActor
final class ACPClipboardImageWatcher {
    static let shared = ACPClipboardImageWatcher()

    /// The clipboard holds a bitmap image no composer has pasted yet.
    private(set) var offersImage = false

    @ObservationIgnored private var observedChangeCount: Int?
    @ObservationIgnored private var pastedChangeCount: Int?
    @ObservationIgnored private var watcherCount = 0
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var activationObserver: NSObjectProtocol?

    /// Bitmap data the composer pastes as an image chip. A file copied in
    /// Finder also offers its icon as TIFF, so anything carrying file URLs is
    /// left out: telling an image file from another file means reading it.
    nonisolated static func offersImage(types: [NSPasteboard.PasteboardType]) -> Bool {
        guard !types.contains(.fileURL) else { return false }
        return types.contains(.png) || types.contains(.tiff)
    }

    /// Balanced by `stopWatching()`; polling runs while any composer watches.
    func startWatching() {
        watcherCount += 1
        guard watcherCount == 1 else { return }
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
        timer.tolerance = 0.3
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        activationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
        refresh()
    }

    func stopWatching() {
        guard watcherCount > 0 else { return }
        watcherCount -= 1
        guard watcherCount == 0 else { return }
        timer?.invalidate()
        timer = nil
        if let activationObserver { NotificationCenter.default.removeObserver(activationObserver) }
        activationObserver = nil
    }

    /// The current clipboard item went into a composer; hide the offer until
    /// the clipboard changes again.
    func markPasted() {
        pastedChangeCount = NSPasteboard.general.changeCount
        offersImage = false
    }

    private func refresh() {
        guard NSApp.isActive else { return }
        let pasteboard = NSPasteboard.general
        let changeCount = pasteboard.changeCount
        guard changeCount != observedChangeCount else { return }
        observedChangeCount = changeCount
        let offers = changeCount != pastedChangeCount && Self.offersImage(types: pasteboard.types ?? [])
        if offers != offersImage { offersImage = offers }
    }
}
