@testable import SnugBarCore

/// Made-up data shaped like a real macOS 27 menu bar: a system monitor with two items, a clipboard manager and a
/// chat app with one generic item each, and Apple's Battery, Wi-Fi, Control Center and clock.
enum Fixtures {
    static let meters = "com.example.meters"
    static let clipboard = "org.example.clipboard"
    static let chat = "com.example.chat"

    /// `TrailingItemPreferredPositions`: distance from the right edge, larger is further left.
    static let positions: [String: Double] = [
        "status:com.example.chat::Item-0": 420,
        "status:org.example.clipboard::Item-0": 380,
        "status:com.example.meters::CPU_mini": 340,
        "status:com.example.meters::RAM_mini": 300,
        "module:Battery": 200,
        "module:WiFi": 160,
        "module:FocusModes": 120,
    ]

    /// Left to right, as the reader reports them.
    static let observed: [ObservedItem] = [
        ObservedItem(ownerBundleID: chat, minX: 1000),
        ObservedItem(ownerBundleID: clipboard, minX: 1030),
        ObservedItem(ownerBundleID: meters, minX: 1060),
        ObservedItem(ownerBundleID: meters, minX: 1100),
        ObservedItem(ownerBundleID: "com.apple.controlcenter", axIdentifier: "com.apple.menuextra.battery", minX: 1200),
        ObservedItem(ownerBundleID: "com.apple.controlcenter", axIdentifier: "com.apple.menuextra.wifi", minX: 1240),
        ObservedItem(ownerBundleID: "com.apple.controlcenter", axIdentifier: "com.apple.menuextra.focusmode", minX: 1280),
        ObservedItem(ownerBundleID: "com.apple.controlcenter", axIdentifier: "com.apple.menuextra.controlcenter", minX: 1320),
        ObservedItem(ownerBundleID: "com.apple.controlcenter", axIdentifier: "com.apple.menuextra.clock", minX: 1360),
    ]

    static func item(_ id: String, bundle: String, app: String, name: String? = nil, x: Double = 0, apple: Bool = false, axID: String? = nil) -> MenuBarItem {
        MenuBarItem(
            id: ItemID(rawValue: id), ownerBundleID: bundle, ownerPID: 100, appName: app, displayName: name ?? app,
            frame: Rect(x: x, y: 0, width: 30, height: 33), isAppleItem: apple, isOverflowed: false, axIdentifier: axID
        )
    }
}
