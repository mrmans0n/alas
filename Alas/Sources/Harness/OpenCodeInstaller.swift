import Foundation

struct OpenCodeInstaller: AgentInstaller, Sendable {
    let agent = AgentKind.opencode
    let pluginURL: URL

    private static let managedMarker = "alas-managed-opencode-hook"

    init(
        homeDirectoryURL: URL = FileManager.default.homeDirectoryForCurrentUser,
        pluginURL: URL? = nil
    ) {
        self.pluginURL = pluginURL ?? homeDirectoryURL
            .appendingPathComponent(".config", isDirectory: true)
            .appendingPathComponent("opencode", isDirectory: true)
            .appendingPathComponent("plugins", isDirectory: true)
            .appendingPathComponent("alas-notify.js", isDirectory: false)
    }

    func installState() -> InstallState {
        guard FileManager.default.fileExists(atPath: pluginURL.path) else { return .notInstalled }
        guard let contents = try? String(contentsOf: pluginURL, encoding: .utf8) else { return .outdated }
        return contents.contains(Self.managedMarker) ? .installed : .outdated
    }

    func install() async throws {
        if FileManager.default.fileExists(atPath: pluginURL.path) {
            let contents = (try? String(contentsOf: pluginURL, encoding: .utf8)) ?? ""
            guard contents.contains(Self.managedMarker) else {
                throw OpenCodeInstallerError.unmanagedPluginExists(pluginURL.path)
            }
        }
        try FileManager.default.createDirectory(
            at: pluginURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Self.pluginContent.write(to: pluginURL, atomically: true, encoding: .utf8)
    }

    func uninstall() throws {
        guard FileManager.default.fileExists(atPath: pluginURL.path),
              let contents = try? String(contentsOf: pluginURL, encoding: .utf8),
              contents.contains(Self.managedMarker)
        else {
            return
        }
        try FileManager.default.removeItem(at: pluginURL)
    }

    private static let pluginContent = #"""
    // alas-managed-opencode-hook
    import * as childProcess from "node:child_process";

    function envelope(event, sessionId) {
      return JSON.stringify({
        v: 1,
        event,
        agent: "opencode",
        session_id: sessionId || process.env.ALAS_SESSION_ID || "opencode",
        pid: Number(process.ppid || 0)
      });
    }

    function sessionIdFrom(event) {
      return event?.properties?.info?.id || event?.properties?.sessionID || event?.sessionID || event?.id || process?.env?.ALAS_SESSION_ID;
    }

    function isChildSession(event) {
      return Boolean(event?.properties?.info?.parentID || event?.properties?.parentID || event?.parentID);
    }

    function statusTypeFrom(event) {
      return event?.properties?.status?.type || event?.properties?.info?.status?.type || event?.status?.type || event?.status;
    }

    function permissionPayloadFrom(event) {
      return event?.properties?.permission || event?.properties?.input || event?.properties?.output || event?.properties || event;
    }

    function notify(event, sessionId) {
      try {
        if (typeof process === "undefined" || !process.env || !process.env.ALAS_SOCKET_PATH) return;
        const nc = childProcess.spawn("/usr/bin/nc", ["-U", "-w1", process.env.ALAS_SOCKET_PATH], {
          stdio: ["pipe", "ignore", "ignore"]
        });
        nc.on("error", () => {});
        nc.stdin.on("error", () => {});
        nc.stdin.end(envelope(event, sessionId) + "\n");
      } catch (_) {}
    }

    function permissionPayloadStatus(payload) {
      if (!payload) return undefined;
      return payload.status || payload.type || payload.state || payload.action || payload.permission?.status || payload.input?.status || payload.output?.status;
    }

    function permissionSessionId(event, payload) {
      return payload?.sessionID || payload?.session_id || payload?.properties?.sessionID || payload?.properties?.info?.id || sessionIdFrom(event);
    }

    function shouldNotifyPermissionRequest(payload) {
      const status = permissionPayloadStatus(payload);
      if (!status) return true;
      if (status === "ask" || status === "asked") return true;
      return status !== "approved" && status !== "deny" && status !== "denied" && status !== "rejected" && status !== "cancelled" && status !== "canceled" && status !== "responded" && status !== "replied";
    }

    export const AlasNotifyPlugin = async () => {
      return {
        event: async ({ event }) => {
          try {
            const type = event?.type;
            if (type === "session.created" && !isChildSession(event)) {
              notify("attached", sessionIdFrom(event));
              return;
            }
            if (type === "session.deleted" && !isChildSession(event)) {
              notify("detached", sessionIdFrom(event));
              return;
            }
            if (type === "session.status" && !isChildSession(event)) {
              const status = statusTypeFrom(event);
              if (status === "busy") notify("busy", sessionIdFrom(event));
              if (status === "idle") notify("idle", sessionIdFrom(event));
              return;
            }
            if (type === "session.idle" && !isChildSession(event)) {
              notify("idle", sessionIdFrom(event));
              return;
            }
            if (type === "session.error" && !isChildSession(event)) {
              notify("idle", sessionIdFrom(event));
              return;
            }
            if (type === "permission.asked") {
              const payload = permissionPayloadFrom(event);
              if (shouldNotifyPermissionRequest(payload)) {
                notify("permission_request", permissionSessionId(event, payload));
              }
            }
          } catch (_) {}
        }
      };
    };
    """#
}

enum OpenCodeInstallerError: Error, LocalizedError {
    case unmanagedPluginExists(String)

    var errorDescription: String? {
        switch self {
        case .unmanagedPluginExists(let path):
            return "An unmanaged OpenCode plugin already exists at \(path). Remove it before installing the Alas hook plugin."
        }
    }
}
