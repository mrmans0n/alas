import SwiftUI
import WebKit

struct WebPreviewTabView: View {
    let state: AppState
    let tab: WebPreviewTabState
    @State private var browser: WebPreviewBrowser
    @State private var selectionMode = SelectionMode.browse
    @State private var dragStart: CGPoint?
    @State private var dragEnd: CGPoint?
    @State private var showsConsole = false

    private enum SelectionMode: String, CaseIterable {
        case browse, region, element
        var icon: String {
            switch self {
            case .browse: "cursorarrow"
            case .region: "crop"
            case .element: "scope"
            }
        }
        var title: String {
            switch self {
            case .browse: "Browse"
            case .region: "Select screenshot region"
            case .element: "Inspect element"
            }
        }
    }

    init(state: AppState, tab: WebPreviewTabState) {
        self.state = state
        self.tab = tab
        _browser = State(initialValue: state.tabs.webPreviewBrowser(ownerKey: tab.ownerKey, remoteHost: tab.remoteHost))
    }

    var body: some View {
        @Bindable var browser = browser
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                tool("Back", icon: "chevron.left", disabled: !browser.canGoBack) { browser.webView.goBack() }
                tool("Forward", icon: "chevron.right", disabled: !browser.canGoForward) { browser.webView.goForward() }
                tool(browser.loading ? "Stop" : "Reload", icon: browser.loading ? "xmark" : "arrow.clockwise") {
                    if browser.loading { browser.webView.stopLoading()
                    browser.loading = false }
                    else if browser.error == nil && browser.webView.url != nil { browser.webView.reload() }
                    else { openAddress() }
                }
                TextField("http://localhost:3000", text: $browser.address)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(openAddress)
                    .accessibilityLabel("Preview URL")
                tool("Open in external browser", icon: "arrow.up.right.square", disabled: browser.webView.url == nil) {
                    if let url = browser.webView.url, WebPreviewNavigation.allows(url, remoteHost: tab.remoteHost) {
                        NSWorkspace.shared.open(url)
                    }
                }
            }
            .padding(8)
            Divider()
            HStack(spacing: 8) {
                Picker("Selection", selection: $selectionMode) {
                    ForEach(SelectionMode.allCases, id: \.self) { mode in
                        Image(systemName: mode.icon).help(mode.title).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .frame(width: 130)
                .disabled(browser.webView.url == nil || browser.loading || browser.capturing)
                tool("Capture viewport", icon: "camera", disabled: browser.webView.url == nil || browser.loading || browser.capturing) {
                    selectionMode = .browse
                    browser.captureRegion()
                }
                Spacer(minLength: 0)
                if browser.capturing { ProgressView().controlSize(.small) }
                tool("Console errors (\(browser.consoleErrors.count))", icon: "exclamationmark.bubble") { showsConsole.toggle() }
                    .popover(isPresented: $showsConsole) {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Console errors (\(browser.consoleErrors.count))").font(.headline)
                            if browser.consoleErrors.count == 100 {
                                Text("Console limit reached.").font(.caption).foregroundStyle(.secondary)
                            }
                            ScrollView {
                                Text(browser.consoleErrors.isEmpty ? "No errors recorded for this page." : browser.consoleErrors.joined(separator: "\n\n"))
                                    .font(.system(size: 11, design: .monospaced))
                                    .textSelection(.enabled)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }.padding().frame(width: 440, height: 280)
                    }
                Menu {
                    Text("Private storage for this preview. Logins last until the tab closes or Alas quits.")
                    Button("Clear Preview Cookies and Storage", systemImage: "trash") {
                        Task { @MainActor in
                            await browser.webView.configuration.websiteDataStore.removeData(
                                ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(), modifiedSince: .distantPast)
                            browser.webView.reload()
                        }
                    }
                } label: { Image(systemName: "lock.shield") }
                .menuStyle(.borderlessButton)
                .frame(width: 24)
                .help("Private preview storage")
            }
            .padding(.horizontal, 8).padding(.vertical, 5)
            if let error = browser.error {
                HStack(alignment: .top) {
                    Image(systemName: "exclamationmark.triangle")
                    Text(error).textSelection(.enabled)
                    Spacer(minLength: 0)
                }
                .font(.system(size: 12)).padding(10)
                .background(Color.yellow.opacity(0.12))
            }
            Divider()
            ZStack(alignment: .topLeading) {
                WebPreviewSurface(browser: browser)
                if browser.webView.url == nil && !browser.loading {
                    ContentUnavailableView("Web Preview", systemImage: "globe", description: Text("Enter a page URL."))
                        .allowsHitTesting(false)
                }
                if selectionMode != .browse {
                    Color.clear.contentShape(Rectangle())
                        .gesture(DragGesture(minimumDistance: 0)
                            .onChanged { value in
                                dragStart = value.startLocation
                                dragEnd = value.location
                            }
                            .onEnded { value in
                                if selectionMode == .element {
                                    browser.captureRegion(elementAt: value.location)
                                } else {
                                    browser.captureRegion(rect(from: value.startLocation, to: value.location))
                                }
                                dragStart = nil
                                dragEnd = nil
                                selectionMode = .browse
                            })
                    if let dragStart, let dragEnd, selectionMode == .region {
                        let selection = rect(from: dragStart, to: dragEnd)
                        Rectangle().fill(Color.accentColor.opacity(0.15))
                            .border(Color.accentColor, width: 1)
                            .frame(width: selection.width, height: selection.height)
                            .offset(x: selection.minX, y: selection.minY)
                            .allowsHitTesting(false)
                    }
                }
            }
            .clipped()
        }
        .onAppear {
            browser.onNavigate = { url in state.tabs.updateWebPreviewURL(worktreeId: tab.ownerKey, url: url) }
            if browser.webView.url == nil, let url = tab.url { browser.navigate(url) }
        }
        .onChange(of: tab.url) {
            if let url = tab.url, url != browser.webView.url { browser.navigate(url) }
        }
        .sheet(item: $browser.capture) { capture in
            WebPreviewFeedbackSheet(state: state, capture: capture)
        }
    }

