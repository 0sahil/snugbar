import Foundation

/// Stable identity of one menu bar item.
///
/// Three forms exist:
/// - `status:<bundle id>::<autosave name>`: a third-party item, taken from the system order file.
/// - `module:<Name>`: an Apple item, taken from the system order file.
/// - `<owner>#<index>`: fallback when the order file is unavailable or the mapping is ambiguous.
///   `index` is the item's position among the owner's items, left to right.
///
/// The raw string is the identity; it is what gets stored and what the order file uses as a key.
public struct ItemID: Hashable, Codable, Sendable, CustomStringConvertible, Comparable {
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    public static func status(bundleID: String, autosaveName: String) -> ItemID {
        ItemID(rawValue: "status:\(bundleID)::\(autosaveName)")
    }

    public static func module(_ name: String) -> ItemID {
        ItemID(rawValue: "module:\(name)")
    }

    public static func indexed(owner: String, index: Int) -> ItemID {
        ItemID(rawValue: "\(owner)#\(index)")
    }

    public enum Kind: Equatable, Sendable {
        case status(bundleID: String, autosaveName: String)
        case module(name: String)
        case indexed(owner: String, index: Int)
        case other
    }

    public var kind: Kind {
        if rawValue.hasPrefix("status:") {
            let rest = rawValue.dropFirst("status:".count)
            if let sep = rest.range(of: "::") {
                return .status(bundleID: String(rest[..<sep.lowerBound]), autosaveName: String(rest[sep.upperBound...]))
            }
            return .other
        }
        if rawValue.hasPrefix("module:") {
            return .module(name: String(rawValue.dropFirst("module:".count)))
        }
        if let hash = rawValue.lastIndex(of: "#"), let index = Int(rawValue[rawValue.index(after: hash)...]) {
            let owner = String(rawValue[..<hash])
            if !owner.isEmpty { return .indexed(owner: owner, index: index) }
        }
        return .other
    }

    /// True when the ID is a key of the system order file (and can therefore be moved by writing it).
    public var isOrderFileKey: Bool {
        switch kind {
        case .status, .module: return true
        case .indexed, .other: return false
        }
    }

    /// The bundle ID encoded in the ID, when there is one.
    public var bundleID: String? {
        switch kind {
        case let .status(bundleID, _): return bundleID
        case let .indexed(owner, _): return owner
        case .module, .other: return nil
        }
    }

    public var description: String { rawValue }

    public static func < (lhs: ItemID, rhs: ItemID) -> Bool { lhs.rawValue < rhs.rawValue }

    public init(from decoder: Decoder) throws {
        rawValue = try decoder.singleValueContainer().decode(String.self)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}
