import AppKit
import ApplicationServices
import SnugBarCore

/// Thin wrappers over the Accessibility C API. All callers are on the main actor.
enum AX {
    static func attribute(_ element: AXUIElement, _ name: String) -> AnyObject? {
        var value: AnyObject?
        return AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success ? value : nil
    }

    static func string(_ element: AXUIElement, _ name: String) -> String? {
        guard let s = attribute(element, name) as? String, !s.isEmpty else { return nil }
        return s
    }

    static func children(_ element: AXUIElement) -> [AXUIElement] {
        attribute(element, kAXChildrenAttribute) as? [AXUIElement] ?? []
    }

    static func role(_ element: AXUIElement) -> String? { string(element, kAXRoleAttribute) }

    static func identifier(_ element: AXUIElement) -> String? { string(element, "AXIdentifier") }

    static func actions(_ element: AXUIElement) -> [String] {
        var names: CFArray?
        guard AXUIElementCopyActionNames(element, &names) == .success else { return [] }
        return names as? [String] ?? []
    }

    static func element(_ value: AnyObject?) -> AXUIElement? {
        guard let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return (value as! AXUIElement)
    }

    /// Frame in global top-left coordinates.
    static func frame(_ element: AXUIElement) -> CGRect? {
        guard let p = attribute(element, kAXPositionAttribute), let s = attribute(element, kAXSizeAttribute),
              CFGetTypeID(p) == AXValueGetTypeID(), CFGetTypeID(s) == AXValueGetTypeID()
        else { return nil }
        var point = CGPoint.zero
        var size = CGSize.zero
        guard AXValueGetValue(p as! AXValue, .cgPoint, &point), AXValueGetValue(s as! AXValue, .cgSize, &size) else {
            return nil
        }
        return CGRect(origin: point, size: size)
    }

    static func pid(_ element: AXUIElement) -> pid_t? {
        var pid: pid_t = 0
        return AXUIElementGetPid(element, &pid) == .success && pid > 0 ? pid : nil
    }

    /// First non-empty `AXIdentifier` at or below the element, depth-first.
    static func firstIdentifier(_ element: AXUIElement, maxDepth: Int = 3) -> String? {
        if let id = identifier(element) { return id }
        guard maxDepth > 0 else { return nil }
        for child in children(element) {
            if let id = firstIdentifier(child, maxDepth: maxDepth - 1) { return id }
        }
        return nil
    }

    /// First non-empty description, title or help text at or below the element.
    static func firstDescription(_ element: AXUIElement, maxDepth: Int = 3) -> String? {
        for name in [kAXDescriptionAttribute, kAXTitleAttribute, kAXHelpAttribute] {
            if let s = string(element, name) { return s }
        }
        guard maxDepth > 0 else { return nil }
        for child in children(element) where role(child) != kAXApplicationRole {
            if let s = firstDescription(child, maxDepth: maxDepth - 1) { return s }
        }
        return nil
    }

    @discardableResult
    static func perform(_ element: AXUIElement, _ action: String) -> AXError {
        AXUIElementPerformAction(element, action as CFString)
    }
}

extension CGRect {
    var coreRect: SnugBarCore.Rect { SnugBarCore.Rect(x: minX, y: minY, width: width, height: height) }
}

extension SnugBarCore.Rect {
    public var cgRect: CGRect { CGRect(x: x, y: y, width: width, height: height) }
}
