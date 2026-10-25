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

    /// Whether an AX message may go to `pid`: never to this process. Its AppKit accessibility
    /// handlers would run on the calling thread, the AX queue, and assert off the main thread.
    /// (`AXUIElementGetPid` itself is answered locally.)
    static func mayMessage(_ pid: pid_t) -> Bool {
        pid > 0 && pid != getpid()
    }

    /// The frames of the active displays, CG global, top-left.
    static func displayFrames() -> [CGRect] {
        var ids = [CGDirectDisplayID](repeating: 0, count: 16)
        var count: UInt32 = 0
        guard CGGetActiveDisplayList(UInt32(ids.count), &ids, &count) == .success else { return [] }
        return ids.prefix(Int(count)).map(CGDisplayBounds)
    }

    static let hostRefusal = ComputerUseSystemError.actionFailed("Agents can't use Alas itself.")

    /// `application(_:)`, refused for this process.
    static func target(_ pid: pid_t) throws -> AXUIElement {
        guard mayMessage(pid) else { throw hostRefusal }
        return application(pid)
    }

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
        guard mayMessage(pid) else { return }
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

    /// Asks a Chromium or Electron app to build its web content's tree: `attribute` is set to true
    /// unless it already reads as true. Returns whether Alas turned it on
    /// (`ComputerUseWebContent.restores`), so it can be turned off again.
    static func wakeWebContent(_ app: ComputerUseAppIdentity, attribute: String) async -> Bool {
        await withCheckedContinuation { continuation in
            queue.async {
                guard let element = try? target(app.pid) else { return continuation.resume(returning: false) }
                var value: CFTypeRef?
                var before: Bool?
                if AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success,
                   let value, CFGetTypeID(value) == CFBooleanGetTypeID() {
                    before = CFBooleanGetValue((value as! CFBoolean))
                }
                let set = before == true
                    || AXUIElementSetAttributeValue(element, attribute as CFString, kCFBooleanTrue) == .success
                continuation.resume(returning: ComputerUseWebContent.restores(before: before, setSucceeded: set))
            }
        }
    }

    /// Turns off an attribute `wakeWebContent` turned on.
    static func restoreWebContent(_ app: ComputerUseAppIdentity, attribute: String) async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            queue.async {
                guard mayMessage(app.pid) else { return continuation.resume() }
                let element = AXUIElementCreateApplication(app.pid)
                AXUIElementSetMessagingTimeout(element, messagingTimeout)
                _ = AXUIElementSetAttributeValue(element, attribute as CFString, kCFBooleanFalse)
                continuation.resume()
            }
        }
    }

    final class CancelFlag: Sendable {
        private let flag = Atomic<Bool>(false)
        func set() { flag.store(true, ordering: .relaxed) }
        var isSet: Bool { flag.load(ordering: .relaxed) }
    }

    /// Throws `CancellationError` when the calling task is cancelled. `cut` says why the walk
    /// stopped early (node budget, deadline, an app that didn't answer); nil when it read it all.
    /// `handles` retains every element in the tree, indexed by `ComputerUseAXNode.handle`.
    static func read(
        _ window: ComputerUseWindow, maxDepth: Int, nodeBudget: Int, timeLimit: Duration = deadline
    ) async throws
        -> (root: ComputerUseAXNode, cut: ComputerUseReadCut?, handles: ComputerUseAXHandles) {
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
        /// Set once `ComputerUseReadCut.unansweredLimit` AX messages in a row went unanswered
        /// (kAXErrorCannotComplete): the app is not answering.
        var appStalled = false
        var unansweredInARow = 0
        /// An element the app didn't answer was left without its attributes and children.
        var skippedUnanswered = false
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
            -> (root: ComputerUseAXNode, cut: ComputerUseReadCut?, handles: ComputerUseAXHandles) {
            let app = try ComputerUseAXReader.target(window.app.pid)

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
            // On screen, but no AX window answers for it: a sheet's backing window, say.
            guard let target else { throw ComputerUseSystemError.windowUnreadable(window.windowID) }

            let root = node(target, depth: 0)
            if isCancelled() { throw CancellationError() }
            let cut = ComputerUseReadCut.reason(
                appNotResponding: appStalled || skippedUnanswered, timedOut: ContinuousClock.now >= deadline,
                budgetSpent: cutOff)
            return (root, cut, ComputerUseAXHandles(elements))
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
        /// the nodes already built are kept and no more are read. An element the app doesn't
        /// answer reads as `AXUnknown` without children, and the walk goes on past it.
        private func node(_ element: AXUIElement, depth: Int) -> ComputerUseAXNode {
            count += 1
            AXUIElementSetMessagingTimeout(element, ComputerUseAXReader.messagingTimeout)
            let values = attributes(of: element)
            let role = Self.string(values?[kAXRoleAttribute]) ?? "AXUnknown"
            let subrole = Self.string(values?[kAXSubroleAttribute])
            // Never read the contents of a password field. Some apps expose it
            // as the role rather than the subrole; both use the same string.
            let isSecure = role == kAXSecureTextFieldSubrole || subrole == kAXSecureTextFieldSubrole
            let children = (values?[kAXChildrenAttribute] as? [AXUIElement]) ?? []
            var result = ComputerUseAXNode(
                role: role,
                subrole: subrole,
                title: Self.string(values?[kAXTitleAttribute]),
                value: isSecure || values == nil ? nil : valueString(of: element),
                description: Self.string(values?[kAXDescriptionAttribute]),
                frame: Self.frame(position: values?[kAXPositionAttribute], size: values?[kAXSizeAttribute]) ?? .zero,
                isEnabled: Self.bool(values?[kAXEnabledAttribute]) ?? true,
                isFocused: Self.bool(values?[kAXFocusedAttribute]) ?? false,
                handle: elements.count
            )
            elements.append(element)
            if depth < maxDepth {
                if count < budget, !isHalted {
                    for child in children {
                        guard count < budget, !isHalted else {
                            cutOff = true
                            break
                        }
                        result.children.append(node(child, depth: depth + 1))
                    }
                } else if values == nil || !children.isEmpty {
                    // An element left unread may have had children.
                    cutOff = true
                }
            } else {
                // At the depth limit: only whether there is more below, so the agent can ask for it.
                result.childrenUnread = !children.isEmpty
            }
            return result
        }

        /// What `node` reads of every element, in one message.
        private static let nodeAttributes = [
            kAXRoleAttribute, kAXSubroleAttribute, kAXTitleAttribute, kAXDescriptionAttribute, kAXPositionAttribute,
            kAXSizeAttribute, kAXEnabledAttribute, kAXFocusedAttribute, kAXChildrenAttribute,
        ]

        /// `nodeAttributes` by name, read in one message: a walk sends one per element rather than
        /// one per attribute, several times faster. Attributes the element lacks are absent. Read
        /// one at a time where the app doesn't take the batch. Nil when the walk has halted, the
        /// element is gone, or the app didn't answer, which counts toward a stalled app.
        private func attributes(of element: AXUIElement) -> [String: AnyObject]? {
            guard !isHalted else { return nil }
            var list: CFArray?
            let result = AXUIElementCopyMultipleAttributeValues(
                element, Self.nodeAttributes as CFArray, AXCopyMultipleAttributeOptions(rawValue: 0), &list)
            noteAnswer(result)
            switch result {
            case .success:
                guard let values = list as? [AnyObject], values.count == Self.nodeAttributes.count else { return nil }
                var byName: [String: AnyObject] = [:]
                for (name, value) in zip(Self.nodeAttributes, values) where !Self.isError(value) { byName[name] = value }
                return byName
            case .cannotComplete:
                skippedUnanswered = true
                return nil
            case .invalidUIElement:
                return nil
            default:
                var byName: [String: AnyObject] = [:]
                for name in Self.nodeAttributes {
                    if let value = attribute(element, name) { byName[name] = value }
                }
                return isHalted ? nil : byName
            }
        }

        /// Counts the messages in a row the app didn't answer; the limit's worth halts the walk.
        private func noteAnswer(_ result: AXError) {
            guard result == .cannotComplete else {
                unansweredInARow = 0
                return
            }
            unansweredInARow += 1
            if unansweredInARow >= ComputerUseReadCut.unansweredLimit { appStalled = true }
        }

        /// A batch read's entry for an attribute that failed.
        private static func isError(_ value: AnyObject) -> Bool {
            CFGetTypeID(value) == AXValueGetTypeID() && AXValueGetType(value as! AXValue) == .axError
        }

        private static func string(_ value: AnyObject?) -> String? {
            guard let value, CFGetTypeID(value) == CFStringGetTypeID() else { return nil }
            let string = value as! String
            return string.isEmpty ? nil : string
        }

        private static func bool(_ value: AnyObject?) -> Bool? {
            guard let value, CFGetTypeID(value) == CFBooleanGetTypeID() else { return nil }
            return CFBooleanGetValue((value as! CFBoolean))
        }

        private static func frame(position: AnyObject?, size: AnyObject?) -> CGRect? {
            guard let position, let size, CFGetTypeID(position) == AXValueGetTypeID(), CFGetTypeID(size) == AXValueGetTypeID()
            else { return nil }
            var point = CGPoint.zero
            var extent = CGSize.zero
            guard AXValueGetValue(position as! AXValue, .cgPoint, &point), AXValueGetValue(size as! AXValue, .cgSize, &extent)
            else { return nil }
            return CGRect(origin: point, size: extent)
        }

        /// Skips the IPC once the walk has halted, and counts an unanswered message.
        private func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
            guard !isHalted else { return nil }
            var value: CFTypeRef?
            let result = AXUIElementCopyAttributeValue(element, name as CFString, &value)
            noteAnswer(result)
            return result == .success ? value : nil
        }

        private func string(of element: AXUIElement, _ name: String) -> String? {
            guard let value = attribute(element, name), CFGetTypeID(value) == CFStringGetTypeID() else { return nil }
            let string = value as! String
            return string.isEmpty ? nil : string
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

// MARK: - Sheets

extension ComputerUseAXReader {
    /// How long one listing may spend reading its apps' sheets.
    static let sheetFramesBudget: Duration = .milliseconds(400)

    /// The frames of the AXSheets in each app's AX windows, for the apps among `pids`, within
    /// `sheetFramesBudget` overall; apps past it, or never Alas, are left out.
    static func sheetFrames(pids: [pid_t]) async -> [pid_t: [CGRect]] {
        await withCheckedContinuation { continuation in
            queue.async {
                let deadline = ContinuousClock.now + sheetFramesBudget
                var frames: [pid_t: [CGRect]] = [:]
                func list(_ element: AXUIElement, _ attribute: String) -> [AXUIElement] {
                    var value: CFTypeRef?
                    guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success,
                          let elements = value as? [AXUIElement] else { return [] }
                    for element in elements { AXUIElementSetMessagingTimeout(element, promptProbeMessagingTimeout) }
                    return elements
                }
                func frame(_ element: AXUIElement) -> CGRect? {
                    var position: CFTypeRef?
                    var size: CFTypeRef?
                    guard AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &position) == .success,
                          AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &size) == .success,
                          let position, let size, CFGetTypeID(position) == AXValueGetTypeID(), CFGetTypeID(size) == AXValueGetTypeID()
                    else { return nil }
                    var point = CGPoint.zero
                    var extent = CGSize.zero
                    guard AXValueGetValue(position as! AXValue, .cgPoint, &point), AXValueGetValue(size as! AXValue, .cgSize, &extent)
                    else { return nil }
                    return CGRect(origin: point, size: extent)
                }
                apps: for pid in pids where mayMessage(pid) {
                    let application = AXUIElementCreateApplication(pid)
                    AXUIElementSetMessagingTimeout(application, promptProbeMessagingTimeout)
                    for window in list(application, kAXWindowsAttribute) {
                        for child in list(window, kAXChildrenAttribute) {
                            guard ContinuousClock.now < deadline else { break apps }
                            var role: CFTypeRef?
                            guard AXUIElementCopyAttributeValue(child, kAXRoleAttribute as CFString, &role) == .success,
                                  role as? String == kAXSheetRole, let sheet = frame(child)
                            else { continue }
                            frames[pid, default: []].append(sheet)
                        }
                    }
                }
                continuation.resume(returning: frames)
            }
        }
    }
}

