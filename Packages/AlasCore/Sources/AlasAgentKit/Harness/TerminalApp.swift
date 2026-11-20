import Foundation
import AlasModel

/// A well-known program running in the foreground of a terminal, used to
/// badge and name its tab. Agents are not in this catalog: they come from
/// `HarnessKind`, which drives activity tracking as well.
public struct TerminalApp: Equatable, Hashable, Sendable {
    public enum Glyph: Equatable, Hashable, Sendable {
        /// A bundled monochrome brand mark, drawn as a template image.
        case brand(assetName: String)
        /// A bundled full-colour logo, drawn as is without a tile.
        case logo(assetName: String)
        /// An app icon-set symbol, for tools without a brand mark of their own.
        case symbol(String)
    }

    public let id: String
    public let displayName: String
    public let glyph: Glyph
    /// Tile background as `RRGGBB`.
    public let tintHex: String

    public init(id: String, displayName: String, glyph: Glyph, tintHex: String) {
        self.id = id
        self.displayName = displayName
        self.glyph = glyph
        self.tintHex = tintHex
    }
}

/// The programs worth badging, generated from `scripts/terminal-apps/catalog.tsv`.
public enum TerminalAppCatalog {
    /// The app for a foreground process, or nil when it is not a program
    /// worth badging (shells included).
    ///
    /// Interpreters (`node`, `python`, `java`, …) host most developer tools,
    /// so their arguments name the tool when `arguments` is given: npm, vite
    /// and pytest are scripts, Gradle and Maven are JVM main classes.
    public static func app(forExecutablePath path: String, arguments: [String]? = nil) -> TerminalApp? {
        let executable = (path as NSString).lastPathComponent
        for name in candidateNames(executable: executable, arguments: arguments ?? []) {
            if let app = app(forName: name) { return app }
        }
        return nil
    }

    /// Names to look up, most specific first: the tool an interpreter runs,
    /// then the executable itself.
    static func candidateNames(executable: String, arguments: [String]) -> [String] {
        let executable = executable.lowercased()
        var names: [String] = []
        switch stripVersion(executable) {
        case "java":
            names += jvmTool(arguments: arguments).map { [$0] } ?? []
        case let interpreter where scriptInterpreters.contains(interpreter):
            names += scriptNames(arguments: Array(arguments.dropFirst()))
        default:
            break
        }
        return names + [executable]
    }

    /// Whether the executable hosts other tools, so its arguments are worth reading.
    public static func isInterpreter(_ executable: String) -> Bool {
        let stem = stripVersion(executable.lowercased())
        return stem == "java" || scriptInterpreters.contains(stem)
    }

    private static let scriptInterpreters: Set<String> = ["node", "bun", "deno", "python", "ruby", "perl", "php"]

    private static func app(forName name: String) -> TerminalApp? {
        let lowered = name.lowercased()
        return byProcessName[lowered] ?? byProcessName[stripVersion(lowered)]
    }

    /// `python3.12` → `python`, `ruby3.3` → `ruby`.
    private static func stripVersion(_ name: String) -> String {
        let stem = name.replacing(/[0-9.]+$/, with: "")
        return stem.isEmpty ? name : stem
    }

    private static func jvmTool(arguments: [String]) -> String? {
        let markers: [(String, String)] = [
            ("org.gradle", "gradle"), ("GradleWrapperMain", "gradle"), ("GradleDaemon", "gradle"),
            ("org.codehaus.plexus.classworlds", "mvn"), ("maven-wrapper", "mvn"),
            ("org.jetbrains.kotlin", "kotlin"),
            ("sbt-launch", "sbt"), ("xsbt.boot", "sbt"),
        ]
        for argument in arguments {
            if let match = markers.first(where: { argument.contains($0.0) }) { return match.1 }
        }
        return nil
    }

    /// The script an interpreter runs: `-m module`, or the first operand,
    /// named by its npm package and by its file stem.
    private static func scriptNames(arguments: [String]) -> [String] {
        var index = arguments.startIndex
        while index < arguments.endIndex {
            let argument = arguments[index]
            if argument == "-m", index + 1 < arguments.endIndex {
                let module = arguments[index + 1]
                return [String(module.split(separator: ".").first ?? Substring(module))]
            }
            // Deno and Bun take a subcommand before the script.
            if ["run", "x", "exec"].contains(argument) { index += 1; continue }
            if argument.hasPrefix("-") { index += 1; continue }
            return names(forScript: argument)
        }
        return []
    }

    private static func names(forScript script: String) -> [String] {
        var names: [String] = []
        if let range = script.range(of: "node_modules/", options: .backwards) {
            let parts = script[range.upperBound...].split(separator: "/")
            if let first = parts.first {
                names.append(first.hasPrefix("@") && parts.count > 1 ? "\(first)/\(parts[1])" : String(first))
            }
        }
        var stem = (script as NSString).lastPathComponent
        for suffix in [".js", ".mjs", ".cjs", ".ts", ".py", ".rb", ".pl", ".php"] where stem.hasSuffix(suffix) {
            stem = String(stem.dropLast(suffix.count))
            break
        }
        if stem.hasSuffix("-cli") { names.append(String(stem.dropLast(4))) }
        names.append(stem)
        return names
    }

    private static let byProcessName: [String: TerminalApp] = {
        var map: [String: TerminalApp] = [:]
        for entry in entries {
            for name in entry.names { map[name] = entry.app }
        }
        return map
    }()
}

/// What a terminal tab shows for the program in its focused pane: a badge
/// beside the terminal icon and, for catalogued apps, the app's name with
/// the working directory as a subtitle.
public struct TerminalTabPresence: Equatable, Sendable {
    public enum Badge: Equatable, Sendable {
        case agent(AgentKind)
        case app(TerminalApp)
    }

    public let badge: Badge
    /// Replaces the tab title; nil keeps it.
    public let title: String?
    public let subtitle: String?

    public init(badge: Badge, title: String?, subtitle: String?) {
        self.badge = badge
        self.title = title
        self.subtitle = subtitle
    }

    /// - Parameters:
    ///   - harness: the agent in the foreground, which wins over `app`.
    ///     Agent tabs keep their title: it usually names the task.
    ///   - renamesTab: false when the user keeps tab titles to themselves.
    public static func resolve(
        harness: HarnessKind?,
        app: TerminalApp?,
        cwd: String?,
        renamesTab: Bool,
        homeDirectory: String = NSHomeDirectory()
    ) -> TerminalTabPresence? {
        if let harness {
            return TerminalTabPresence(badge: .agent(harness.asAgentKind), title: nil, subtitle: nil)
        }
        guard let app else { return nil }
        guard renamesTab else { return TerminalTabPresence(badge: .app(app), title: nil, subtitle: nil) }
        return TerminalTabPresence(
            badge: .app(app),
            title: app.displayName,
            subtitle: cwd.map { abbreviate($0, home: homeDirectory) }
        )
    }

    private static func abbreviate(_ path: String, home: String) -> String {
        let home = home.hasSuffix("/") ? String(home.dropLast()) : home
        guard !home.isEmpty else { return path }
        if path == home { return "~" }
        if path.hasPrefix(home + "/") { return "~" + path.dropFirst(home.count) }
        return path
    }
}
