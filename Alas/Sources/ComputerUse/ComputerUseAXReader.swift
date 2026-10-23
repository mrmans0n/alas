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
    /// Pids that accepted the ask: Chromium and Electron apps, kept for the process's life.
    private static let manualAccessibilityAccepted = Mutex<Set<pid_t>>([])

    /// Whether the app accepted `AXManualAccessibility` when it was first asked.
    static func acceptsManualAccessibility(_ pid: pid_t) -> Bool {
        manualAccessibilityAccepted.withLock { $0.contains(pid) }
    }

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
            manualAccessibilityAccepted.withLock { _ = $0.insert(pid) }
        }
        return application
    }

    /// An app that just accepted `AXManualAccessibility` builds its tree asynchronously: until it
    /// has, the window reads as nested groups. Before the first read of such an app, checks every
    /// `treeBuildPoll` until the window has an element other than a group within
    /// `treeBuildProbeDepth` levels, for at most `treeBuildWait` overall and as much AX-queue time.
    /// A pid already asked and not building costs nothing: no hop to the AX queue. The waits
    /// happen off the queue, so actions and other reads go on meanwhile.
    private static func awaitTreeBuild(_ window: ComputerUseWindow, cancel: CancelFlag) async {
        let pid = window.app.pid
        let asked = manualAccessibilityPIDs.withLock { $0.contains(pid) }
        if asked, !buildingTreePIDs.withLock({ $0.contains(pid) }) { return }
        let deadline = ContinuousClock.now + treeBuildWait
        var queueTime = Duration.zero
        while true {
            let budget = treeBuildWait - queueTime
            let (built, spent) = await withCheckedContinuation { (continuation: CheckedContinuation<(Bool, Duration), Never>) in
                queue.async {
                    let start = ContinuousClock.now
                    // The first sight of a pid asks it here.
                    let application = application(pid)
                    guard buildingTreePIDs.withLock({ $0.contains(pid) }), !cancel.isSet else {
                        return continuation.resume(returning: (true, ContinuousClock.now - start))
                    }
                    let probe = Walk(
                        budget: treeBuildProbeNodes, maxDepth: treeBuildProbeDepth,
                        deadline: min(deadline, start + budget), isCancelled: { cancel.isSet })
                    let built = probe.hasMoreThanGroups(window, application: application)
                    continuation.resume(returning: (built, ContinuousClock.now - start))
                }
            }
            queueTime += spent
            if built || cancel.isSet || ContinuousClock.now >= deadline || queueTime >= treeBuildWait { break }
            try? await Task.sleep(for: treeBuildPoll)
        }
        buildingTreePIDs.withLock { _ = $0.remove(pid) }
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

    /// The AX window behind `window`: by its CG window id where AX can name it, so two windows
    /// with the same frame and title can't be confused, else by frame with the title breaking ties.
    /// An app none of whose AX windows has an id is matched by frame too.
    /// The readers are the caller's, so a walk can stop on a stalled app.
    static func axWindow(
        _ candidates: [AXUIElement], for window: ComputerUseWindow,
        frame: (AXUIElement) -> CGRect?, title: (AXUIElement) -> String?, shouldStop: () -> Bool = { false }
    ) -> AXUIElement? {
        guard ComputerUseSkyLight.canIdentifyWindows else {
            return matchingWindow(candidates, for: window, frame: frame, title: title, shouldStop: shouldStop)
        }
        var anyIdentified = false
        for candidate in candidates {
            guard !shouldStop() else { return nil }
            AXUIElementSetMessagingTimeout(candidate, messagingTimeout)
            guard let id = ComputerUseSkyLight.windowID(of: candidate) else { continue }
            if id == window.windowID { return candidate }
            anyIdentified = true
        }
        guard !anyIdentified else { return nil }
        return matchingWindow(candidates, for: window, frame: frame, title: title, shouldStop: shouldStop)
    }

    /// The AX window whose frame matches the CG bounds; the title breaks ties.
    private static func matchingWindow(
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
            let target = ComputerUseAXReader.axWindow(
                axWindows, for: window,
                frame: { frame(of: $0) }, title: { string(of: $0, kAXTitleAttribute) }, shouldStop: { isHalted })
            if isCancelled() { throw CancellationError() }
            if appStalled || (target == nil && ContinuousClock.now >= deadline) { throw notResponding(window) }
            guard let target else { throw ComputerUseSystemError.windowNotFound(window.windowID) }

            let root = node(target, depth: 0)
            if isCancelled() { throw CancellationError() }
            return (root, !cutOff && !isHalted, ComputerUseAXHandles(elements))
        }

        /// Whether the window has a descendant other than an `AXGroup` within `maxDepth` levels and
        /// `budget` nodes. Every element is checked against the deadline and cancellation, and no
        /// AX message may wait past the deadline.
        func hasMoreThanGroups(_ window: ComputerUseWindow, application: AXUIElement) -> Bool {
            func limitWait(_ element: AXUIElement) {
                let remaining = deadline - ContinuousClock.now
                let seconds = Float(remaining.components.seconds) + Float(remaining.components.attoseconds) / 1e18
                AXUIElementSetMessagingTimeout(element, max(0.01, min(ComputerUseAXReader.messagingTimeout, seconds)))
            }
            limitWait(application)
            guard let windowsRef = attribute(application, kAXWindowsAttribute), let axWindows = windowsRef as? [AXUIElement],
                  let root = ComputerUseAXReader.axWindow(
                      axWindows, for: window, frame: { frame(of: $0) }, title: { string(of: $0, kAXTitleAttribute) },
                      shouldStop: { isHalted })
            else { return false }
            limitWait(root)
            var level = childElements(of: root)
            for _ in 0 ..< maxDepth {
                var next: [AXUIElement] = []
                for element in level {
                    count += 1
                    guard count <= budget, !isHalted else { return false }
                    limitWait(element)
                    // A halted walk reads nothing; an unreadable role proves nothing.
                    let role = string(of: element, kAXRoleAttribute)
                    if isHalted { return false }
                    if let role, role != kAXGroupRole { return true }
                    next += childElements(of: element)
                }
                guard !next.isEmpty else { return false }
                level = next
            }
            return false
        }

        private func notResponding(_ window: ComputerUseWindow) -> ComputerUseSystemError {
            .appNotResponding(window.app.name)
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
            } else if !isHalted {
                // At the depth limit: only whether there is more below, so the agent can ask for it.
                var childCount: CFIndex = 0
                let counted = AXUIElementGetAttributeValueCount(element, kAXChildrenAttribute as CFString, &childCount)
                if counted == .cannotComplete { appStalled = true }
                result.childrenUnread = counted == .success && childCount > 0
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
