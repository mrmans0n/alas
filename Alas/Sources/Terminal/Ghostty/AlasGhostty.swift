// AlasGhostty.swift
// Namespace + shared logger for Alas's minimal Ghostty C-API wrapper.
//
// Scope: macOS 14+, Swift 5.9+, strict concurrency (complete).
// No splits, no fullscreen, no quick-terminal, no inspector, no IME composition,
// no clipboard-confirm dialogs, no drag-and-drop.

import Foundation
import os.log

/// Top-level namespace for Alas's Ghostty wrapper.
/// All types live inside this enum so they never collide with upstream's `Ghostty` namespace.
enum AlasGhostty {
    // Shared subsystem logger used by all sub-files.
    static let logger = Logger(subsystem: "io.nlopez.alas", category: "AlasGhostty")
}