    private func openAddress() {
        let value = browser.address.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = RunEndpointPolicy.endpoint(from: value) else {
            browser.error = "Enter a complete HTTP or HTTPS URL."
            return
        }
        browser.navigate(url)
    }

    private func rect(from start: CGPoint, to end: CGPoint) -> CGRect {
        CGRect(x: min(start.x, end.x), y: min(start.y, end.y),
               width: abs(end.x - start.x), height: abs(end.y - start.y))
    }

    private func tool(_ title: String, icon: String, disabled: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) { Image(systemName: icon).frame(width: 20, height: 20) }
            .buttonStyle(.borderless).disabled(disabled).help(title).accessibilityLabel(title)
    }
}

private struct WebPreviewFeedbackSheet: View {
    let state: AppState
    let capture: WebPreviewCapture
    @Environment(\.dismiss) private var dismiss
    @State private var message = ""
    @State private var sessionID = ""
    @State private var includeConsole = false
    @State private var sending = false
    @State private var error: String?
    @State private var showsImage = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Preview Feedback").font(.headline)
            if let image = NSImage(data: capture.png) {
                Button { showsImage = true } label: {
                    Image(nsImage: image).resizable().scaledToFit()
                        .frame(maxWidth: .infinity).frame(height: 180)
                        .background(Color.black.opacity(0.05))
                }.buttonStyle(.plain).help("Inspect screenshot")
            }
            ScrollView {
                Text(capture.prompt(message: "", includeConsole: includeConsole))
                    .font(.system(size: 11, design: .monospaced))
                    .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
            }.frame(height: 100)
            Text("Message").font(.subheadline)
            TextEditor(text: $message).font(.body).frame(height: 64)
                .border(Color.secondary.opacity(0.3))
                .accessibilityLabel("Feedback message")
                .disabled(sending)
            Toggle("Include console errors (\(capture.consoleErrors.count))", isOn: $includeConsole)
                .disabled(sending || capture.consoleErrors.isEmpty)
            Picker("Send to", selection: $sessionID) {
                Text("Choose a session").tag("")
                ForEach(WebPreviewFeedbackDelivery.recipients(state: state, ownerKey: capture.ownerKey)) { session in
                    Text(session.title.isEmpty ? "Untitled chat" : session.title).tag(session.id)
                }
            }.disabled(sending)
            if WebPreviewFeedbackDelivery.recipients(state: state, ownerKey: capture.ownerKey).isEmpty {
                Text("No open writable chats for this preview.").font(.caption).foregroundStyle(.secondary)
            }
            if let error { Text(error).foregroundStyle(.red).font(.caption) }
            HStack {
                if sending { ProgressView().controlSize(.small) }
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction).disabled(sending)
                Button("Send Feedback", systemImage: "paperplane") {
                    sending = true
                    Task { @MainActor in
                        do {
                            try await WebPreviewFeedbackDelivery.send(capture: capture, message: message,
                                includeConsole: includeConsole, sessionID: sessionID, state: state)
                            dismiss()
                        } catch { self.error = error.localizedDescription }
                        sending = false
                    }
                }
                .disabled(sending || sessionID.isEmpty || message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }.padding(20).frame(width: 580)
        .interactiveDismissDisabled(sending)
        .sheet(isPresented: $showsImage) {
            WebPreviewCaptureImage(png: capture.png)
        }
    }
}

private struct WebPreviewCaptureImage: View {
    let png: Data
    @Environment(\.dismiss) private var dismiss
    @State private var zoom = 1.0

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Image(systemName: "minus.magnifyingglass")
                Slider(value: $zoom, in: 0.25...3).frame(width: 180).accessibilityLabel("Screenshot zoom")
                Image(systemName: "plus.magnifyingglass")
                Text("\(Int(zoom * 100))%").monospacedDigit().frame(width: 45)
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
            }.padding(12)
            Divider()
            ScrollView([.horizontal, .vertical]) {
                if let image = NSImage(data: png) {
                    Image(nsImage: image).resizable()
                        .frame(width: image.size.width * zoom, height: image.size.height * zoom)
                }
            }
        }.frame(width: 800, height: 600)
    }
}
