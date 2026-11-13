import Foundation

/// How much of the menu bar is revealed.
public enum RevealLevel: String, Codable, CaseIterable, Sendable {
    /// Only Shown apps (Hidden and Always hidden are hidden).
    case collapsed
    /// Shown and Hidden apps.
    case expanded
    /// Every app, Always hidden included.
    case all
}

/// The runtime state that decides what's visible. Not persisted: SnugBar starts collapsed and unswapped.
public struct BarState: Equatable, Sendable {
    public var reveal: RevealLevel
    /// Shown and Hidden trade places (feature 7). Always hidden is unaffected.
    public var swapped: Bool

    public init(reveal: RevealLevel = .collapsed, swapped: Bool = false) {
        self.reveal = reveal
        self.swapped = swapped
    }

    public static let initial = BarState()

    public var isCollapsed: Bool { reveal == .collapsed }

    /// The sections whose apps are visible in this state.
    public var visibleSections: Set<Section> {
        switch reveal {
        case .all: return Set(Section.allCases)
        case .expanded: return [.shown, .hidden]
        case .collapsed: return swapped ? [.hidden] : [.shown]
        }
    }
}

/// Turns the state and section map into what the hider must do.
public enum VisibilityPlanner {
    public enum Plan: Equatable, Sendable {
        /// Nothing needs hiding: stop the hider.
        case showEverything
        /// Hide every third-party app except these bundle IDs (Apple's items stay).
        case allow(Set<String>)
    }

    /// - Parameters:
    ///   - candidates: bundle IDs that may own menu bar items right now (running apps). Apps that aren't listed in the
    ///     section map follow its default section, so they must be named to be let through.
    ///   - alwaysAllowed: bundle IDs that are never hidden (SnugBar itself).
    public static func plan(
        state: BarState,
        sections: AppSectionMap,
        candidates: Set<String>,
        alwaysAllowed: Set<String>
    ) -> Plan {
        let visible = state.visibleSections
        if visible.count == Section.allCases.count { return .showEverything }

        // If no app at all can be in an invisible section, nothing needs hiding.
        let invisible = Set(Section.allCases).subtracting(visible)
        let explicitInvisible = sections.apps.contains { invisible.contains($0.value) }
        let defaultInvisible = invisible.contains(sections.defaultSection)
            && candidates.contains { sections.apps[$0] == nil && !alwaysAllowed.contains($0) }
        if !explicitInvisible && !defaultInvisible { return .showEverything }

        var allowed = alwaysAllowed
        for (bundle, section) in sections.apps where visible.contains(section) {
            allowed.insert(bundle)
        }
        if visible.contains(sections.defaultSection) {
            for bundle in candidates where sections.apps[bundle] == nil {
                allowed.insert(bundle)
            }
        }
        return .allow(allowed)
    }
}
