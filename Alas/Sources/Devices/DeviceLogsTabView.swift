import AlasCore
import AppKit
import SwiftUI

/// A device's logs in a center tab: the foreground app (or a chosen one, or
/// all processes), a level, Apple subsystems on or off (iOS), a search, and a
/// banner for each crash written while it is open.
struct DeviceLogsTabView: View {
    let tabState: SimulatorLogsTabState
    /// Kept for the tab's life: a source follows its app until `stop()`.
    @State private var source: any DeviceLogSource
    @Environment(\.theme) private var theme

    enum Source: Hashable {
        case foreground
        case app(String)
        case all
    }

    init(tabState: SimulatorLogsTabState, source: @autoclosure () -> any DeviceLogSource) {
        self.tabState = tabState
        _source = State(initialValue: source())
    }

    @State private var stream = SimulatorLogStream()
    @State private var selection = Source.foreground
    @State private var level = SimulatorLogLevel.default
    @State private var includeApple = false
    @State private var search = ""
    /// While paused, how many lines the view shows.
    @State private var pausedAt: Int?
    @State private var apps: [SimulatorApp] = []
    /// The app the stream follows now; nil for all processes.
    @State private var following: String?
    @State private var noAppInFront = false
    @State private var crashes: [SimulatorCrashReport] = []
    @State private var openedAt = Date()
    @State private var atBottom = true
    /// Reports the user dismissed, so polling doesn't bring them back.
    @State private var dismissed: Set<String> = []

    private var udid: String { tabState.udid }

