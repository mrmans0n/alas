import AppKit
import SwiftUI

enum PluginTabContent: Equatable {
    case unavailable
    case stopped(String)
    case loading
    case content

    static func resolve(
        pluginsOn: Bool, found: Bool, approved: Bool, enabled: Bool,
        hostState: PluginHostState?, hasContent: Bool
    ) -> PluginTabContent {
        guard pluginsOn, found, approved, enabled else { return .unavailable }
        if case .failed(let reason) = hostState { return .stopped(reason) }
        return hostState == .active && hasContent ? .content : .loading
    }
}

enum PluginCanvasLayout {
    /// Largest whole-number scale at which the frame fits, never below 1 (a larger frame is clipped).
    static func scale(frame: CGSize, in view: CGSize) -> Int {
        guard frame.width > 0, frame.height > 0 else { return 1 }
        return max(1, Int(min(view.width / frame.width, view.height / frame.height)))
    }
}

extension PluginFrame {
    var cgImage: CGImage? {
        guard let provider = CGDataProvider(data: pixels as CFData) else { return nil }
        return CGImage(
            width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue),
            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
    }
}

struct PluginTabView: View {
    let state: AppState
    let worktree: Worktree
    let tab: PluginTabState
    @Environment(\.theme) var theme

    var body: some View {
        let manager = state.pluginManager
        let plugin = manager?.plugin(id: tab.pluginID)
        let host = manager?.host(pluginID: tab.pluginID, projectID: worktree.projectId)
        let tabIndex = plugin?.manifest.tabs.firstIndex { $0.id == tab.contributionID }
        let kind = tabIndex.flatMap { plugin?.manifest.tabs[$0].kind }
        let content = PluginTabContent.resolve(
            pluginsOn: manager != nil,
            found: plugin != nil && tabIndex != nil,
            approved: plugin.map { manager?.isApproved($0) == true } ?? false,
            enabled: plugin.map { manager?.isEnabled($0) == true } ?? false,
            hostState: host?.state,
            // A web tab's page is its own content; it posts "ready" when it loads.
            hasContent: tabIndex.map {
                switch kind {
                case .view: host?.views[$0] != nil
                case .web: true
                default: host?.frames[.tab($0)] != nil
                }
            } ?? false)
        ZStack {
            theme.color("bg-1")
            switch content {
            case .content:
                if let host, let tabIndex {
                    switch kind {
                    case .view: PluginViewTabView(host: host, tabIndex: tabIndex)
                    case .web: PluginWebTabView(host: host, surface: .tab(tabIndex), script: plugin?.web ?? Data())
                    default: PluginCanvasView(host: host, surface: .tab(tabIndex))
                    }
                }
            case .loading:
                Spinner().frame(width: 14, height: 14).accessibilityLabel("Loading")
            case .stopped(let reason):
                placeholder("\(tab.title) stopped: \(reason)", button: "Restart") {
                    guard let manager else { return }
                    Task {
                        await manager.restart(PluginManager.HostKey(pluginID: tab.pluginID, projectID: worktree.projectId))
                    }
                }
            case .unavailable:
                placeholder("\(tab.title) isn't available", button: "Open Plugin Settings") {
                    NotificationCenter.default.post(name: .alasOpenSettings, object: SettingsSection.plugins)
                }
            }
        }
        // Canvas tabs tick only while on screen; API 9 plugins hear when any of their tabs shows or hides.
        .background(PluginVisibilityReporter(
            target: (content == .content || content == .loading) ? host.flatMap { host in tabIndex.map { (host, $0) } } : nil))
    }

    private func placeholder(_ text: String, button: String, action: @escaping () -> Void) -> some View {
        VStack(spacing: 12) {
            Text(text).foregroundColor(theme.color("fg-dim")).multilineTextAlignment(.center)
            AlasButton(title: button, style: .normal, action: action)
        }
        .padding(24)
    }
}

struct PluginCanvasView: View {
    let host: PluginHost
    let surface: PluginSurface
    /// Index into the region list: ids are plugin-chosen and the host truncates them, so they can collide.
    @FocusState private var focused: Int?

    var body: some View {
        GeometryReader { geometry in
            if let frame = host.frames[surface], let image = frame.cgImage {
                let size = CGSize(width: frame.width, height: frame.height)
                let scale = CGFloat(PluginCanvasLayout.scale(frame: size, in: geometry.size))
                let origin = CGPoint(
                    x: ((geometry.size.width - size.width * scale) / 2).rounded(.down),
                    y: ((geometry.size.height - size.height * scale) / 2).rounded(.down))
                ZStack(alignment: .topLeading) {
                    Image(decorative: image, scale: 1)
                        .interpolation(.none)
                        .resizable()
                        .frame(width: size.width * scale, height: size.height * scale)
                        .offset(x: origin.x, y: origin.y)
                        .accessibilityHidden(true)
                    ForEach(Array((host.regions[surface] ?? []).enumerated()), id: \.offset) { index, region in
                        // Rects are not range-checked by the host: never hand SwiftUI a negative size.
                        let activate = { Task { await host.click(surface: surface, region: region.id) } }
                        Button(action: { activate() }) {
                            Color.clear.contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        // Explicitly focusable so Tab reaches regions in list order, and Return/Space activate.
                        .focusable()
                        .focused($focused, equals: index)
                        .onKeyPress(.return) {
                            activate()
                            return .handled
                        }
                        .onKeyPress(.space) {
                            activate()
                            return .handled
                        }
                        .frame(
                            width: CGFloat(max(0, region.rect[2])) * scale,
                            height: CGFloat(max(0, region.rect[3])) * scale)
                        .overlay {
                            if focused == index {
                                RoundedRectangle(cornerRadius: 2).stroke(Color.accentColor, lineWidth: 2)
                            }
                        }
                        .offset(
                            x: origin.x + CGFloat(region.rect[0]) * scale,
                            y: origin.y + CGFloat(region.rect[1]) * scale)
                        .help(region.label)
                        .accessibilityLabel(region.label)
                        .pointerStyle(.link)
                    }
                }
                .frame(width: geometry.size.width, height: geometry.size.height, alignment: .topLeading)
                .clipped()
            }
        }
    }
}

/// Reports the tab as visible while it is in a window that is not occluded.
private struct PluginVisibilityReporter: NSViewRepresentable {
    let target: (host: PluginHost, tab: Int)?

    func makeNSView(context: Context) -> ReporterView { ReporterView() }

    func updateNSView(_ view: ReporterView, context: Context) { view.target = target }

    static func dismantleNSView(_ view: ReporterView, coordinator: ()) { view.target = nil }

    @MainActor
    final class ReporterView: NSView {
        private var reported: (host: PluginHost, tab: Int)?
        private var observer: NSObjectProtocol?

        var target: (host: PluginHost, tab: Int)? { didSet { update() } }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let observer { NotificationCenter.default.removeObserver(observer) }
            observer = window.map {
                NotificationCenter.default.addObserver(
                    forName: NSWindow.didChangeOcclusionStateNotification, object: $0, queue: .main
                ) { [weak self] _ in MainActor.assumeIsolated { self?.update() } }
            }
            update()
        }

        private func update() {
            let visible = window?.occlusionState.contains(.visible) == true ? target : nil
            guard visible?.host !== reported?.host || visible?.tab != reported?.tab else { return }
            if let reported { reported.host.setTabVisible(reported.tab, false) }
            if let visible { visible.host.setTabVisible(visible.tab, true) }
            reported = visible
        }
    }
}
