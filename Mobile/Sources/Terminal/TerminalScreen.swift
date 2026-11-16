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
        TerminalSurface(console: console, columns: console.columns, rows: console.rows, controlling: console.isControlling)
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
    let rows: Int
    let controlling: Bool

    func makeCoordinator() -> Coordinator { Coordinator(console: console) }

    func makeUIView(context: Context) -> HostGridView {
        let container = HostGridView()
        let view = container.terminal
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
        return container
    }

    func updateUIView(_ container: HostGridView, context: Context) {
        // A holder on a host that resizes lays the console out for the phone; anyone else shows the host's grid.
        container.hostGrid = controlling && console.canResize ? nil : (columns, rows)
        let view = container.terminal
        if controlling {
            if !view.isFirstResponder { _ = view.becomeFirstResponder() }
        } else if view.isFirstResponder {
            _ = view.resignFirstResponder()
        }
    }

    @MainActor
    final class Coordinator: NSObject, TerminalViewDelegate {
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

/// Holds the terminal at exactly the host's grid, as the Mac's viewer does: the host lays its
/// screen out for its rows and columns, so a smaller grid clips and a different one wraps
/// differently. The font is the largest, up to the default, that fits the grid on screen; past the
/// minimum the grid overflows and is clipped. Without a host grid the terminal fills the view.
final class HostGridView: UIView {
    static let defaultSize: CGFloat = 12
    static let minimumSize: CGFloat = 5

    let terminal = TerminalView(frame: .zero)

    var hostGrid: (columns: Int, rows: Int)? {
        didSet {
            if hostGrid?.columns != oldValue?.columns || hostGrid?.rows != oldValue?.rows { setNeedsLayout() }
        }
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        clipsToBounds = true
        backgroundColor = .black
        addSubview(terminal)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func layoutSubviews() {
        super.layoutSubviews()
        guard bounds.width > 0, bounds.height > 0 else { return }
        guard let grid = hostGrid, grid.columns > 0, grid.rows > 0 else {
            setFont(Self.defaultSize)
            terminal.frame = bounds
            return
        }
        var size = Self.defaultSize
        while size > Self.minimumSize {
            let cell = Self.cell(size)
            if cell.width * CGFloat(grid.columns) <= bounds.width, cell.height * CGFloat(grid.rows) <= bounds.height { break }
            size -= 0.5
        }
        setFont(size)
        let cell = Self.cell(size)
        // Half a cell of slack: SwiftTerm floors frame / cell, so this lands on the grid exactly.
        terminal.frame = CGRect(x: 0, y: 0, width: cell.width * (CGFloat(grid.columns) + 0.5),
                                height: cell.height * (CGFloat(grid.rows) + 0.5))
    }

    private func setFont(_ size: CGFloat) {
        guard abs(terminal.font.pointSize - size) >= 0.1 else { return }
        terminal.font = UIFont.monospacedSystemFont(ofSize: size, weight: .regular)
    }

    /// SwiftTerm's cell for a font of `size`, measured as `computeFontDimensions` measures it.
    private static func cell(_ size: CGFloat) -> CGSize {
        let font = UIFont.monospacedSystemFont(ofSize: size, weight: .regular)
        let scale = UITraitCollection.current.displayScale > 0 ? UITraitCollection.current.displayScale : 3
        let width = ("W" as NSString).size(withAttributes: [.font: font]).width
        let ctFont = font as CTFont
        let height = ceil(CTFontGetAscent(ctFont) + CTFontGetDescent(ctFont) + CTFontGetLeading(ctFont))
        return CGSize(width: max(1, (width * scale).rounded() / scale), height: max(1, ceil(height * scale) / scale))
    }
}
