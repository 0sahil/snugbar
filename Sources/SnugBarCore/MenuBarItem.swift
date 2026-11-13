import Foundation

/// A rectangle in global screen coordinates with a top-left origin (the Accessibility convention).
/// Core avoids CoreGraphics so it stays platform-neutral; the engine converts.
public struct Rect: Codable, Equatable, Hashable, Sendable {
    public var x: Double
    public var y: Double
    public var width: Double
    public var height: Double

    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }

    public static let zero = Rect(x: 0, y: 0, width: 0, height: 0)

    public var minX: Double { x }
    public var maxX: Double { x + width }
    public var minY: Double { y }
    public var maxY: Double { y + height }
    public var midX: Double { x + width / 2 }
    public var midY: Double { y + height / 2 }

    public func contains(x px: Double, y py: Double) -> Bool {
        px >= minX && px < maxX && py >= minY && py < maxY
    }

    public func insetBy(dx: Double, dy: Double) -> Rect {
        Rect(x: x + dx, y: y + dy, width: width - 2 * dx, height: height - 2 * dy)
    }
}

/// One status item in the menu bar, as seen at the time of a snapshot.
public struct MenuBarItem: Codable, Equatable, Hashable, Sendable, Identifiable {
    public var id: ItemID
    /// Bundle ID of the app that owns the item. Empty when the owner could not be determined.
    public var ownerBundleID: String
    public var ownerPID: Int32
    /// Localised name of the owning app.
    public var appName: String
    /// App name plus the item's description when there is one ("Stats: CPU").
    public var displayName: String
    public var frame: Rect
    /// Apple's own items (`com.apple.menuextra.*`): clock, Control Center, Wi-Fi and so on.
    public var isAppleItem: Bool
    /// The item sits in the system overflow behind the « button.
    public var isOverflowed: Bool
    /// The item's Accessibility identifier, when it has one (Apple items always do).
    public var axIdentifier: String?

    public init(
        id: ItemID,
        ownerBundleID: String,
        ownerPID: Int32,
        appName: String,
        displayName: String,
        frame: Rect,
        isAppleItem: Bool,
        isOverflowed: Bool,
        axIdentifier: String?
    ) {
        self.id = id
        self.ownerBundleID = ownerBundleID
        self.ownerPID = ownerPID
        self.appName = appName
        self.displayName = displayName
        self.frame = frame
        self.isAppleItem = isAppleItem
        self.isOverflowed = isOverflowed
        self.axIdentifier = axIdentifier
    }

    /// Builds the user-facing name: the app name, plus the item's description when it adds something.
    public static func makeDisplayName(appName: String, description: String?, isAppleItem: Bool, axIdentifier: String?) -> String {
        let desc = description?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if isAppleItem {
            if !desc.isEmpty { return desc }
            if let axIdentifier, let suffix = AppleItems.suffix(ofIdentifier: axIdentifier) { return suffix }
            return appName
        }
        if desc.isEmpty || desc.caseInsensitiveCompare(appName) == .orderedSame { return appName }
        if appName.isEmpty { return desc }
        return "\(appName): \(desc)"
    }
}

/// Facts about Apple's own menu bar items.
public enum AppleItems {
    public static let identifierPrefix = "com.apple.menuextra."
    public static let clockIdentifier = "com.apple.menuextra.clock"
    public static let controlCenterIdentifier = "com.apple.menuextra.controlcenter"

    public static func isAppleIdentifier(_ identifier: String?) -> Bool {
        identifier?.hasPrefix(identifierPrefix) == true
    }

    /// `com.apple.menuextra.wifi` -> `wifi`.
    public static func suffix(ofIdentifier identifier: String) -> String? {
        guard identifier.hasPrefix(identifierPrefix) else { return nil }
        let s = String(identifier.dropFirst(identifierPrefix.count))
        return s.isEmpty ? nil : s
    }
}
