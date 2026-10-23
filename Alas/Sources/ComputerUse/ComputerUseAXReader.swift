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
    /// Default wall-clock budget for one read; the tree gathered so far is returned after it.
    static let deadline: Duration = .seconds(5)

    /// Walks and AX actions share it so an action never runs during a walk.
    static let queue = DispatchQueue(label: "io.nlopez.alas.computer-use.ax", qos: .userInitiated)

    /// Pids already asked to expose their tree; one ask per process is enough.
    private static let manualAccessibilityPIDs = Mutex<Set<pid_t>>([])
    /// Pids that accepted the ask and haven't been read since: their tree may still be building.
    private static let buildingTreePIDs = Mutex<Set<pid_t>>([])

    /// How long the first read after the ask waits for the tree to show more than groups.
    static let treeBuildWait: Duration = .seconds(1)
    static let treeBuildPoll: Duration = .milliseconds(100)
    /// How deep and how wide one check of a building tree looks.
    static let treeBuildProbeDepth = 6
    static let treeBuildProbeNodes = 300

    /// The app element, with the messaging timeout set. The first time a pid is seen, asks it to
    /// build its Accessibility tree (`AXManualAccessibility`): Chromium and Electron apps expose
    /// little more than nested groups until asked. Other apps refuse the attribute; that's fine.
    /// Call on `queue`.
    static func application(_ pid: pid_t) -> AXUIElement {
        let application = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(application, messagingTimeout)
        if manualAccessibilityPIDs.withLock({ $0.insert(pid).inserted }),
           AXUIElementSetAttributeValue(application, "AXManualAccessibility" as CFString, kCFBooleanTrue) == .success {
            buildingTreePIDs.withLock { _ = $0.insert(pid) }
        }
        return application
    }

    /// An app that just accepted `AXManualAccessibility` builds its tree asynchronously: until it
    /// has, the window reads as nested groups. Before the first read of such an app, checks every
    /// `treeBuildPoll` for up to `treeBuildWait` until the window has an element other than a group
    /// within `treeBuildProbeDepth` levels. Apps that refused the ask are never waited on.
    /// The waits happen off the AX queue, so actions and other reads go on meanwhile.
    private static func awaitTreeBuild(_ window: ComputerUseWindow, cancel: CancelFlag) async {
        let pid = window.app.pid
        let deadline = ContinuousClock.now + treeBuildWait
        while true {
            let built = await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
                queue.async {
                    let application = application(pid)
                    guard buildingTreePIDs.withLock({ $0.contains(pid) }), !cancel.isSet else {
                        return continuation.resume(returning: true)
                    }
                    continuation.resume(returning: hasMoreThanGroups(window, application: application))
                }
            }
            if built || cancel.isSet || ContinuousClock.now >= deadline { break }
            try? await Task.sleep(for: treeBuildPoll)
        }
        buildingTreePIDs.withLock { _ = $0.remove(pid) }
    }

    /// Whether the window has a descendant other than an `AXGroup` within the probe's bounds.
    /// Call on `queue`.
    private static func hasMoreThanGroups(_ window: ComputerUseWindow, application: AXUIElement) -> Bool {
        func copy(_ element: AXUIElement, _ attribute: String) -> CFTypeRef? {
            var value: CFTypeRef?
            return AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success ? value : nil
        }
        func frame(_ element: AXUIElement) -> CGRect? {
            guard let position = copy(element, kAXPositionAttribute), let size = copy(element, kAXSizeAttribute),
                  CFGetTypeID(position) == AXValueGetTypeID(), CFGetTypeID(size) == AXValueGetTypeID()
            else { return nil }
            var point = CGPoint.zero
            var extent = CGSize.zero
            guard AXValueGetValue(position as! AXValue, .cgPoint, &point), AXValueGetValue(size as! AXValue, .cgSize, &extent)
            else { return nil }
            return CGRect(origin: point, size: extent)
        }
        func children(_ element: AXUIElement) -> [AXUIElement] {
            let children = (copy(element, kAXChildrenAttribute) as? [AXUIElement]) ?? []
            for child in children {
                AXUIElementSetMessagingTimeout(child, messagingTimeout)
            }
            return children
        }
        guard let axWindows = copy(application, kAXWindowsAttribute) as? [AXUIElement],
              let root = matchingWindow(axWindows, for: window, frame: frame, title: { copy($0, kAXTitleAttribute) as? String })
        else { return false }
        var level = children(root)
        var visited = 0
        for _ in 1 ... treeBuildProbeDepth {
            var next: [AXUIElement] = []
            for element in level {
                visited += 1
                guard visited <= treeBuildProbeNodes else { return false }
                if (copy(element, kAXRoleAttribute) as? String) != kAXGroupRole { return true }
                next += children(element)
            }
            if next.isEmpty { return false }
            level = next
        }
        return false
    }

    final class CancelFlag: Sendable {
        private let flag = Atomic<Bool>(false)
        func set() { flag.store(true, ordering: .relaxed) }
        var isSet: Bool { flag.load(ordering: .relaxed) }
    }

    /// Throws `CancellationError` when the calling task is cancelled. `complete`
    /// is false when the walk stopped early (node budget, deadline, stalled app).
    /// `handles` retains every element in the tree, indexed by `ComputerUseAXNode.handle`.
    static func read(
        _ window: ComputerUseWindow, maxDepth: Int, nodeBudget: Int, timeLimit: Duration = deadline
    ) async throws
        -> (root: ComputerUseAXNode, complete: Bool, handles: ComputerUseAXHandles) {
        let cancel = CancelFlag()
        return try await withTaskCancellationHandler {
            await awaitTreeBuild(window, cancel: cancel)
            return try await withCheckedThrowingContinuation { continuation in
                queue.async {
                    // A call cancelled while queued behind another walk makes no AX request.
                    if cancel.isSet {
                        continuation.resume(throwing: CancellationError())
                        return
                    }
                    let walk = Walk(
                        budget: max(1, nodeBudget),
                        maxDepth: maxDepth,
                        deadline: .now + timeLimit,
                        isCancelled: { cancel.isSet }
                    )
                    continuation.resume(with: Result { try walk.tree(for: window) })
                }
            }
        } onCancel: {
            cancel.set()
        }
    }

    /// The AX window whose frame matches the CG bounds; the title breaks ties.
    /// The readers are the caller's, so a walk can stop on a stalled app.
    static func matchingWindow(
        _ candidates: [AXUIElement], for window: ComputerUseWindow,
        frame: (AXUIElement) -> CGRect?, title: (AXUIElement) -> String?, shouldStop: () -> Bool = { false }
    ) -> AXUIElement? {
        var matches: [AXUIElement] = []
        for candidate in candidates {
            guard !shouldStop() else { break }
            AXUIElementSetMessagingTimeout(candidate, messagingTimeout)
            guard let frame = frame(candidate) else { continue }
            if abs(frame.minX - window.frame.minX) <= frameTolerance,
               abs(frame.minY - window.frame.minY) <= frameTolerance,
               abs(frame.width - window.frame.width) <= frameTolerance,
               abs(frame.height - window.frame.height) <= frameTolerance {
                matches.append(candidate)
            }
        }
        if matches.count > 1, let windowTitle = window.title,
           let titled = matches.first(where: { title($0) == windowTitle }) {
            return titled
        }
        return matches.first
    }

    private final class Walk {
        let budget: Int
        let maxDepth: Int
        let deadline: ContinuousClock.Instant
        let isCancelled: () -> Bool
        var count = 0
        /// Every element turned into a node; a node's handle is its index here.
        var elements: [AXUIElement] = []
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

        func tree(for window: ComputerUseWindow) throws
            -> (root: ComputerUseAXNode, complete: Bool, handles: ComputerUseAXHandles) {
            let app = ComputerUseAXReader.application(window.app.pid)

            var windowsRef: CFTypeRef?
            let result = AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &windowsRef)
            if result == .cannotComplete { throw notResponding(window) }
            guard result == .success, let axWindows = windowsRef as? [AXUIElement] else {
                if result == .apiDisabled {
                    throw ComputerUseSystemError.captureFailed("Accessibility permission is not granted")
                }
                throw ComputerUseSystemError.captureFailed("Could not read the app's windows (AXError \(result.rawValue))")
            }
            let target = ComputerUseAXReader.matchingWindow(
                axWindows, for: window,
                frame: { frame(of: $0) }, title: { string(of: $0, kAXTitleAttribute) }, shouldStop: { isHalted })
            if isCancelled() { throw CancellationError() }
            if appStalled || (target == nil && ContinuousClock.now >= deadline) { throw notResponding(window) }
            guard let target else { throw ComputerUseSystemError.windowNotFound(window.windowID) }

            let root = node(target, depth: 0)
            if isCancelled() { throw CancellationError() }
            return (root, !cutOff && !isHalted, ComputerUseAXHandles(elements))
        }

        private func notResponding(_ window: ComputerUseWindow) -> ComputerUseSystemError {
            .captureFailed("\(window.app.name) is not responding")
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
                isFocused: bool(of: element, kAXFocusedAttribute) ?? false,
                handle: elements.count
            )
            elements.append(element)
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
