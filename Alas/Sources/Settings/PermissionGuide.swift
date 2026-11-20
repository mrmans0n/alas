import AppKit
import SwiftUI

/// Opens a System Settings privacy list and docks a panel beside it whose app icon
/// the user drags into that list. An animated hint over both windows shows the drag.
@MainActor
final class PermissionGuide {
    private static var current: PermissionGuide?

    private let panel: NSPanel
    private var hint: NSPanel?
    private var pollTimer: Timer?
    private var closeObserver: NSObjectProtocol?

    static func show(name: String, settingsURL: URL, isGranted: @escaping @MainActor () -> Bool) {
        current?.close()
        let guide = PermissionGuide(name: name, isGranted: isGranted)
        current = guide
        URLOpening.shared.open(settingsURL)
        guide.dockBesideSettings()
    }

    private init(name: String, isGranted: @escaping @MainActor () -> Bool) {
        panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 380, height: 330),
            styleMask: [.titled, .closable, .fullSizeContentView, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.titlebarAppearsTransparent = true
        panel.titleVisibility = .hidden
        panel.level = .floating
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.contentView = NSHostingView(rootView: PermissionGuideView(name: name) { [weak self] in
            self?.hideHint()
        })

        closeObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification, object: panel, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.tearDown() }
        }
        pollTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                if isGranted() { self?.close() }
            }
        }
    }

    private func close() {
        panel.close()
    }

    private func tearDown() {
        pollTimer?.invalidate()
        hideHint()
        if let closeObserver { NotificationCenter.default.removeObserver(closeObserver) }
        if Self.current === self { Self.current = nil }
    }

    private func hideHint() {
        hint?.close()
        hint = nil
    }

    /// System Settings opens asynchronously; wait until its window stops moving.
    private func dockBesideSettings(attempt: Int = 0, last: NSRect? = nil) {
        let frame = Self.settingsWindowFrame()
        if let frame, frame == last {
            place(beside: frame)
            return
        }
        guard attempt < 30 else {
            if let frame {
                place(beside: frame)
            } else {
                panel.center()
                panel.orderFrontRegardless()
            }
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
            self?.dockBesideSettings(attempt: attempt + 1, last: frame)
        }
    }

    private func place(beside settings: NSRect) {
        guard Self.current === self else { return }
        let screen = NSScreen.screens.first { $0.frame.intersects(settings) }?.visibleFrame
            ?? NSScreen.main?.visibleFrame ?? settings
        let size = panel.frame.size
        let x = max(screen.minX, settings.minX - size.width - 12)
        let y = min(max(screen.minY, settings.maxY - size.height), screen.maxY - size.height)
        panel.setFrameOrigin(NSPoint(x: x, y: y))
        panel.orderFrontRegardless()
        showHint(from: panel.frame, to: settings)
    }

    private func showHint(from guide: NSRect, to settings: NSRect) {
        let area = guide.union(settings)
        // Icon center in the guide view, and a spot in the Settings app list on the right.
        let start = NSPoint(x: guide.midX, y: guide.maxY - PermissionGuideView.iconCenterFromTop)
        let end = NSPoint(x: settings.minX + settings.width * 0.68, y: settings.maxY - settings.height * 0.4)
        let local = { (p: NSPoint) in CGPoint(x: p.x - area.minX, y: area.maxY - p.y) }

        let hint = NSPanel(contentRect: area, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        hint.isOpaque = false
        hint.backgroundColor = .clear
        hint.hasShadow = false
        hint.ignoresMouseEvents = true
        hint.level = .floating
        hint.isReleasedWhenClosed = false
        hint.contentView = NSHostingView(rootView: PermissionDragHint(start: local(start), end: local(end)))
        hint.orderFrontRegardless()
        self.hint = hint
    }

    /// The frontmost normal window of System Settings, in AppKit screen coordinates.
    /// Window bounds and owner need no permission, unlike window titles.
    private static func settingsWindowFrame() -> NSRect? {
        let pids = Set(NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.systempreferences")
            .map(\.processIdentifier))
        guard !pids.isEmpty,
              let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]],
              let primaryHeight = NSScreen.screens.first?.frame.maxY
        else { return nil }
        for window in windows {
            guard let pid = window[kCGWindowOwnerPID as String] as? pid_t, pids.contains(pid),
                  window[kCGWindowLayer as String] as? Int == 0,
                  let bounds = window[kCGWindowBounds as String] as? NSDictionary,
                  let rect = CGRect(dictionaryRepresentation: bounds), rect.width > 200
            else { continue }
            return NSRect(x: rect.minX, y: primaryHeight - rect.maxY, width: rect.width, height: rect.height)
        }
        return nil
    }
}

private struct PermissionGuideView: View {
    static let iconSize: CGFloat = 96
    static let iconTop: CGFloat = 36
    static var iconCenterFromTop: CGFloat { iconTop + iconSize / 2 }

    let name: String
    let onDragStart: () -> Void

    var body: some View {
        VStack(spacing: 14) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: Self.iconSize, height: Self.iconSize)
                .onDrag {
                    onDragStart()
                    return NSItemProvider(object: Bundle.main.bundleURL as NSURL)
                }
                .help("Drag into the list in System Settings")
                .accessibilityLabel("\(AppRelaunch.appName) app icon. Drag it into the list in System Settings.")
            Text("Allow \(name)")
                .font(.title2.bold())
            Text("**Drag the icon above into the list in System Settings**, then make sure its switch is on.")
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .padding(12)
                .frame(maxWidth: .infinity)
                .background(Color.accentColor.opacity(0.15), in: RoundedRectangle(cornerRadius: 8))
            Text("This window closes once macOS reports the permission as granted.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(.top, Self.iconTop)
        .padding([.horizontal, .bottom], 24)
        .frame(width: 380, alignment: .top)
    }
}

/// A ghost icon with a grabbing hand that travels from the guide's icon into the Settings list.
private struct PermissionDragHint: View {
    let start: CGPoint
    let end: CGPoint
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        TimelineView(.animation(paused: reduceMotion)) { context in
            let progress = reduceMotion ? 1 : Self.progress(at: context.date)
            let eased = progress * progress * (3 - 2 * progress)
            ZStack(alignment: .topLeading) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .frame(width: 72, height: 72)
                    .overlay(alignment: .center) {
                        Image(systemName: "hand.raised.fill")
                            .font(.system(size: 26))
                            .foregroundStyle(.white)
                            .shadow(radius: 2)
                            .offset(x: 8, y: 10)
                    }
                    .opacity(reduceMotion ? 0.6 : 0.85 * min(1, progress * 6, (1 - progress) * 6))
                    .position(
                        x: start.x + (end.x - start.x) * eased,
                        y: start.y + (end.y - start.y) * eased
                    )
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .allowsHitTesting(false)
    }

    /// 0…1 across a 1.6 s move, then a 0.6 s pause before it repeats.
    private static func progress(at date: Date) -> Double {
        let t = date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 2.2)
        return min(1, t / 1.6)
    }
}
