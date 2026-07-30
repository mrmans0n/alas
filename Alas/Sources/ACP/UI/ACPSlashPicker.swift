import AppKit
import SwiftUI

/// Model backing the reactive slash-command picker. The text view writes
/// the live query string into `query` as the user types after `/`; the
/// picker view re-renders the filtered list. Arrow keys and Enter in
/// the text view call `moveUp` / `moveDown` / `selected()` to navigate
/// and accept without ever moving focus out of the composer.
@MainActor
final class ACPSlashPickerModel: ObservableObject {
    @Published var query: String = ""
    @Published private(set) var selectedIndex: Int = 0
    let allSuggestions: [ACPPromptSuggestion]

    init(suggestions: [ACPPromptSuggestion]) {
        // De-duplicate by `command` (case-sensitive) keeping the first
        // occurrence in original order. Some agents emit the same slash
        // command more than once (e.g. across re-sent
        // `available_commands_update` payloads); duplicates would otherwise
        // render as repeated rows and, with element-based ForEach identity,
        // as blank phantom rows.
        var seen = Set<String>()
        self.allSuggestions = suggestions.filter { seen.insert($0.command).inserted }
    }

    /// Score each suggestion by how well it matches the (lowercased)
    /// query and keep only positive matches. Empty query keeps the full
    /// list in original order. Score formula: prefix > contains > subseq.
    var filtered: [ACPPromptSuggestion] {
        let q = query.lowercased()
        if q.isEmpty { return allSuggestions }
        var scored: [(ACPPromptSuggestion, Int)] = []
        for s in allSuggestions {
            // Compare without the leading "/" so a query of "init"
            // matches "/init" cleanly.
            let name = s.command.hasPrefix("/")
                ? String(s.command.dropFirst()).lowercased()
                : s.command.lowercased()
            if let score = matchScore(query: q, name: name) {
                scored.append((s, score))
            }
        }
        scored.sort { $0.1 > $1.1 }
        return scored.map(\.0)
    }

    func moveUp() {
        let n = filtered.count
        guard n > 0 else { return }
        selectedIndex = (selectedIndex - 1 + n) % n
    }
    func moveDown() {
        let n = filtered.count
        guard n > 0 else { return }
        selectedIndex = (selectedIndex + 1) % n
    }

    /// Currently-highlighted suggestion (clamped to the filtered list).
    func selected() -> ACPPromptSuggestion? {
        let list = filtered
        guard !list.isEmpty else { return nil }
        let i = min(selectedIndex, list.count - 1)
        return list[i]
    }

    /// Called whenever the query changes. Resets the cursor to the top.
    func setQuery(_ q: String) {
        query = q
        selectedIndex = 0
    }

    /// Returns a positive score when `name` matches `query`, or `nil` if
    /// it doesn't match at all. Ordering: exact > prefix > contains >
    /// subsequence, with shorter names winning ties.
    private func matchScore(query: String, name: String) -> Int? {
        if name == query { return 1000 }
        if name.hasPrefix(query) { return 900 - name.count }
        if name.contains(query) { return 600 - name.count }
        if isSubsequence(query, of: name) { return 300 - name.count }
        return nil
    }

    private func isSubsequence(_ q: String, of name: String) -> Bool {
        var qi = q.startIndex
        for c in name {
            if qi == q.endIndex { return true }
            if c == q[qi] { qi = q.index(after: qi) }
        }
        return qi == q.endIndex
    }
}

/// SwiftUI list rendered inside the floating panel. Visually mirrors
/// the model/mode picker dropdowns: rounded glass background, mono
/// command name on the left, dim description on the right.
struct ACPSlashPickerView: View {
    @ObservedObject var model: ACPSlashPickerModel
    let onPick: (ACPPromptSuggestion) -> Void
    @Environment(\.theme) private var theme

    var body: some View {
        let items = model.filtered
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 0) {
                    if items.isEmpty {
                        Text("No matches")
                            .font(.system(size: 11.5))
                            .foregroundStyle(theme.color("fg-faint"))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 10).padding(.vertical, 6)
                    } else {
                        // Identity is the command string, kept consistent
                        // across the ForEach `id:`, the row `.id()` and
                        // `scrollTo`. The model de-duplicates by command in its
                        // init, so commands are unique here — no element-id
                        // collision. A positional id would instead freeze
                        // LazyVStack rows against the list re-sorting on every
                        // keystroke, leaving stale rows on screen.
                        ForEach(Array(items.enumerated()), id: \.element.command) { idx, s in
                            row(s, isSelected: idx == model.selectedIndex)
                                .id(s.command)
                                .contentShape(Rectangle())
                                .onTapGesture { onPick(s) }
                        }
                    }
                }
                .padding(.vertical, 4)
            }
            .onChange(of: model.selectedIndex) { _, new in
                guard items.indices.contains(new) else { return }
                withAnimation(.easeOut(duration: 0.08)) {
                    proxy.scrollTo(items[new].command, anchor: .center)
                }
            }
        }
    }

    private func row(_ s: ACPPromptSuggestion, isSelected: Bool) -> some View {
        HStack(spacing: 8) {
            Text(s.command)
                .font(.system(size: 12, weight: .medium, design: .monospaced))
                .foregroundStyle(theme.color("fg"))
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
            if let hint = s.hint, !hint.isEmpty {
                Text("‹\(hint)›")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(theme.color("fg-faint"))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .layoutPriority(-1)
            }
            if let d = s.description, !d.isEmpty {
                MarqueeText(
                    text: d,
                    font: .system(size: 11),
                    color: theme.color("fg-faint"),
                    isActive: isSelected
                )
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10).padding(.vertical, 5)
        .background(
            RoundedRectangle(cornerRadius: 5)
                .fill(isSelected ? theme.color("accent").opacity(0.25) : .clear)
                .padding(.horizontal, 4)
        )
    }
}

