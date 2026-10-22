import AlasCore
import ApplicationServices
import CoreGraphics
import Foundation

/// Reads a window's Accessibility tree. Blocking AX IPC: call off the main actor.
enum ComputerUseAXReader {
    /// Frame tolerance, in points, when matching an AX window to CG bounds.
    static let frameTolerance: CGFloat = 2

    static func tree(for window: ComputerUseWindow, maxDepth: Int, nodeBudget: Int) throws -> ComputerUseAXNode {
        let app = AXUIElementCreateApplication(window.app.pid)
        AXUIElementSetMessagingTimeout(app, 1.0)

        var windowsRef: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &windowsRef)
        guard result == .success, let axWindows = windowsRef as? [AXUIElement] else {
            if result == .apiDisabled {
                throw ComputerUseSystemError.captureFailed("Accessibility permission is not granted")
            }
            throw ComputerUseSystemError.captureFailed("Could not read the app's windows (AXError \(result.rawValue))")
        }
        guard let target = matchingWindow(axWindows, for: window) else {
            throw ComputerUseSystemError.windowNotFound(window.windowID)
        }
        var count = 0
        return node(target, depth: 0, maxDepth: maxDepth, budget: max(1, nodeBudget), count: &count)
    }

    /// The AX window whose frame matches the CG bounds; the title breaks ties.
    private static func matchingWindow(_ candidates: [AXUIElement], for window: ComputerUseWindow) -> AXUIElement? {
        let matches = candidates.filter { candidate in
            guard let frame = frame(of: candidate) else { return false }
            return abs(frame.minX - window.frame.minX) <= frameTolerance
                && abs(frame.minY - window.frame.minY) <= frameTolerance
                && abs(frame.width - window.frame.width) <= frameTolerance
                && abs(frame.height - window.frame.height) <= frameTolerance
        }
        if matches.count > 1, let title = window.title,
           let titled = matches.first(where: { string(of: $0, kAXTitleAttribute) == title }) {
            return titled
        }
        return matches.first
    }

    private static func node(
        _ element: AXUIElement,
        depth: Int,
        maxDepth: Int,
        budget: Int,
        count: inout Int
    ) -> ComputerUseAXNode {
        count += 1
        let subrole = string(of: element, kAXSubroleAttribute)
        var children: [ComputerUseAXNode] = []
        if depth < maxDepth, count < budget {
            for child in childElements(of: element) {
                guard count < budget else { break }
                children.append(node(child, depth: depth + 1, maxDepth: maxDepth, budget: budget, count: &count))
            }
        }
        return ComputerUseAXNode(
            role: string(of: element, kAXRoleAttribute) ?? "AXUnknown",
            subrole: subrole,
            title: string(of: element, kAXTitleAttribute),
            // Never read the contents of a password field.
            value: subrole == kAXSecureTextFieldSubrole ? nil : valueString(of: element),
            description: string(of: element, kAXDescriptionAttribute),
            frame: frame(of: element) ?? .zero,
            isEnabled: bool(of: element, kAXEnabledAttribute) ?? true,
            isFocused: bool(of: element, kAXFocusedAttribute) ?? false,
            children: children
        )
    }

    private static func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
        return value
    }

    private static func string(of element: AXUIElement, _ name: String) -> String? {
        guard let value = attribute(element, name), CFGetTypeID(value) == CFStringGetTypeID() else { return nil }
        let string = value as! String
        return string.isEmpty ? nil : string
    }

    private static func bool(of element: AXUIElement, _ name: String) -> Bool? {
        guard let value = attribute(element, name), CFGetTypeID(value) == CFBooleanGetTypeID() else { return nil }
        return CFBooleanGetValue((value as! CFBoolean))
    }

    /// Only text and numbers: other value types (elements, ranges) carry no
    /// readable content.
    private static func valueString(of element: AXUIElement) -> String? {
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

    private static func childElements(of element: AXUIElement) -> [AXUIElement] {
        guard let value = attribute(element, kAXChildrenAttribute),
              CFGetTypeID(value) == CFArrayGetTypeID()
        else { return [] }
        return (value as? [AXUIElement]) ?? []
    }

    private static func frame(of element: AXUIElement) -> CGRect? {
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
