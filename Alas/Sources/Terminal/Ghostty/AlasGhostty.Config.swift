// AlasGhostty.Config.swift
// Wraps ghostty_config_t. File-based config model; no per-key Swift setters.

import Foundation
import GhosttyKit

extension AlasGhostty {

    /// Wraps a `ghostty_config_t`. Owns the config lifetime.
    ///
    /// Usage:
    ///   let cfg = try Config()                   // load default files
    ///   let cfg = try Config(filePath: "~/.config/ghostty/config")
    @MainActor
    final class Config {

        /// The raw C config pointer. Valid for this object's lifetime.
        private(set) var cValue: ghostty_config_t

        // MARK: - Init

        /// Load a Ghostty config.
        ///
        /// - Parameter filePath: Optional path to a config file. When `nil` the default
        ///   Ghostty config files are loaded (`ghostty_config_load_default_files`).
        /// - Throws: `ConfigError.diagnostics` if the config has any diagnostics after finalisation.
        init(filePath: String? = nil) throws {
            guard let raw = ghostty_config_new() else {
                throw ConfigError.allocationFailed
            }
            cValue = raw

            if let path = filePath {
                path.withCString { cStr in
                    ghostty_config_load_file(cValue, cStr)
                }
            } else {
                ghostty_config_load_default_files(cValue)
            }

            ghostty_config_finalize(cValue)

            let count = ghostty_config_diagnostics_count(cValue)
            if count > 0 {
                // Collect messages for the error.
                var messages: [String] = []
                for i in 0..<count {
                    let diag = ghostty_config_get_diagnostic(cValue, i)
                    if let msg = diag.message {
                        messages.append(String(cString: msg))
                    }
                }
                ghostty_config_free(cValue)
                throw ConfigError.diagnostics(messages)
            }
        }

        deinit {
            ghostty_config_free(cValue)
        }

        // MARK: - Helpers

        /// Returns the filesystem path where Ghostty would open its config editor, if known.
        func openPath() -> URL? {
            let gs = ghostty_config_open_path()
            defer { ghostty_string_free(gs) }
            guard gs.len > 0, let ptr = gs.ptr else { return nil }
            // ghostty_string_s uses `const char*` ptr and `uintptr_t` len.
            // We convert via Data to avoid the CChar/UInt8 mismatch.
            let data = Data(bytes: ptr, count: Int(gs.len))
            let str = String(data: data, encoding: .utf8) ?? ""
            guard !str.isEmpty else { return nil }
            return URL(fileURLWithPath: str)
        }

        // MARK: - Errors

        enum ConfigError: Error, LocalizedError {
            case allocationFailed
            case diagnostics([String])

            var errorDescription: String? {
                switch self {
                case .allocationFailed:
                    return "ghostty_config_new() returned nil"
                case .diagnostics(let msgs):
                    return "Ghostty config diagnostics:\n" + msgs.joined(separator: "\n")
                }
            }
        }
    }
}
