import SwiftUI

struct AppearancePane: View {
    @Bindable var state: AppState
    @Environment(\.theme) var theme

    private let themes: [(String, String, Color, Color)] = [
        ("cool-slate", "Cool Slate", Color(hex: "#26323b"), Color(hex: "#5fb7c4")),
        ("light",      "Light",      Color(hex: "#f0eee9"), Color(hex: "#5b8a91")),
    ]

    private let accents: [(String, Color)] = [
        ("teal",   Color(hex: "#5fb7c4")),
        ("mint",   Color(hex: "#7fc6a8")),
        ("amber",  Color(hex: "#d3a25c")),
        ("coral",  Color(hex: "#d77b88")),
        ("iris",   Color(hex: "#9789c7")),
    ]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                Text("Appearance").font(.system(size: 18, weight: .semibold))
                Text("Themes, density, window chrome, and display defaults.")
                    .font(.system(size: 12.5)).foregroundColor(theme.color("fg-dim"))
                    .padding(.bottom, 12)

                SettingsGroup(title: "Theme") {
                    SettingsRow(name: "Color scheme",
                                desc: "Pick a light or dark theme.") {
                        HStack(spacing: 8) {
                            ForEach(themes, id: \.0) { (id, name, c1, c2) in
                                Button {
                                    state.config.themeId = id
                                    // Manually picking a theme implicitly turns
                                    // off match-system mode (themeStore.activate
                                    // already does this in-memory) — also clear
                                    // the persisted flag so the toggle reflects
                                    // reality + relaunches don't re-enter
                                    // match-system mode.
                                    state.config.matchSystemTheme = false
                                    try? state.themeStore.activate(id: id)
                                    state.saveConfig()
                                } label: {
                                    VStack(spacing: 4) {
                                        ZStack(alignment: .topLeading) {
                                            Rectangle().fill(c1).frame(width: 72, height: 46)
                                            Rectangle().fill(c2).frame(width: 16, height: 4).padding(4)
                                        }
                                        .clipShape(RoundedRectangle(cornerRadius: 4))
                                        .overlay(
                                            RoundedRectangle(cornerRadius: 4)
                                                .strokeBorder(state.config.themeId == id ? theme.color("accent") : Color.black.opacity(0.4),
                                                              lineWidth: state.config.themeId == id ? 2 : 0.5)
                                        )
                                        Text(name).font(.system(size: 10.5))
                                            .foregroundColor(theme.color("fg-muted"))
                                    }
                                    .padding(4)
                                    .background(state.config.themeId == id ? theme.color("accent-soft") : .clear)
                                    .clipShape(RoundedRectangle(cornerRadius: 8))
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                    SettingsRow(name: "Accent color") {
                        HStack(spacing: 8) {
                            ForEach(accents, id: \.0) { (id, color) in
                                Button {
                                    state.config.accent = id
                                    state.saveConfig()
                                    // Push the accent override into the live
                                    // theme so the chrome updates immediately.
                                    state.themeStore.setAccent(id)
                                } label: {
                                    Circle().fill(color).frame(width: 24, height: 24)
                                        .overlay(
                                            Circle().strokeBorder(.white, lineWidth: state.config.accent == id ? 2 : 0)
                                        )
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                    SettingsRow(name: "Match system") {
                        AlasToggle(on: Binding(
                            get: { state.config.matchSystemTheme },
                            set: { newValue in
                                state.config.matchSystemTheme = newValue
                                state.saveConfig()
                                state.themeStore.setMatchSystem(newValue)
                            }
                        ))
                    }
                }
                SettingsGroup(title: "Layout") {
                    SettingsRow(name: "Density") {
                        Seg(value: bind(\.density), options: [
                            ("compact", "compact"),
                            ("comfortable", "comfortable"),
                            ("spacious", "spacious"),
                        ])
                    }
                    SettingsRow(name: "Sidebar width",
                                desc: "Width of the repos/worktrees sidebar.") {
                        AlasField(text: Binding(
                            get: { String(Int(state.config.sidebarWidth)) },
                            set: { state.config.sidebarWidth = Double($0) ?? 244
                            state.saveConfig() }
                        ), monospaced: true).frame(width: 100)
                    }
                }
                SettingsGroup(title: "Markdown") {
                    SettingsRow(name: "Default view mode",
                                desc: "Initial mode when a markdown file is opened.") {
                        Picker("", selection: Binding(
                            get: { state.config.markdown.defaultViewMode },
                            set: {
                                state.config.markdown.defaultViewMode = $0
                                state.saveConfig()
                            }
                        )) {
                            Text("Editor").tag(MarkdownViewMode.editor)
                            Text("Split").tag(MarkdownViewMode.split)
                            Text("Preview").tag(MarkdownViewMode.preview)
                        }
                        .pickerStyle(.segmented)
                        .frame(width: 240)
                    }
                }
            }
            .padding(.horizontal, 32).padding(.vertical, 24)
        }
    }

    private func bind<T>(_ kp: WritableKeyPath<AppConfig, T>) -> Binding<T> {
        Binding(
            get: { state.config[keyPath: kp] },
            set: { state.config[keyPath: kp] = $0
            state.saveConfig() }
        )
    }
}
