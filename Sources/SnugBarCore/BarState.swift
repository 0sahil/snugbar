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

/// The runtime state that decides what's visible. Not persisted: SnugBar starts collapsed, unswapped and out of Zen.
public struct BarState: Equatable, Sendable {
    public var reveal: RevealLevel
    /// Shown and Hidden trade places (feature 7). Always hidden is unaffected.
    public var swapped: Bool
    /// The revealed items are listed in the SnugBar Bar instead of the menu bar, so the menu bar stays collapsed.
    public var revealInBar: Bool
    /// Zen mode: every third-party app is hidden and nothing can be revealed until Zen ends.
    public var zen: Bool

    public init(reveal: RevealLevel = .collapsed, swapped: Bool = false, revealInBar: Bool = false, zen: Bool = false) {
        self.reveal = reveal
        self.swapped = swapped
        self.revealInBar = revealInBar
        self.zen = zen
    }

    public static let initial = BarState()

    public var isCollapsed: Bool { reveal == .collapsed }

    /// How much the menu bar itself reveals: nothing beyond the collapsed set while the reveal is shown in the
    /// SnugBar Bar or Zen is on.
    public var menuBarReveal: RevealLevel {
        zen || revealInBar ? .collapsed : reveal
    }

    /// The sections whose apps are visible in the menu bar in this state.
    public var visibleSections: Set<Section> {
        if zen { return [] }
        switch menuBarReveal {
        case .all: return Set(Section.allCases)
        case .expanded: return [.shown, .hidden]
        case .collapsed: return collapsedSections
        }
    }

    /// The sections visible in the menu bar when collapsed (swap-aware, ignoring Zen).
    public var collapsedSections: Set<Section> {
        swapped ? [.hidden] : [.shown]
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
    ///   - alwaysAllowed: bundle IDs that are never hidden (SnugBar itself), not even in Zen.
    ///   - overflowHidden: apps moved out of the menu bar because they don't fit beside the notch. They are left out
    ///     while the menu bar is collapsed.
    public static func plan(
        state: BarState,
        sections: AppSectionMap,
        candidates: Set<String>,
        alwaysAllowed: Set<String>,
        overflowHidden: Set<String> = []
    ) -> Plan {
        // Zen: nothing third-party but SnugBar. Apple's items stay (the hider keeps its system items).
        if state.zen { return .allow(alwaysAllowed) }

        let visible = state.visibleSections
        let dropped = state.menuBarReveal == .collapsed ? overflowHidden.subtracting(alwaysAllowed) : []
        if visible.count == Section.allCases.count && dropped.isEmpty { return .showEverything }

        // If no app at all can be in an invisible section, nothing needs hiding.
        let invisible = Set(Section.allCases).subtracting(visible)
        let explicitInvisible = sections.apps.contains { invisible.contains($0.value) }
        let defaultInvisible = invisible.contains(sections.defaultSection)
            && candidates.contains { sections.apps[$0] == nil && !alwaysAllowed.contains($0) }
        if !explicitInvisible && !defaultInvisible && dropped.isEmpty { return .showEverything }

        var allowed = alwaysAllowed
        for (bundle, section) in sections.apps where visible.contains(section) {
            allowed.insert(bundle)
        }
        if visible.contains(sections.defaultSection) {
            for bundle in candidates where sections.apps[bundle] == nil {
                allowed.insert(bundle)
            }
        }
        return .allow(allowed.subtracting(dropped))
    }

    /// Third-party apps among `candidates` that the collapsed menu bar shows (swap-aware): the apps whose widths
    /// decide whether the bar fits.
    public static func collapsedVisibleApps(
        state: BarState, sections: AppSectionMap, candidates: Set<String>, excluding: Set<String>
    ) -> Set<String> {
        let visible = state.collapsedSections
        return Set(candidates.filter { !excluding.contains($0) && visible.contains(sections.section(forBundleID: $0)) })
    }
}
