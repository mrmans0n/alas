import AppKit
import SwiftUI

@MainActor
final class MermaidDiagramViewerController: NSObject, NSWindowDelegate {
    static let shared = MermaidDiagramViewerController()

    private weak var hostWindow: NSWindow?
    private var sheetWindow: MermaidDiagramSheetWindow?

    func show(source: String, theme: Theme, from hostWindow: NSWindow) {
        endCurrentViewer()

        let visibleFrame = hostWindow.screen?.visibleFrame
            ?? NSScreen.main?.visibleFrame
            ?? NSRect(x: 0, y: 0, width: 1_280, height: 800)
        let size = NSSize(
            width: visibleFrame.width * 0.8,
            height: visibleFrame.height * 0.8
        )
        let backingScale = hostWindow.screen?.backingScaleFactor
            ?? hostWindow.backingScaleFactor
        let rootView = MermaidDiagramViewerView(
            source: source,
            diagramTheme: MermaidDiagramTheme(theme: theme),
            backingScale: backingScale
        )
        .environment(\.theme, theme)

        let sheet = MermaidDiagramSheetWindow(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        sheet.title = "Mermaid Diagram"
        sheet.isReleasedWhenClosed = false
        sheet.contentMinSize = NSSize(
            width: min(480, size.width),
            height: min(320, size.height)
        )
        sheet.contentView = NSHostingView(rootView: rootView)
        sheet.delegate = self
        sheet.onCancel = { [weak self] in
            self?.dismiss()
        }

        self.hostWindow = hostWindow
        sheetWindow = sheet
        hostWindow.beginSheet(sheet)
    }

    func dismiss() {
        endCurrentViewer()
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard sender === sheetWindow else { return true }
        endCurrentViewer()
        return false
    }

    func windowWillClose(_ notification: Notification) {
        guard let closingWindow = notification.object as? NSWindow,
              closingWindow === sheetWindow else { return }
        hostWindow = nil
        sheetWindow = nil
    }

    private func endCurrentViewer() {
        guard let sheet = sheetWindow else { return }
        let parent = sheet.sheetParent ?? hostWindow
        sheet.delegate = nil
        sheet.onCancel = nil
        sheetWindow = nil
        hostWindow = nil
        if let parent {
            parent.endSheet(sheet)
            sheet.orderOut(nil)
        } else {
            sheet.close()
        }
    }
}

@MainActor
private final class MermaidDiagramSheetWindow: NSWindow {
    var onCancel: (() -> Void)?

    override func cancelOperation(_ sender: Any?) {
        onCancel?()
    }
}

struct MermaidDiagramViewerView: View {
    let source: String
    let diagramTheme: MermaidDiagramTheme
    let backingScale: CGFloat
    var service: MermaidRenderService = .shared

    @Environment(\.theme) private var theme
    @State private var renderState = MermaidRenderRequestState()
    @State private var showsSource = false
    @State private var zoomState = MermaidZoomState()
    @GestureState private var dragTranslation: CGSize = .zero
    @GestureState private var magnification: CGFloat = 1

    private var key: MermaidRenderKey {
        MermaidRenderKey(
            source: source,
            theme: diagramTheme,
            scale: backingScale,
            profile: .full
        )
    }

    var body: some View {
        VStack(spacing: 0) {
            MermaidDiagramViewerToolbar(
                scale: zoomState.scale,
                showsSource: showsSource,
                zoomOut: { zoomState.zoom(by: 0.8) },
                zoomIn: { zoomState.zoom(by: 1.25) },
                resetScale: { zoomState.setScale(1) },
                reset: { zoomState.resetToFit() },
                toggleSource: { showsSource.toggle() },
                copySource: { Clipboard.copy(source) }
            )
            viewerContent
        }
        .background(theme.color("bg-1"))
        .task(id: key) {
            let requestedKey = key
            renderState.begin(requestedKey)
            zoomState.resetToFit()
            let rendered = await service.render(key: requestedKey)
            guard !Task.isCancelled else { return }
            renderState.apply(rendered, for: requestedKey)
        }
    }

    @ViewBuilder
    private var viewerContent: some View {
        if showsSource {
            HSplitView {
                canvas
                    .frame(minWidth: 240, maxWidth: .infinity, maxHeight: .infinity)
                MermaidDiagramSourceView(source: source, maximumHeight: .infinity)
                    .frame(minWidth: 220, idealWidth: 360, maxWidth: .infinity)
                    .frame(maxHeight: .infinity)
            }
        } else {
            canvas
        }
    }

