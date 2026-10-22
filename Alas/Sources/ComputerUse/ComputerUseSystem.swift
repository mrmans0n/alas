import AlasCore
import AppKit
import CoreGraphics
import ScreenCaptureKit

/// An on-screen, layer-0 window of a running app.
struct ComputerUseWindow: Sendable, Equatable {
    var windowID: UInt32
    var title: String?
    /// Points, global, top-left origin (CG window bounds).
    var frame: CGRect
    var app: ComputerUseAppIdentity
}

struct ComputerUseScreenshot: Sendable {
    var png: Data
    var pixelSize: CGSize
    /// Output pixels per point.
    var scale: CGFloat
}

enum ComputerUseSystemError: Error, LocalizedError {
    case windowNotFound(UInt32)
    case captureFailed(String)

    var errorDescription: String? {
        switch self {
        case .windowNotFound(let id): "Window \(id) is no longer on screen"
        case .captureFailed(let reason): "Capture failed: \(reason)"
        }
    }
}

/// The macOS calls behind the computer_apps, computer_screenshot and
/// computer_inspect tools. Closures so the coordinator can be tested with fakes.
struct ComputerUseSystem: Sendable {
    var runningApps: @Sendable () async -> [(app: ComputerUseAppIdentity, windows: [ComputerUseWindow])]
    var window: @Sendable (UInt32) async -> ComputerUseWindow?
    var screenshot: @Sendable (ComputerUseWindow) async throws -> ComputerUseScreenshot
    var axTree: @Sendable (ComputerUseWindow, _ maxDepth: Int, _ nodeBudget: Int) async throws -> ComputerUseAXNode

    static let live = ComputerUseSystem(
        runningApps: { await LiveComputerUseSystem.runningApps() },
        window: { await LiveComputerUseSystem.window($0) },
        screenshot: { try await LiveComputerUseSystem.screenshot($0) },
        axTree: { window, maxDepth, nodeBudget in
            try await Task.detached(priority: .userInitiated) {
                try ComputerUseAXReader.tree(for: window, maxDepth: maxDepth, nodeBudget: nodeBudget)
            }.value
        }
    )
}

private enum LiveComputerUseSystem {
    /// Same cap as preview_capture.
    static let maxPNGBytes = 8 * 1024 * 1024

    private struct CGWindowEntry {
        var id: UInt32
        var pid: Int32
        var ownerName: String?
        var title: String?
        var frame: CGRect
    }

    static func runningApps() async -> [(app: ComputerUseAppIdentity, windows: [ComputerUseWindow])] {
        let apps = await MainActor.run {
            NSWorkspace.shared.runningApplications
                .filter { $0.activationPolicy == .regular }
                .map(identity(of:))
        }
        var windowsByPID: [Int32: [CGWindowEntry]] = [:]
        // CG window list order is front to back; grouping keeps it.
        for entry in onScreenWindows() {
            windowsByPID[entry.pid, default: []].append(entry)
        }
        return apps
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
            .map { app in
                let windows = (windowsByPID[app.pid] ?? []).map {
                    ComputerUseWindow(windowID: $0.id, title: $0.title, frame: $0.frame, app: app)
                }
                return (app: app, windows: windows)
            }
    }

    static func window(_ id: UInt32) async -> ComputerUseWindow? {
        guard let entry = onScreenWindows().first(where: { $0.id == id }) else { return nil }
        let app = await MainActor.run {
            NSRunningApplication(processIdentifier: entry.pid).map(identity(of:))
        } ?? ComputerUseAppIdentity(name: entry.ownerName ?? "pid \(entry.pid)", bundleID: nil, pid: entry.pid)
        return ComputerUseWindow(windowID: entry.id, title: entry.title, frame: entry.frame, app: app)
    }

    static func screenshot(_ window: ComputerUseWindow) async throws -> ComputerUseScreenshot {
        let content: SCShareableContent
        do {
            content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        } catch {
            throw ComputerUseSystemError.captureFailed(error.localizedDescription)
        }
        guard let scWindow = content.windows.first(where: { $0.windowID == window.windowID }) else {
            throw ComputerUseSystemError.windowNotFound(window.windowID)
        }
        let backingScale = await MainActor.run { screenBackingScale(containing: window.frame) }
        let geometry = ComputerUseScreenshotGeometry.output(pointSize: window.frame.size, backingScale: backingScale)

        let filter = SCContentFilter(desktopIndependentWindow: scWindow)
        let configuration = SCStreamConfiguration()
        configuration.width = Int(geometry.pixelSize.width)
        configuration.height = Int(geometry.pixelSize.height)
        configuration.showsCursor = false
        configuration.scalesToFit = true
        configuration.captureResolution = .best
        // Shadows would pad the image and break the point-to-pixel mapping.
        configuration.ignoreShadowsSingleWindow = true

        let image: CGImage
        do {
            image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration)
        } catch {
            throw ComputerUseSystemError.captureFailed(error.localizedDescription)
        }
        guard let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else {
            throw ComputerUseSystemError.captureFailed("PNG encoding failed")
        }
        guard png.count <= maxPNGBytes else {
            throw ComputerUseSystemError.captureFailed("PNG exceeds 8 MiB")
        }
        // Derived from the delivered image so the pixel-to-point mapping holds
        // even if ScreenCaptureKit does not honor the requested size exactly.
        let scale = window.frame.width > 0 ? CGFloat(image.width) / window.frame.width : geometry.scale
        return ComputerUseScreenshot(
            png: png,
            pixelSize: CGSize(width: image.width, height: image.height),
            scale: scale
        )
    }

    @MainActor
    private static func identity(of app: NSRunningApplication) -> ComputerUseAppIdentity {
        let pid = app.processIdentifier
        return ComputerUseAppIdentity(
            name: app.localizedName ?? app.bundleIdentifier ?? "pid \(pid)",
            bundleID: app.bundleIdentifier,
            pid: pid
        )
    }

    /// The scale of the screen holding the window's center. CG bounds are
    /// top-left origin; NSScreen frames are bottom-left, anchored at the
    /// primary screen.
    @MainActor
    private static func screenBackingScale(containing frame: CGRect) -> CGFloat {
        let fallback = NSScreen.main?.backingScaleFactor ?? 2
        let screens = NSScreen.screens
        guard let primary = screens.first else { return fallback }
        let center = CGPoint(x: frame.midX, y: primary.frame.height - frame.midY)
        return screens.first(where: { $0.frame.contains(center) })?.backingScaleFactor ?? fallback
    }

    private static func onScreenWindows() -> [CGWindowEntry] {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
            as? [[String: Any]]
        else { return [] }
        return list.compactMap { info in
            guard (info[kCGWindowLayer as String] as? Int) == 0,
                  let number = info[kCGWindowNumber as String] as? NSNumber,
                  let pid = info[kCGWindowOwnerPID as String] as? NSNumber,
                  let boundsDict = info[kCGWindowBounds as String] as? NSDictionary,
                  let frame = CGRect(dictionaryRepresentation: boundsDict as CFDictionary)
            else { return nil }
            let title = (info[kCGWindowName as String] as? String).flatMap { $0.isEmpty ? nil : $0 }
            return CGWindowEntry(
                id: number.uint32Value,
                pid: pid.int32Value,
                ownerName: info[kCGWindowOwnerName as String] as? String,
                title: title,
                frame: frame
            )
        }
    }
}
