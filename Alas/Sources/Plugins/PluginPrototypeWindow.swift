#if DEBUG
import AppKit
import SwiftUI

@MainActor
final class PluginPrototypeModel: ObservableObject {
    @Published private(set) var panel: PluginPanel?
    @Published private(set) var status = "Loading…"
    @Published private(set) var busy = false
    private var runtime: PluginPrototypeRuntime?

    func reload() {
        perform("reload") { runtime in try await runtime.reload() }
    }

    func send(_ id: String) {
        perform(id) { runtime in try await runtime.send(event: id) }
    }

    private func perform(_ label: String, _ body: @escaping @Sendable (PluginPrototypeRuntime) async throws -> PluginPanel) {
        guard !busy else { return }
        busy = true
        Task {
            let start = ContinuousClock.now
            do {
                let runtime = try runtime ?? PluginPrototypeRuntime(wasm: PluginPrototypeSample.wasm())
                self.runtime = runtime
                panel = try await body(runtime)
                status = "\(label): ok"
            } catch {
                // Keep the last good panel; the plugin stays loaded after a trap.
                status = "\(label): \(String(describing: error).split(separator: "\n").first ?? "")"
            }
            let memory = await runtime?.memoryBytes ?? 0
            status += " · \((ContinuousClock.now - start).formatted(.units(allowed: [.milliseconds]))) · \(memory / 1024) KiB"
            busy = false
        }
    }
}

struct PluginPrototypeView: View {
    @StateObject private var model = PluginPrototypeModel()

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let panel = model.panel {
                Text(panel.title).font(.headline)
                Text(panel.text)
                HStack {
                    ForEach(panel.buttons) { button in
                        Button(button.label) { model.send(button.id) }
                    }
                }
                .disabled(model.busy)
            }
            Spacer()
            Divider()
            HStack {
                Button("Reload plugin") { model.reload() }
                    .disabled(model.busy)
                if model.busy {
                    ProgressView().controlSize(.small)
                }
                Text(model.status)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
        }
        .padding(16)
        .frame(minWidth: 640, minHeight: 200)
        .task { model.reload() }
    }
}

@MainActor
final class PluginPrototypeWindowController: NSObject, NSWindowDelegate {
    static let shared = PluginPrototypeWindowController()
    private var window: NSWindow?

    func show() {
        if let window {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let win = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 640, height: 200),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered, defer: false)
        win.title = "Plugin prototype"
        win.isReleasedWhenClosed = false
        win.contentView = NSHostingView(rootView: PluginPrototypeView())
        win.center()
        win.delegate = self
        win.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        window = win
    }

    func windowWillClose(_ notification: Notification) {
        if let closing = notification.object as? NSWindow, closing === window {
            window = nil
        }
    }
}
#endif
