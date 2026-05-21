import Foundation

struct PiInstaller: AgentInstaller, Sendable {
    let agent = AgentKind.pi
    let extensionURL: URL

    private static let managedMarker = "alas-managed-pi-hook"

    init(
        homeDirectoryURL: URL = FileManager.default.homeDirectoryForCurrentUser,
        extensionURL: URL? = nil
    ) {
        self.extensionURL = extensionURL ?? homeDirectoryURL
            .appendingPathComponent(".pi", isDirectory: true)
            .appendingPathComponent("agent", isDirectory: true)
            .appendingPathComponent("extensions", isDirectory: true)
            .appendingPathComponent("alas-notify.ts", isDirectory: false)
    }

    func installState() -> InstallState {
        guard FileManager.default.fileExists(atPath: extensionURL.path) else { return .notInstalled }
        guard let contents = try? String(contentsOf: extensionURL, encoding: .utf8) else { return .outdated }
        return contents.contains(Self.managedMarker) ? .installed : .outdated
    }

    func install() async throws {
        if FileManager.default.fileExists(atPath: extensionURL.path) {
            let contents = (try? String(contentsOf: extensionURL, encoding: .utf8)) ?? ""
            guard contents.contains(Self.managedMarker) else {
                throw PiInstallerError.unmanagedExtensionExists(extensionURL.path)
            }
        }
        try FileManager.default.createDirectory(
            at: extensionURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Self.extensionContent.write(to: extensionURL, atomically: true, encoding: .utf8)
    }

    func uninstall() throws {
        guard FileManager.default.fileExists(atPath: extensionURL.path),
              let contents = try? String(contentsOf: extensionURL, encoding: .utf8),
              contents.contains(Self.managedMarker)
        else {
            return
        }
        try FileManager.default.removeItem(at: extensionURL)
    }

    private static let extensionContent = #"""
    // alas-managed-pi-hook
    import * as childProcess from "node:child_process";

    declare const process: any;

    const eventMap: Record<string, string> = {
      session_start: "attached",
      session_end: "detached",
      before_agent_start: "busy",
      tool_execution_end: "busy",
      agent_end: "idle",
      session_shutdown: "detached"
    };

    function envValue(name: string): string | undefined {
      try {
        if (typeof process !== "undefined" && process?.env) return process.env[name];
      } catch (_) {}
      return undefined;
    }

    function sessionIdFrom(event: any, ctx: any): string {
      return ctx?.session_id || ctx?.sessionId || ctx?.session?.id || event?.session_id || event?.sessionId || event?.session?.id || envValue("ALAS_SESSION_ID") || "pi";
    }

    function parentPid(): number {
      try {
        if (typeof process !== "undefined") return Number(process.ppid || process.pid || 0);
      } catch (_) {}
      return 0;
    }

    function envelope(eventName: string, event: any, ctx: any): string {
      return JSON.stringify({
        v: 1,
        agent: "pi",
        event: eventName,
        session_id: sessionIdFrom(event, ctx),
        pid: parentPid()
      });
    }

    function notify(eventName: string, event: any, ctx: any): void {
      try {
        if (ctx && ctx.hasUI === false) return;
        const socketPath = envValue("ALAS_SOCKET_PATH");
        if (!socketPath) return;
        const mappedEvent = eventMap[eventName];
        if (!mappedEvent) return;
        const child = childProcess.spawn("/usr/bin/nc", ["-U", "-w1", socketPath], {
          stdio: ["pipe", "ignore", "ignore"]
        });
        const body = envelope(mappedEvent, event, ctx) + "\n";
        try {
          if (child?.stdin?.end) {
            child.on?.("error", () => {});
            child.stdin.on?.("error", () => {});
            child.stdin.end(body);
            return;
          }
        } catch (_) {}
      } catch (_) {}
    }

    function register(pi: any, eventName: string): void {
      try {
        pi?.on?.(eventName, async (event: any, ctx: any) => {
          try {
            notify(eventName, event, ctx);
          } catch (_) {}
        });
      } catch (_) {}
    }

    export default function (pi) {
      try {
        pi.on("session_start", async (event: any, ctx: any) => {
          try {
            notify("session_start", event, ctx);
          } catch (_) {}
        });
        pi.on("session_end", async (event: any, ctx: any) => {
          try {
            notify("session_end", event, ctx);
          } catch (_) {}
        });
        pi.on("before_agent_start", async (event: any, ctx: any) => {
          try {
            notify("before_agent_start", event, ctx);
          } catch (_) {}
        });
        pi.on("tool_execution_end", async (event: any, ctx: any) => {
          try {
            notify("tool_execution_end", event, ctx);
          } catch (_) {}
        });
        pi.on("agent_end", async (event: any, ctx: any) => {
          try {
            notify("agent_end", event, ctx);
          } catch (_) {}
        });
        pi.on("session_shutdown", async (event: any, ctx: any) => {
          try {
            notify("session_shutdown", event, ctx);
          } catch (_) {}
        });
      } catch (_) {
        try {
          register(pi, "session_start");
          register(pi, "session_end");
          register(pi, "before_agent_start");
          register(pi, "tool_execution_end");
          register(pi, "agent_end");
          register(pi, "session_shutdown");
        } catch (_) {}
      }
    }
    """#
}

enum PiInstallerError: Error, LocalizedError {
    case unmanagedExtensionExists(String)

    var errorDescription: String? {
        switch self {
        case .unmanagedExtensionExists(let path):
            return "An unmanaged Pi extension already exists at \(path). Remove it before installing the Alas hook extension."
        }
    }
}
