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

enum MermaidViewerAction: CaseIterable {
    case zoomOut
    case zoomIn
    case actualSize
    case resetToFit
    case toggleSource
    case copySource

    var shortcut: ShortcutBinding {
        switch self {
        case .zoomOut:
            ShortcutBinding(key: "-", modifiers: [.command])
        case .zoomIn:
            ShortcutBinding(key: "=", modifiers: [.command])
        case .actualSize:
            ShortcutBinding(key: "0", modifiers: [.command])
        case .resetToFit:
            ShortcutBinding(key: "9", modifiers: [.command])
        case .toggleSource:
            ShortcutBinding(key: "u", modifiers: [.option, .command])
        case .copySource:
            ShortcutBinding(key: "c", modifiers: [.option, .command])
        }
    }
}

enum MermaidViewerEffect: Equatable {
    case copySource
}

enum MermaidViewerZoomAdjustment {
    case increment
    case decrement
}

struct MermaidViewerZoomAccessibilityMetadata: Equatable {
    let label: String
    let value: String
}

struct MermaidViewerInteractionState {
    private var zoomState = MermaidZoomState()
    private(set) var showsSource = false

    var scale: CGFloat {
        zoomState.scale
    }

    var translation: CGSize {
        zoomState.translation
    }

    var zoomAccessibilityMetadata: MermaidViewerZoomAccessibilityMetadata {
        MermaidViewerZoomAccessibilityMetadata(
            label: "Mermaid diagram zoom",
            value: "\(Int((scale * 100).rounded()))%"
        )
    }

    @discardableResult
    mutating func perform(_ action: MermaidViewerAction) -> MermaidViewerEffect? {
        switch action {
        case .zoomOut:
            zoomState.zoom(by: 0.8)
        case .zoomIn:
            zoomState.zoom(by: 1.25)
        case .actualSize:
            zoomState.setScale(1)
        case .resetToFit:
            zoomState.resetToFit()
        case .toggleSource:
            showsSource.toggle()
        case .copySource:
            return .copySource
        }
        return nil
    }

    mutating func adjustZoom(_ adjustment: MermaidViewerZoomAdjustment) {
        switch adjustment {
        case .increment:
            perform(.zoomIn)
        case .decrement:
            perform(.zoomOut)
        }
    }

    mutating func zoom(by factor: CGFloat) {
        zoomState.zoom(by: factor)
    }

    mutating func translate(by delta: CGSize) {
        zoomState.translate(by: delta)
    }

    func scale(adding factor: CGFloat) -> CGFloat {
        zoomState.scale(adding: factor)
    }
}

struct MermaidDiagramViewerView: View {
    let source: String
    let diagramTheme: MermaidDiagramTheme
    let backingScale: CGFloat
    var service: MermaidRenderService = .shared

    @Environment(\.theme) private var theme
    @State private var renderState = MermaidRenderRequestState()
    @State private var interactionState = MermaidViewerInteractionState()
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
                showsSource: interactionState.showsSource,
                zoomAccessibilityMetadata: interactionState.zoomAccessibilityMetadata,
                perform: perform,
                adjustZoom: { interactionState.adjustZoom($0) }
            )
            viewerContent
        }
        .background(theme.color("bg-1"))
        .task(id: key) {
            let requestedKey = key
            renderState.begin(requestedKey)
            interactionState.perform(.resetToFit)
            let rendered = await service.render(key: requestedKey)
            guard !Task.isCancelled else { return }
            renderState.apply(rendered, for: requestedKey)
        }
    }

    @ViewBuilder
    private var viewerContent: some View {
        if interactionState.showsSource {
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
                        .scaleEffect(interactionState.scale(adding: magnification))
                        .offset(Self.displayTranslation(
                            committed: interactionState.translation,
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
                interactionState.translate(by: value.translation)
            }
    }

    private var zoomGesture: some Gesture {
        MagnifyGesture()
            .updating($magnification) { value, magnification, _ in
                magnification = value.magnification
            }
            .onEnded { value in
                interactionState.zoom(by: value.magnification)
            }
    }

    private func perform(_ action: MermaidViewerAction) {
        guard interactionState.perform(action) == .copySource else { return }
        Clipboard.copy(source)
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
    let showsSource: Bool
    let zoomAccessibilityMetadata: MermaidViewerZoomAccessibilityMetadata
    let perform: (MermaidViewerAction) -> Void
    let adjustZoom: (MermaidViewerZoomAdjustment) -> Void

    @Environment(\.theme) private var theme

    var body: some View {
        HStack(spacing: 12) {
            Text("MERMAID")
                .font(.system(size: 11, weight: .semibold))
                .tracking(0.4)
                .foregroundStyle(theme.color("fg-faint"))
            Spacer(minLength: 0)
            Button(action: { perform(.zoomOut) }) {
                Label("Zoom out", systemImage: "minus.magnifyingglass")
                    .labelStyle(.iconOnly)
            }
            .help("Zoom out")
            .keyboardShortcut(MermaidViewerAction.zoomOut.shortcut.asKeyboardShortcut())
            Button(action: { perform(.actualSize) }) {
                Text(zoomAccessibilityMetadata.value)
                    .monospacedDigit()
                    .frame(minWidth: 38)
            }
            .help("Set zoom to 100%")
            .keyboardShortcut(MermaidViewerAction.actualSize.shortcut.asKeyboardShortcut())
            .accessibilityLabel(zoomAccessibilityMetadata.label)
            .accessibilityValue(zoomAccessibilityMetadata.value)
            .accessibilityAdjustableAction { direction in
                switch direction {
                case .increment:
                    adjustZoom(.increment)
                case .decrement:
                    adjustZoom(.decrement)
                @unknown default:
                    break
                }
            }
            Button(action: { perform(.zoomIn) }) {
                Label("Zoom in", systemImage: "plus.magnifyingglass")
                    .labelStyle(.iconOnly)
            }
            .help("Zoom in")
            .keyboardShortcut(MermaidViewerAction.zoomIn.shortcut.asKeyboardShortcut())
            Button("Reset") {
                perform(.resetToFit)
            }
            .keyboardShortcut(MermaidViewerAction.resetToFit.shortcut.asKeyboardShortcut())
            Divider()
                .frame(height: 16)
            Button(showsSource ? "Hide source" : "Show source") {
                perform(.toggleSource)
            }
            .keyboardShortcut(MermaidViewerAction.toggleSource.shortcut.asKeyboardShortcut())
            Button("Copy") {
                perform(.copySource)
            }
            .keyboardShortcut(MermaidViewerAction.copySource.shortcut.asKeyboardShortcut())
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
