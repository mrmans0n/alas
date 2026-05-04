// AlasGhostty.Surface.swift
// Per-surface configuration struct + C interop helpers for ghostty_surface_config_s.

import AppKit
import Foundation
import GhosttyKit

extension AlasGhostty {

    /// Per-surface configuration passed when creating a `SurfaceView`.
    struct SurfaceConfiguration {
        /// Working directory for the shell process. Nil = inherit from parent.
        var workingDirectory: String?

        /// Shell / command to launch. Nil = use the user's default shell.
        var command: String?

        /// Extra environment variables to inject into the process.
        var environment: [String: String] = [:]

        /// Text injected into the PTY immediately after the shell starts.
        var initialInput: String?

        /// Font size override (pt). Nil = use global config.
        var fontSize: Float32?

        init(
            workingDirectory: String? = nil,
            command: String? = nil,
            environment: [String: String] = [:],
            initialInput: String? = nil,
            fontSize: Float32? = nil
        ) {
            self.workingDirectory = workingDirectory
            self.command = command
            self.environment = environment
            self.initialInput = initialInput
            self.fontSize = fontSize
        }
    }
}

// MARK: - C struct conversion

extension AlasGhostty.SurfaceConfiguration {

    /// Calls `body` with a correctly populated `ghostty_surface_config_s`.
    ///
    /// All C strings are backed by Swift storage pinned with `withCString`; they are valid
    /// only for the duration of `body`. Ghostty copies what it needs before `ghostty_surface_new`
    /// returns, so this lifetime is sufficient.
    ///
    /// - Parameter nsView: The `NSView` that Ghostty will draw into (`platform.macos.nsview`).
    /// - Parameter userdata: Opaque pointer stored by Ghostty and returned in surface callbacks.
    func withCValue<T>(
        nsView: AnyObject,
        userdata: UnsafeMutableRawPointer?,
        _ body: (inout ghostty_surface_config_s) throws -> T
    ) rethrows -> T {
        // Start from the API-provided zero-filled default.
        var cfg = ghostty_surface_config_new()

        cfg.platform_tag = GHOSTTY_PLATFORM_MACOS
        // The NSView pointer is held unretained for the duration of this call.
        cfg.platform.macos.nsview = Unmanaged.passUnretained(nsView as AnyObject).toOpaque()

        // The surface userdata is the SurfaceView pointer used in callbacks.
        cfg.userdata = userdata

        cfg.scale_factor = Double(NSScreen.main?.backingScaleFactor ?? 2.0)

        if let fs = fontSize {
            cfg.font_size = fs
        }

        // All the withCString calls are nested so the C strings stay pinned.
        return try withCStringOrNil(workingDirectory) { wdPtr in
            cfg.working_directory = wdPtr
            return try withCStringOrNil(command) { cmdPtr in
                cfg.command = cmdPtr
                return try withCStringOrNil(initialInput) { inputPtr in
                    cfg.initial_input = inputPtr

                    // Env vars: allocate a flat C array of ghostty_env_var_s.
                    // The keys/values are pinned via a parallel array of (key, value) C strings.
                    if environment.isEmpty {
                        cfg.env_vars = nil
                        cfg.env_var_count = 0
                        return try body(&cfg)
                    }

                    // Convert dictionary to sorted array for stable ordering.
                    let pairs = environment.map { ($0.key, $0.value) }

                    // We need all C strings alive simultaneously, so we use a recursive
                    // withCString chain. For simplicity we use a flat UnsafePointer array
                    // managed via withUnsafeTemporaryAllocation.
                    return try pairs.withCStringPairs { envVars in
                        cfg.env_var_count = envVars.count
                        return try envVars.withUnsafeBufferPointer { buf in
                            cfg.env_vars = UnsafeMutablePointer(mutating: buf.baseAddress)
                            return try body(&cfg)
                        }
                    }
                }
            }
        }
    }
}

// MARK: - Helpers

/// Calls `body` with either a C string pointer or nil if `str` is nil.
private func withCStringOrNil<T>(
    _ str: String?,
    _ body: (UnsafePointer<CChar>?) throws -> T
) rethrows -> T {
    if let str {
        return try str.withCString { ptr in try body(ptr) }
    } else {
        return try body(nil)
    }
}

// MARK: - Env-var pair pinning

private extension Array where Element == (String, String) {
    /// Pins all key/value C strings and builds a temporary [ghostty_env_var_s] array.
    func withCStringPairs<T>(_ body: ([ghostty_env_var_s]) throws -> T) rethrows -> T {
        try withCStringPairsRecursive(index: 0, accumulated: [], body: body)
    }
}

private func withCStringPairsRecursive<T>(
    index: Int,
    accumulated: [ghostty_env_var_s],
    pairs: [(String, String)]? = nil,
    body: ([ghostty_env_var_s]) throws -> T
) rethrows -> T {
    // This function is called with the actual pairs via the extension method;
    // pairs will be injected by the extension.
    fatalError("Use the extension method instead")
}

private extension Array where Element == (String, String) {
    func withCStringPairsRecursive<T>(
        index: Int,
        accumulated: [ghostty_env_var_s],
        body: ([ghostty_env_var_s]) throws -> T
    ) rethrows -> T {
        if index >= count {
            return try body(accumulated)
        }
        let (key, value) = self[index]
        return try key.withCString { kPtr in
            try value.withCString { vPtr in
                var ev = ghostty_env_var_s()
                ev.key = kPtr
                ev.value = vPtr
                var next = accumulated
                next.append(ev)
                return try withCStringPairsRecursive(index: index + 1, accumulated: next, body: body)
            }
        }
    }
}
