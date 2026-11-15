import AlasRemoteKit
import SwiftTerm
import SwiftUI

/// A host console, full screen. Opens as a viewer; Take Control lets the
/// keyboard type into it.
struct TerminalScreen: View {
    @State private var console: TerminalConsole

    init(hub: HostHub, hostID: UUID, console: PeerConsoleSummary) {
        _console = State(initialValue: TerminalConsole(hub: hub, hostID: hostID, console: console))
    }

    var body: some View {
        TerminalSurface(console: console, columns: console.columns, controlling: console.isControlling)
            .background(Color.black)
            .overlay {
                switch console.phase {
                case .attaching:
                    ProgressView().tint(.white)
                case .ended(let message):
                    ContentUnavailableView("Terminal closed", systemImage: "terminal", description: Text(message))
                        .background(.background)
                case .live:
                    EmptyView()
                }
            }
            .safeAreaInset(edge: .bottom) {
                if console.phase == .live, !console.isControlling {
                    Label(viewingNote, systemImage: "eye")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 16).padding(.vertical, 10)
                        .glassEffect(.regular, in: Capsule())
                        .padding(.bottom, 8)
                }
            }
            .navigationTitle(console.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar(.hidden, for: .tabBar)
            .toolbar {
                if console.phase == .live {
                    ToolbarItem(placement: .primaryAction) {
                        if console.isControlling {
                            Button("Release", systemImage: "hand.raised.slash") { console.releaseControl() }
                        } else {
                            Button("Take Control", systemImage: "keyboard") { console.takeControl() }
                        }
                    }
                }
            }
            .onAppear { console.attach() }
            .onDisappear { console.detach() }
    }

    private var viewingNote: String {
        switch console.control.owner {
        case .anotherPeer: "Another device is typing. Take control to type."
        default: "Viewing. Take control to type."
        }
    }
}

/// SwiftTerm's view, fed by the console. Without a lease to resize the host
/// grid, the font shrinks so the host's columns fit the screen's width.
private struct TerminalSurface: UIViewRepresentable {
    let console: TerminalConsole
    let columns: Int
    let controlling: Bool

    func makeCoordinator() -> Coordinator { Coordinator(console: console) }

    func makeUIView(context: Context) -> FittingTerminalView {
        let view = FittingTerminalView(frame: .zero)
        view.terminalDelegate = context.coordinator
        // The phone forwards no mouse reports; a tap only places focus.
        view.allowMouseReporting = false
        view.keyboardAppearance = .dark
        view.nativeBackgroundColor = .black
        view.nativeForegroundColor = UIColor(white: 0.92, alpha: 1)
        console.write = { [weak view] data, isSnapshot in
            // A snapshot replaces the screen: reset (RIS) before it, in the same feed.
            let bytes = isSnapshot ? Data("\u{1B}c".utf8) + data : data
            view?.feed(byteArray: ArraySlice(bytes))
        }
        return view
    }

    func updateUIView(_ view: FittingTerminalView, context: Context) {
        // A holder on a host that resizes gets a readable font and its own grid.
        view.columnsToFit = controlling && console.canResize ? nil : columns
        if controlling {
            if !view.isFirstResponder { _ = view.becomeFirstResponder() }
        } else if view.isFirstResponder {
            _ = view.resignFirstResponder()
        }
    }

    @MainActor
    // SwiftTerm calls its delegate from the view, on the main thread.
    final class Coordinator: NSObject, @preconcurrency TerminalViewDelegate {
        let console: TerminalConsole

        init(console: TerminalConsole) { self.console = console }

        func send(source: TerminalView, data: ArraySlice<UInt8>) { console.viewWrote(Data(data)) }
        func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {
            console.viewResized(rows: newRows, columns: newCols)
        }
        func setTerminalTitle(source: TerminalView, title: String) {}
        func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
        func scrolled(source: TerminalView, position: Double) {}
        func requestOpenLink(source: TerminalView, link: String, params: [String: String]) {}
        func bell(source: TerminalView) {}
        func clipboardCopy(source: TerminalView, content: Data) {
            UIPasteboard.general.string = String(data: content, encoding: .utf8)
        }
        func clipboardRead(source: TerminalView) -> Data? { nil }
        func iTermContent(source: TerminalView, content: ArraySlice<UInt8>) {}
        func rangeChanged(source: TerminalView, startY: Int, endY: Int) {}
    }
}

/// Picks the largest monospaced font, up to the default, that fits `columnsToFit` across.
final class FittingTerminalView: TerminalView {
    static let defaultSize: CGFloat = 12
    static let minimumSize: CGFloat = 5

    var columnsToFit: Int? {
        didSet { if columnsToFit != oldValue { setNeedsLayout() } }
    }

    override func layoutSubviews() {
        fitFont()
        super.layoutSubviews()
    }

    private func fitFont() {
        guard bounds.width > 0 else { return }
        var size = Self.defaultSize
        if let columns = columnsToFit, columns > 0 {
            let probe = UIFont.monospacedSystemFont(ofSize: 100, weight: .regular)
            let advance = ("M" as NSString).size(withAttributes: [.font: probe]).width / 100
            // A little under the exact fit, so rounding never leaves the grid a column short.
            size = min(Self.defaultSize, max(Self.minimumSize, (bounds.width / (CGFloat(columns) * advance) * 0.98 * 10).rounded(.down) / 10))
        }
        guard abs(font.pointSize - size) >= 0.1 else { return }
        font = UIFont.monospacedSystemFont(ofSize: size, weight: .regular)
    }
}