    private var canvas: some View {
        GeometryReader { proxy in
            ZStack {
                theme.color("bg-1")
                switch renderState.outcome {
                case .rendered(let diagram):
                    let fittedSize = MermaidDiagramLayout.fittedSize(
                        intrinsic: diagram.image.size,
                        availableWidth: max(0, proxy.size.width - 40),
                        maxHeight: max(0, proxy.size.height - 40)
                    )
                    Image(nsImage: diagram.image)
                        .resizable()
                        .interpolation(.high)
                        .aspectRatio(contentMode: .fit)
                        .frame(width: fittedSize.width, height: fittedSize.height)
                        .scaleEffect(zoomState.scale(adding: magnification))
                        .offset(Self.displayTranslation(
                            committed: zoomState.translation,
                            gesture: dragTranslation
                        ))
                        .accessibilityLabel("Mermaid diagram")
                        .accessibilityValue(Text(verbatim: source))
                case .failed(let failure):
                    VStack(spacing: 8) {
                        Text("Couldn't render Mermaid diagram")
                            .font(.headline)
                            .foregroundStyle(theme.color("fg"))
                        Text(failure.mermaidDisplayDiagnostic)
                            .font(.callout)
                            .foregroundStyle(theme.color("fg-muted"))
                            .textSelection(.enabled)
                    }
                    .multilineTextAlignment(.center)
                    .padding(24)
                case nil:
                    ProgressView()
                        .controlSize(.regular)
                        .accessibilityLabel("Rendering Mermaid diagram")
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .contentShape(Rectangle())
            .clipped()
        }
        .simultaneousGesture(panGesture)
        .simultaneousGesture(zoomGesture)
    }

    private var panGesture: some Gesture {
        DragGesture(minimumDistance: 1)
            .updating($dragTranslation) { value, translation, _ in
                translation = value.translation
            }
            .onEnded { value in
                zoomState.translate(by: value.translation)
            }
    }

    private var zoomGesture: some Gesture {
        MagnifyGesture()
            .updating($magnification) { value, magnification, _ in
                magnification = value.magnification
            }
            .onEnded { value in
                zoomState.zoom(by: value.magnification)
            }
    }

    nonisolated static func displayTranslation(
        committed: CGSize,
        gesture: CGSize
    ) -> CGSize {
        CGSize(
            width: committed.width + gesture.width,
            height: committed.height + gesture.height
        )
    }
}

private struct MermaidDiagramViewerToolbar: View {
    let scale: CGFloat
    let showsSource: Bool
    let zoomOut: () -> Void
    let zoomIn: () -> Void
    let resetScale: () -> Void
    let reset: () -> Void
    let toggleSource: () -> Void
    let copySource: () -> Void

    @Environment(\.theme) private var theme

    var body: some View {
        HStack(spacing: 12) {
            Text("MERMAID")
                .font(.system(size: 11, weight: .semibold))
                .tracking(0.4)
                .foregroundStyle(theme.color("fg-faint"))
            Spacer(minLength: 0)
            Button(action: zoomOut) {
                Label("Zoom out", systemImage: "minus.magnifyingglass")
                    .labelStyle(.iconOnly)
            }
            .help("Zoom out")
            Button(action: resetScale) {
                Text("\(Int((scale * 100).rounded()))%")
                    .monospacedDigit()
                    .frame(minWidth: 38)
            }
            .help("Set zoom to 100%")
            Button(action: zoomIn) {
                Label("Zoom in", systemImage: "plus.magnifyingglass")
                    .labelStyle(.iconOnly)
            }
            .help("Zoom in")
            Button("Reset", action: reset)
            Divider()
                .frame(height: 16)
            Button(showsSource ? "Hide source" : "Show source", action: toggleSource)
            Button("Copy", action: copySource)
        }
        .font(.system(size: 11, weight: .medium))
        .buttonStyle(.plain)
        .foregroundStyle(theme.color("fg-muted"))
        .padding(.horizontal, 14)
        .frame(height: 40)
        .background(theme.color("bg-2"))
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(theme.color("line"))
                .frame(height: 0.5)
        }
    }
}