/// Single-line label that horizontally scrolls (marquees) its text
/// once the content overflows the available width, after a brief
/// initial pause. Toggling `isActive` on/off restarts the cycle so
/// switching rows in the picker doesn't leave stale offsets.
private struct MarqueeText: View {
    let text: String
    let font: Font
    let color: Color
    let isActive: Bool

    @State private var textWidth: CGFloat = 0
    @State private var containerWidth: CGFloat = 0
    @State private var offset: CGFloat = 0
    @State private var animTask: Task<Void, Never>?

    var body: some View {
        GeometryReader { geo in
            Text(text)
                .font(font)
                .foregroundStyle(color)
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
                .background(
                    GeometryReader { tg in
                        Color.clear
                            .preference(key: MarqueeTextWidthKey.self,
                                        value: tg.size.width)
                    }
                )
                .offset(x: offset)
                .frame(width: geo.size.width, height: geo.size.height,
                       alignment: .leading)
                .clipped()
                .onPreferenceChange(MarqueeTextWidthKey.self) { w in
                    textWidth = w
                    containerWidth = geo.size.width
                    restartAnimation()
                }
                .onChange(of: geo.size.width) { _, new in
                    containerWidth = new
                    restartAnimation()
                }
                .onChange(of: isActive) { _, _ in
                    restartAnimation()
                }
                .onAppear { restartAnimation() }
                .onDisappear {
                    animTask?.cancel()
                    animTask = nil
                }
        }
        .frame(height: 14)
    }

    private func restartAnimation() {
        animTask?.cancel()
        offset = 0
        let overflow = textWidth - containerWidth
        guard isActive, overflow > 4 else { return }
        // Run the scroll on a task so each restart cleanly cancels the
        // prior run (selecting a different row, container resize).
        animTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_000_000_000) // 1s hold
            if Task.isCancelled { return }
            let duration = max(2.0, Double(overflow) / 35.0)
            withAnimation(.linear(duration: duration)) {
                offset = -overflow - 12
            }
            try? await Task.sleep(nanoseconds: UInt64((duration + 1.2) * 1_000_000_000))
            if Task.isCancelled { return }
            // Snap back without animation and loop.
            offset = 0
            restartAnimation()
        }
    }
}

private struct MarqueeTextWidthKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

/// Floating NSPanel that hosts `ACPSlashPickerView`. Owned by
/// `ACPNSTextView` while open and dismissed when the slash context
/// breaks (caret moves away, command is accepted, or `/` is deleted).
final class ACPSlashPickerPanel: NSPanel {
    let model: ACPSlashPickerModel
    private let onPick: (ACPPromptSuggestion) -> Void

    init(suggestions: [ACPPromptSuggestion],
         theme: Theme,
         onPick: @escaping (ACPPromptSuggestion) -> Void) {
        self.model = ACPSlashPickerModel(suggestions: suggestions)
        self.onPick = onPick
        super.init(
            // Wider than the original 320pt so skill descriptions have
            // breathing room before the marquee kicks in.
            contentRect: .init(x: 0, y: 0, width: 520, height: 260),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        self.isFloatingPanel = true
        self.hasShadow = true
        self.backgroundColor = .clear
        self.isOpaque = false

        guard let content = contentView else { return }
        let blur = NSVisualEffectView(frame: content.bounds)
        blur.material = .menu
        blur.blendingMode = .behindWindow
        blur.state = .active
        blur.appearance = NSAppearance(named: .vibrantDark)
        blur.wantsLayer = true
        blur.layer?.cornerRadius = 10
        blur.layer?.masksToBounds = true
        blur.layer?.borderWidth = 0.5
        blur.layer?.borderColor = NSColor(white: 1, alpha: 0.10).cgColor
        blur.autoresizingMask = [.width, .height]
        content.addSubview(blur)

        let host = NSHostingView(rootView: ACPSlashPickerView(model: model) { [weak self] s in
            self?.onPick(s)
        }.environment(\.theme, theme))
        host.frame = blur.bounds.insetBy(dx: 4, dy: 4)
        host.autoresizingMask = [.width, .height]
        blur.addSubview(host)
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}