// MARK: - Credential prompts

extension ComputerUseAXReader {
    /// How deep, how wide and how long the read of an app's sheets for a secure field looks.
    static let promptProbeDepth = 8
    static let promptProbeNodes = 400
    static let promptProbeTime: Duration = .milliseconds(400)
    /// Shorter than `messagingTimeout`: an app that doesn't answer reads as unknown, quickly.
    static let promptProbeMessagingTimeout: Float = 0.25

    /// Whether a sheet of one of the app's windows, or an untitled window, holds a secure text
    /// field, as LocalAuthentication's password prompt does. Nil when the app's windows couldn't
    /// be read, or the read ran out of `promptProbeNodes` or passed `deadline` (at most
    /// `promptProbeTime` from its start) before it found one; the first pass over the windows
    /// counts against both. Doesn't ask the app to build its tree (`application(_:)`), so a probe
    /// changes nothing in it.
    static func secureFieldInSheet(pid: pid_t, deadline: ContinuousClock.Instant? = nil) async -> Bool? {
        await withCheckedContinuation { continuation in
            queue.async {
                let ownDeadline = ContinuousClock.now + promptProbeTime
                let deadline = deadline.map { min($0, ownDeadline) } ?? ownDeadline
                var budget = promptProbeNodes
                /// Counts one AX element against the budget; false once the read must stop.
                func spend() -> Bool {
                    guard budget > 0, ContinuousClock.now < deadline else { return false }
                    budget -= 1
                    return true
                }
                // This process draws no system prompt, and must not be messaged here.
                guard mayMessage(pid) else { return continuation.resume(returning: false) }
                let application = AXUIElementCreateApplication(pid)
                AXUIElementSetMessagingTimeout(application, promptProbeMessagingTimeout)
                func elements(_ element: AXUIElement, _ attribute: String) -> [AXUIElement]? {
                    var value: CFTypeRef?
                    let result = AXUIElementCopyAttributeValue(element, attribute as CFString, &value)
                    if result == .noValue || result == .attributeUnsupported { return [] }
                    guard result == .success, let list = value as? [AXUIElement] else { return nil }
                    for item in list { AXUIElementSetMessagingTimeout(item, promptProbeMessagingTimeout) }
                    return list
                }
                func string(_ element: AXUIElement, _ attribute: String) -> String? {
                    var value: CFTypeRef?
                    guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return nil }
                    return value as? String
                }
                guard spend(), let windows = elements(application, kAXWindowsAttribute) else {
                    return continuation.resume(returning: nil)
                }
                var pending: [(element: AXUIElement, depth: Int)] = []
                for window in windows {
                    guard spend() else { return continuation.resume(returning: nil) }
                    if (string(window, kAXTitleAttribute) ?? "").isEmpty { pending.append((window, 0)) }
                    for child in elements(window, kAXChildrenAttribute) ?? [] {
                        guard spend() else { return continuation.resume(returning: nil) }
                        if string(child, kAXRoleAttribute) == kAXSheetRole { pending.append((child, 0)) }
                    }
                }
                while let (element, depth) = pending.popLast() {
                    guard spend() else { return continuation.resume(returning: nil) }
                    let identity = ComputerUseSecureFocus.Element(
                        role: string(element, kAXRoleAttribute), subrole: string(element, kAXSubroleAttribute))
                    if ComputerUseSecureFocus.isSecure(identity) { return continuation.resume(returning: true) }
                    guard depth < promptProbeDepth else { continue }
                    pending += (elements(element, kAXChildrenAttribute) ?? []).map { ($0, depth + 1) }
                }
                continuation.resume(returning: false)
            }
        }
    }
}
