import Foundation

/// Where an app's items live. macOS 27 can only hide per app, so sections are assigned per app.
public enum Section: String, Codable, CaseIterable, Sendable {
    case shown
    case hidden
    case alwaysHidden
}

/// Section assignment per app (keyed by bundle ID), with a default for apps not listed.
public struct AppSectionMap: Codable, Equatable, Sendable {
    public var apps: [String: Section]
    public var defaultSection: Section

    public init(apps: [String: Section] = [:], defaultSection: Section = .hidden) {
        self.apps = apps
        self.defaultSection = defaultSection
    }

    /// The section of an app. Apple's own items are always shown.
    public func section(forBundleID bundleID: String, isAppleItem: Bool = false) -> Section {
        if isAppleItem { return .shown }
        return apps[bundleID] ?? defaultSection
    }

    public func section(for item: MenuBarItem) -> Section {
        section(forBundleID: item.ownerBundleID, isAppleItem: item.isAppleItem)
    }

    public mutating func set(_ section: Section, forBundleID bundleID: String) {
        apps[bundleID] = section
    }

    /// Puts several apps in one section.
    public mutating func set(_ section: Section, forBundleIDs bundleIDs: some Sequence<String>) {
        for bundleID in bundleIDs { apps[bundleID] = section }
    }

    /// Bundle IDs explicitly assigned to a section.
    public func bundleIDs(in section: Section) -> Set<String> {
        Set(apps.filter { $0.value == section }.keys)
    }

    /// Bundle IDs that stay visible: `shown` apps when collapsed, plus `hidden` apps when expanded.
    /// Apps not listed follow `defaultSection`, which the caller handles by passing the bundles it sees.
    public func allowedBundleIDs(expanded: Bool, seenBundleIDs: Set<String> = []) -> Set<String> {
        var visible: Set<Section> = [.shown]
        if expanded { visible.insert(.hidden) }
        var result = Set(apps.filter { visible.contains($0.value) }.keys)
        for bundle in seenBundleIDs where apps[bundle] == nil && visible.contains(defaultSection) {
            result.insert(bundle)
        }
        return result
    }
}
