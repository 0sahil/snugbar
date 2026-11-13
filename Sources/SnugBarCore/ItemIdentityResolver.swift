import Foundation

/// The facts the resolver needs about one item from an Accessibility snapshot.
public struct ObservedItem: Equatable, Sendable {
    /// Bundle ID of the owning app, or nil when unknown.
    public var ownerBundleID: String?
    /// Apple items carry `com.apple.menuextra.*`; others usually have none.
    public var axIdentifier: String?
    /// Left edge in screen points; used only to check that the input is ordered.
    public var minX: Double
    public var isOverflowed: Bool

    public init(ownerBundleID: String?, axIdentifier: String? = nil, minX: Double, isOverflowed: Bool = false) {
        self.ownerBundleID = ownerBundleID
        self.axIdentifier = axIdentifier
        self.minX = minX
        self.isOverflowed = isOverflowed
    }
}

/// Maps a left-to-right Accessibility snapshot to stable `ItemID`s.
///
/// With the order file (`TrailingItemPreferredPositions`: key -> distance from the right edge, larger is further left):
/// - Apple items match a `module:<Name>` key by their identifier suffix (`com.apple.menuextra.wifi` -> `module:WiFi`).
/// - Third-party items are matched per owning app: when the app has exactly as many `status:<bundle>::<name>` keys as
///   visible items, with distinct positions, the keys are assigned in order. Anything else is ambiguous.
/// Ambiguous or unmatched items fall back to `<owner>#<index>`.
public enum ItemIdentityResolver {
    public struct Resolution: Equatable, Sendable {
        public var id: ItemID
        /// True when `id` came from the order file.
        public var fromOrderFile: Bool
    }

    /// - Parameters:
    ///   - items: items sorted left to right (the order the reader reports).
    ///   - orderPositions: the order file dictionary, or nil when it can't be read.
    /// - Returns: one resolution per input item, in the same order.
    public static func resolve(_ items: [ObservedItem], orderPositions: [String: Double]?) -> [Resolution] {
        var result = [Resolution?](repeating: nil, count: items.count)

        // Index of each item among items sharing its owner key, left to right.
        var ownerIndices: [String: [Int]] = [:]
        for (i, item) in items.enumerated() {
            ownerIndices[fallbackOwner(item), default: []].append(i)
        }

        if let positions = orderPositions {
            let (statusKeys, moduleKeys) = partition(positions)
            var usedModules = Set<String>()

            // Apple items: match by identifier suffix.
            for (i, item) in items.enumerated() {
                guard let id = item.axIdentifier, let suffix = AppleItems.suffix(ofIdentifier: id) else { continue }
                if let key = matchModule(suffix: suffix, moduleKeys: moduleKeys), !usedModules.contains(key) {
                    usedModules.insert(key)
                    result[i] = Resolution(id: ItemID(rawValue: key), fromOrderFile: true)
                }
            }

            // Third-party items: match per bundle by order.
            var byBundle: [String: [Int]] = [:]
            for (i, item) in items.enumerated() where !AppleItems.isAppleIdentifier(item.axIdentifier) {
                guard let bundle = item.ownerBundleID, !bundle.isEmpty else { continue }
                byBundle[bundle, default: []].append(i)
            }
            for (bundle, indices) in byBundle {
                guard let keys = statusKeys[bundle], keys.count == indices.count else { continue }
                // Keys left to right: larger distance from the right edge first.
                let sortedKeys = keys.sorted { $0.position > $1.position }
                let distinct = Set(sortedKeys.map(\.position)).count == sortedKeys.count
                guard distinct, orderIsReliable(indices.map { items[$0] }) else { continue }
                for (k, i) in indices.enumerated() {
                    result[i] = Resolution(id: ItemID(rawValue: sortedKeys[k].key), fromOrderFile: true)
                }
            }
        }

        for (owner, indices) in ownerIndices {
            for (n, i) in indices.enumerated() where result[i] == nil {
                result[i] = Resolution(id: .indexed(owner: owner, index: n), fromOrderFile: false)
            }
        }
        return result.map { $0! }
    }

    /// The owner used by fallback IDs: bundle ID, else the Accessibility identifier, else "unknown".
    public static func fallbackOwner(_ item: ObservedItem) -> String {
        if AppleItems.isAppleIdentifier(item.axIdentifier), let id = item.axIdentifier { return id }
        if let b = item.ownerBundleID, !b.isEmpty { return b }
        if let id = item.axIdentifier, !id.isEmpty { return id }
        return "unknown"
    }

    /// Lowercased letters and digits only: `Wi-Fi` and `wifi` compare equal.
    public static func normalize(_ name: String) -> String {
        String(name.lowercased().unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }.map(Character.init))
    }

    // MARK: - Private

    struct KeyedPosition { let key: String; let position: Double }

    static func partition(_ positions: [String: Double]) -> (status: [String: [KeyedPosition]], modules: [String: String]) {
        var status: [String: [KeyedPosition]] = [:]
        var modules: [String: String] = [:]
        for (key, value) in positions {
            let id = ItemID(rawValue: key)
            switch id.kind {
            case let .status(bundleID, _):
                status[bundleID, default: []].append(KeyedPosition(key: key, position: value))
            case let .module(name):
                modules[normalize(name)] = key
            case .indexed, .other:
                break
            }
        }
        return (status, modules)
    }

    /// Matches `wifi` to `module:WiFi`, tolerating a trailing plural `s` on either side
    /// (`focusmode` <-> `FocusModes`).
    static func matchModule(suffix: String, moduleKeys: [String: String]) -> String? {
        let n = normalize(suffix)
        if let key = moduleKeys[n] { return key }
        if let key = moduleKeys[n + "s"] { return key }
        if n.hasSuffix("s"), let key = moduleKeys[String(n.dropLast())] { return key }
        return nil
    }

    /// Overflowed items are stacked at the « button, so two of them from one app have no visible order.
    static func orderIsReliable(_ group: [ObservedItem]) -> Bool {
        group.filter(\.isOverflowed).count <= 1
    }
}
