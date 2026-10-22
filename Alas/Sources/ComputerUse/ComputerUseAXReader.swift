import AlasCore
import ApplicationServices
import CoreGraphics
import Foundation
import Synchronization

/// Reads a window's Accessibility tree. AX calls are blocking IPC into the
/// target app, so the walk runs on its own serial queue rather than a
/// cooperative-pool thread, is cancellable, and is bounded in time.
enum ComputerUseAXReader {
    /// Frame tolerance, in points, when matching an AX window to CG bounds.
    static let frameTolerance: CGFloat = 2
    /// Per-message timeout, set on every element we query (the global default is about 6 s).
    static let messagingTimeout: Float = 1.0
    /// Wall-clock budget for one read; the tree gathered so far is returned after it.
    static let deadline: Duration = .seconds(5)

    private static let queue = DispatchQueue(label: "io.nlopez.alas.computer-use.ax", qos: .userInitiated)

    private final class CancelFlag: Sendable {
        private let flag = Atomic<Bool>(false)
        func set() { flag.store(true, ordering: .relaxed) }
        var isSet: Bool { flag.load(ordering: .relaxed) }
    }

    /// Throws `CancellationError` when the calling task is cancelled. `complete`
    /// is false when the walk stopped early (node budget, deadline, stalled app).
    static func read(_ window: ComputerUseWindow, maxDepth: Int, nodeBudget: Int) async throws
        -> (root: ComputerUseAXNode, complete: Bool) {
        let cancel = CancelFlag()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                queue.async {
                    // A call cancelled while queued behind another walk makes no AX request.
                    if cancel.isSet {
                        continuation.resume(throwing: CancellationError())
                        return
                    }
                    let walk = Walk(
                        budget: max(1, nodeBudget),
                        maxDepth: maxDepth,
                        deadline: .now + deadline,
                        isCancelled: { cancel.isSet }
                    )
                    continuation.resume(with: Result { try walk.tree(for: window) })
                }
            }
        } onCancel: {
            cancel.set()
        }
    }

    private final class Walk {
        let budget: Int
        let maxDepth: Int
        let deadline: ContinuousClock.Instant
        let isCancelled: () -> Bool
        var count = 0
        /// Set on the first timeout-class AX error: the app is not answering.
        var appStalled = false
        /// Set when children were left unread because the budget ran out or the walk halted.
        var cutOff = false

        init(budget: Int, maxDepth: Int, deadline: ContinuousClock.Instant, isCancelled: @escaping () -> Bool) {
            self.budget = budget
            self.maxDepth = maxDepth
            self.deadline = deadline
            self.isCancelled = isCancelled
        }

        private var isHalted: Bool {
            appStalled || isCancelled() || ContinuousClock.now >= deadline
        }

        func tree(for window: ComputerUseWindow) throws -> (root: ComputerUseAXNode, complete: Bool) {
            let app = AXUIElementCreateApplication(window.app.pid)
            AXUIElementSetMessagingTimeout(app, ComputerUseAXReader.messagingTimeout)

            var windowsRef: CFTypeRef?
            let result = AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &windowsRef)
            if result == .cannotComplete { throw notResponding(window) }
            guard result == .success, let axWindows = windowsRef as? [AXUIElement] else {
                if result == .apiDisabled {
                    throw ComputerUseSystemError.captureFailed("Accessibility permission is not granted")
                }
                throw ComputerUseSystemError.captureFailed("Could not read the app's windows (AXError \(result.rawValue))")
            }
            let target = matchingWindow(axWindows, for: window)
            if isCancelled() { throw CancellationError() }
            if appStalled || (target == nil && ContinuousClock.now >= deadline) { throw notResponding(window) }
            guard let target else { throw ComputerUseSystemError.windowNotFound(window.windowID) }

            let root = node(target, depth: 0)
            if isCancelled() { throw CancellationError() }
            return (root, !cutOff && !isHalted)
        }

        private func notResponding(_ window: ComputerUseWindow) -> ComputerUseSystemError {
            .captureFailed("\(window.app.name) is not responding")
        }

        /// The AX window whose frame matches the CG bounds; the title breaks ties.
        private func matchingWindow(_ candidates: [AXUIElement], for window: ComputerUseWindow) -> AXUIElement? {
            var matches: [AXUIElement] = []
            for candidate in candidates {
                guard !isHalted else { break }
                AXUIElementSetMessagingTimeout(candidate, ComputerUseAXReader.messagingTimeout)
                guard let frame = frame(of: candidate) else { continue }
                let tolerance = ComputerUseAXReader.frameTolerance
                if abs(frame.minX - window.frame.minX) <= tolerance,
                   abs(frame.minY - window.frame.minY) <= tolerance,
                   abs(frame.width - window.frame.width) <= tolerance,
                   abs(frame.height - window.frame.height) <= tolerance {
                    matches.append(candidate)
                }
            }
            if matches.count > 1, let title = window.title,
               let titled = matches.first(where: { string(of: $0, kAXTitleAttribute) == title }) {
                return titled
            }
            return matches.first
        }

        /// The root is depth 0 and counts toward the budget. Once the walk
        /// halts (stalled app, cancellation, deadline) or the budget runs out,
        /// the nodes already built are kept and no more are read.
        private func node(_ element: AXUIElement, depth: Int) -> ComputerUseAXNode {
            count += 1
            AXUIElementSetMessagingTimeout(element, ComputerUseAXReader.messagingTimeout)
            let role = string(of: element, kAXRoleAttribute) ?? "AXUnknown"
            let subrole = string(of: element, kAXSubroleAttribute)
            // Never read the contents of a password field. Some apps expose it
            // as the role rather than the subrole; both use the same string.
            let isSecure = role == kAXSecureTextFieldSubrole || subrole == kAXSecureTextFieldSubrole
            var result = ComputerUseAXNode(
                role: role,
                subrole: subrole,
                title: string(of: element, kAXTitleAttribute),
                value: isSecure ? nil : valueString(of: element),
                description: string(of: element, kAXDescriptionAttribute),
                frame: frame(of: element) ?? .zero,
                isEnabled: bool(of: element, kAXEnabledAttribute) ?? true,
                isFocused: bool(of: element, kAXFocusedAttribute) ?? false
            )
            if depth < maxDepth {
                if count < budget, !isHalted {
                    for child in childElements(of: element) {
                        guard count < budget, !isHalted else {
                            cutOff = true
                            break
                        }
                        result.children.append(node(child, depth: depth + 1))
                    }
                } else {
                    // Conservative: the unread element may have had no children.
                    cutOff = true
                }
            }
            return result
        }

        /// Skips the IPC once the walk has halted, and flags a stalled app.
        private func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
            guard !isHalted else { return nil }
            var value: CFTypeRef?
            let result = AXUIElementCopyAttributeValue(element, name as CFString, &value)
            if result == .cannotComplete { appStalled = true }
            return result == .success ? value : nil
        }

        private func string(of element: AXUIElement, _ name: String) -> String? {
            guard let value = attribute(element, name), CFGetTypeID(value) == CFStringGetTypeID() else { return nil }
            let string = value as! String
            return string.isEmpty ? nil : string
        }

        private func bool(of element: AXUIElement, _ name: String) -> Bool? {
            guard let value = attribute(element, name), CFGetTypeID(value) == CFBooleanGetTypeID() else { return nil }
            return CFBooleanGetValue((value as! CFBoolean))
        }

        /// Only text and numbers: other value types (elements, ranges) carry no
        /// readable content.
        private func valueString(of element: AXUIElement) -> String? {
            guard let value = attribute(element, kAXValueAttribute) else { return nil }
            let type = CFGetTypeID(value)
            if type == CFStringGetTypeID() {
                let string = value as! String
                return string.isEmpty ? nil : string
            }
            if type == CFNumberGetTypeID() {
                return (value as! NSNumber).stringValue
            }
            return nil
        }

        private func childElements(of element: AXUIElement) -> [AXUIElement] {
            guard let value = attribute(element, kAXChildrenAttribute),
                  CFGetTypeID(value) == CFArrayGetTypeID()
            else { return [] }
            return (value as? [AXUIElement]) ?? []
        }

        private func frame(of element: AXUIElement) -> CGRect? {
            guard let position = attribute(element, kAXPositionAttribute),
                  let size = attribute(element, kAXSizeAttribute),
                  CFGetTypeID(position) == AXValueGetTypeID(),
                  CFGetTypeID(size) == AXValueGetTypeID()
            else { return nil }
            var point = CGPoint.zero
            var extent = CGSize.zero
            guard AXValueGetValue(position as! AXValue, .cgPoint, &point),
                  AXValueGetValue(size as! AXValue, .cgSize, &extent)
            else { return nil }
            return CGRect(origin: point, size: extent)
        }
    }
}