    private var visible: ArraySlice<SimulatorLogLine> {
        let shown = pausedAt.map { stream.lines.prefix($0) } ?? stream.lines[...]
        let query = search.trimmingCharacters(in: .whitespaces)
        return query.isEmpty ? shown : shown.filter { $0.matches(query) }[...]
    }

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            ForEach(crashes, id: \.report) { crashBanner($0) }
            if let reason = stream.stopReason { stoppedBanner(reason) }
            if noAppInFront && selection == .foreground {
                note("No app in front. Open one on the device, or pick an app.")
            }
            if stream.dropped > 0 {
                note("\(stream.dropped) older lines dropped.")
            }
            lineList
        }
        .task { apps = await source.userApps() }
        .task(id: selection) { await follow() }
        .task { await watchCrashes() }
        .onChange(of: level) { restart() }
        .onChange(of: includeApple) { restart() }
        .onDisappear {
            source.stop()
            stream.stop()
        }
    }

    private var toolbar: some View {
        HStack(spacing: 8) {
            Picker("App", selection: $selection) {
                Text("Foreground App").tag(Source.foreground)
                ForEach(apps) { Text($0.name).tag(Source.app($0.bundleID)) }
                Text("All Processes").tag(Source.all)
            }
            .fixedSize()
            Picker("Level", selection: $level) {
                Text("Default and Above").tag(SimulatorLogLevel.default)
                Text("Include Info").tag(SimulatorLogLevel.info)
                Text("Include Debug").tag(SimulatorLogLevel.debug)
                Text("Errors and Faults").tag(SimulatorLogLevel.error)
            }
            .fixedSize()
            if source.hasAppleSubsystems {
                Toggle("Apple subsystems", isOn: $includeApple)
                    .toggleStyle(.checkbox)
            }
            TextField("Search", text: $search)
                .textFieldStyle(.roundedBorder)
                .frame(minWidth: 120, maxWidth: 220)
            Spacer()
            ToolbarBtn(icon: pausedAt == nil ? "pause" : "play", tooltip: pausedAt == nil ? "Pause" : "Resume") {
                pausedAt = pausedAt == nil ? stream.lines.count : nil
            }
            ToolbarBtn(icon: "trash", tooltip: "Clear") {
                stream.clear()
                pausedAt = nil
            }
            ToolbarBtn(icon: "doc.on.doc", tooltip: "Copy visible lines", action: copyVisible)
        }
        .controlSize(.small)
        .font(.system(size: 11))
        .padding(.horizontal, 10)
        .frame(height: 34)
        .background(theme.color("bg-2"))
    }

    private var lineList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 1) {
                    ForEach(Array(visible.enumerated()), id: \.offset) { index, line in
                        row(line).id(index)
                    }
                    Color.clear.frame(height: 1).id("bottom")
                        .onAppear { atBottom = true }
                        .onDisappear { atBottom = false }
                }
                .padding(8)
            }
            .overlay(alignment: .bottomTrailing) {
                if !atBottom {
                    AlasButton(title: "Jump to Latest", icon: "arrow.down", compact: true) {
                        proxy.scrollTo("bottom", anchor: .bottom)
                    }
                    .padding(12)
                }
            }
            .onChange(of: stream.lines.count) {
                if atBottom, pausedAt == nil { proxy.scrollTo("bottom", anchor: .bottom) }
            }
        }
        .font(.system(size: 11, design: .monospaced))
        .textSelection(.enabled)
    }

    private func row(_ line: SimulatorLogLine) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(line.time).foregroundStyle(theme.color("fg-faint"))
            Text(line.level.prefix(1).uppercased())
                .frame(width: 10)
                .foregroundStyle(theme.color(levelTone(line.level)))
            Text("\(line.process)[\(line.pid)]").foregroundStyle(theme.color("fg-dim"))
            if let subsystem = line.subsystem {
                Text(line.category.map { "\(subsystem):\($0)" } ?? subsystem)
                    .foregroundStyle(theme.color("fg-faint"))
                    .lineLimit(1)
            }
            Text(line.message)
                .foregroundStyle(theme.color(["info", "debug"].contains(line.level) ? "fg-dim" : "fg"))
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func levelTone(_ level: String) -> String {
        switch level {
        case "error", "fault": "del"
        case "info", "debug": "fg-faint"
        default: "fg-dim"
        }
    }

    private func crashBanner(_ crash: SimulatorCrashReport) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.octagon.fill").foregroundStyle(theme.color("del"))
            Text("\(crash.appName) crashed: \(crash.exception)\(crash.frames.first.map { " in \($0)" } ?? "")")
                .lineLimit(2)
            Spacer()
            // iOS writes a report file; Android's report is the stack itself.
            if FileManager.default.fileExists(atPath: crash.report) {
                AlasButton(title: "Open Report", compact: true) {
                    NSWorkspace.shared.open(URL(fileURLWithPath: crash.report))
                }
            } else {
                AlasButton(title: "Copy Report", compact: true) {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(crash.report, forType: .string)
                }
            }
            AlasButton(title: "Dismiss", style: .subtle, compact: true) {
                crashes.removeAll { $0.report == crash.report }
                dismissed.insert(crash.report)
            }
        }
        .font(.system(size: 11.5))
        .padding(8)
        .background(theme.color("del").opacity(0.12))
    }

    private func stoppedBanner(_ reason: String) -> some View {
        HStack {
            Text(reason).foregroundStyle(theme.color("fg-dim"))
            Spacer()
            AlasButton(title: "Restart", compact: true) { restart() }
        }
        .font(.system(size: 11.5))
        .padding(8)
        .background(theme.color("bg-3"))
    }

    private func note(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11))
            .foregroundStyle(theme.color("fg-faint"))
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
    }

    private func copyVisible() {
        let text = visible.map { line in
            [line.time, line.level, "\(line.process)[\(line.pid)]", line.subsystem ?? "", line.message].joined(separator: " ")
        }.joined(separator: "\n")
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    // MARK: Following

    /// Starts the stream for the chosen source; for the foreground app, follows
    /// the app in front as apps come and go.
    private func follow() async {
        switch selection {
        case .all:
            following = nil
            restart()
        case .app(let id):
            following = id
            restart()
        case .foreground:
            following = nil
            for await front in source.frontApps() {
                noAppInFront = front == nil
                guard let front, front != following else { continue }
                following = front
                restart()
            }
        }
    }

    private func restart() {
        // The foreground source waits until it knows the app.
        if selection == .foreground, following == nil { return }
        pausedAt = nil
        let app = following
        Task { await source.start(stream, app: app, level: level, includeApple: includeApple) }
    }

    private func watchCrashes() async {
        while !Task.isCancelled {
            let app: String? = switch selection {
            case .all: nil
            case .app(let id): id
            case .foreground: following
            }
            let found = await source.crashes(app: app, since: openedAt)
            for report in found where !dismissed.contains(report.report) && !crashes.contains(where: { $0.report == report.report }) {
                crashes.append(report)
            }
            try? await Task.sleep(for: .seconds(5))
        }
    }
}
