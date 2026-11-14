import Foundation

/// Why SnugBar checks the layout (feature 78).
public enum LayoutTrigger: String, Codable, CaseIterable, Sendable, Comparable {
    case launch
    case appLaunched
    case displayChanged
    case wake
    case spaceChanged
    case systemBuildChanged
    case settingsImported
    case restored
    /// Zen ended: spacers and apps are back; put anything that lost its place back.
    case zenEnded
    /// The user arranged items (editor, `order` command).
    case userOrder

    /// Re-applying the hider's allow-list is forced for these (the system may have dropped or reset the hide).
    public var forcesVisibility: Bool {
        switch self {
        case .launch, .appLaunched, .displayChanged, .wake, .systemBuildChanged, .settingsImported, .restored: return true
        case .spaceChanged, .zenEnded, .userOrder: return false
        }
    }

    public static func < (a: LayoutTrigger, b: LayoutTrigger) -> Bool {
        allCases.firstIndex(of: a)! < allCases.firstIndex(of: b)!
    }
}

/// Decides what a reconcile does with the order (SPEC: reconcile = re-apply the allow-list, then fix the order only
/// if it differs).
public enum LayoutReconcile {
    public enum Action: String, Codable, Sendable {
        /// Nothing is out of place (or there is no order to keep).
        case none
        /// Write `plan.changes` (and spacer positions) through the order file.
        case writeOrderFile
        /// Move items with the ⌘-drag fallback (explicit user actions only).
        case dragMoves
        /// Something is out of place but this reconcile may not fix it; see `reasons`.
        case skipped
    }

    public struct Input: Equatable, Sendable {
        /// The saved order (spacer keys already mapped to order-file keys where the file has them).
        public var desired: [String]
        /// Shown keys in the menu bar now, left to right (see `liveKeys`).
        public var live: [String]
        /// The order file, when SnugBar can read it.
        public var positions: [String: Double]?
        /// Items of apps seen for the first time; they go to the end of Shown.
        public var newKeys: Set<String>
        /// The user is ⌘-dragging items in the menu bar.
        public var userDragging: Bool
        /// A drag is in progress in the layout editor.
        public var editorDragging: Bool
        /// A user action asked for this (editor drop, `order`): the ⌘-drag fallback is allowed.
        public var explicit: Bool

        public init(desired: [String], live: [String], positions: [String: Double]?, newKeys: Set<String> = [],
                    userDragging: Bool = false, editorDragging: Bool = false, explicit: Bool = false) {
            self.desired = desired
            self.live = live
            self.positions = positions
            self.newKeys = newKeys
            self.userDragging = userDragging
            self.editorDragging = editorDragging
            self.explicit = explicit
        }
    }

    public struct Decision: Codable, Equatable, Sendable {
        public var action: Action
        public var reasons: [String]
        public var plan: OrderPlanner.LayoutPlan?
    }

    public static func decide(_ input: Input) -> Decision {
        if input.userDragging {
            return Decision(action: .skipped, reasons: ["the user is ⌘-dragging items in the menu bar"], plan: nil)
        }
        if input.editorDragging {
            return Decision(action: .skipped, reasons: ["a drag is in progress in the layout editor"], plan: nil)
        }
        guard !input.desired.isEmpty else {
            return Decision(action: .none, reasons: ["no saved order: the order is kept only after items are arranged"], plan: nil)
        }
        guard !input.live.isEmpty else {
            return Decision(action: .none, reasons: ["no Shown items could be read from the menu bar"], plan: nil)
        }
        let plan = OrderPlanner.planLayout(
            desired: input.desired, live: input.live, positions: input.positions, newKeys: input.newKeys
        )
        if plan.isNoOp {
            return Decision(action: .none, reasons: ["the menu bar already matches the saved order"], plan: plan)
        }
        if input.positions != nil {
            if !plan.changes.isEmpty || !plan.freePositions.isEmpty {
                var reasons: [String] = []
                if !plan.unplaced.isEmpty { reasons.append("not in the order file: \(plan.unplaced.joined(separator: ", "))") }
                return Decision(action: .writeOrderFile, reasons: reasons, plan: plan)
            }
            // Out of place, but only items the order file has no key for.
            if input.explicit { return Decision(action: .dragMoves, reasons: ["items without order-file keys are dragged"], plan: plan) }
            return Decision(action: .skipped, reasons: ["out-of-place items have no order-file key; automatic checks never drag"], plan: plan)
        }
        if input.explicit {
            return Decision(action: .dragMoves, reasons: ["no Menu Bar folder access: using ⌘-drag"], plan: plan)
        }
        return Decision(action: .skipped, reasons: ["no Menu Bar folder access; automatic checks never move the pointer"], plan: plan)
    }

    /// A decision for the saved layout, with keys made comparable first: fallback IDs in the saved order become
    /// order-file keys where the file says which, and spacers the file knows use their file key.
    public struct Evaluation: Codable, Equatable, Sendable {
        public var decision: Decision
        /// The order to save when it changed (normalized keys, unknown live items merged in), else nil.
        public var orderToSave: [String]?
        /// Spacer keys mapped to order-file keys for planning.
        public var spacerKeys: [String: String]
        /// Hidden and Always Hidden (by section raw value): their plans, when a saved order exists and the order file
        /// can be read. Planned on the values the Shown write leaves, so the two can be written together.
        public var sectionPlans: [String: SectionOrder.Plan] = [:]

        /// Every order-file value to write: Shown's (when its action is a write) and the sections'.
        public var fileChanges: [String: Double] {
            var changes = decision.action == .writeOrderFile ? decision.plan?.changes ?? [:] : [:]
            for plan in sectionPlans.values { changes.merge(plan.changes) { _, section in section } }
            return changes
        }

        /// Saved section orders that changed (keys merged in or normalized), by section raw value.
        public var sectionOrdersToSave: [String: [String]] = [:]
    }

    public static func evaluate(
        layout: DesiredLayout, live: [String], positions: [String: Double]?, ownBundleID: String,
        sectionKeys: [Section: [String]] = [:],
        userDragging: Bool = false, editorDragging: Bool = false, explicit: Bool = false
    ) -> Evaluation {
        let map = LayoutSpacer.orderKeyMap(layout.spacers, ownBundleID: ownBundleID, positions: positions)
        let inverse = Dictionary(map.map { ($1, $0) }, uniquingKeysWith: { a, _ in a })
        let normalized = DesiredOrder.normalized(layout.shownOrder, positions: positions)
        let input = Input(
            desired: DesiredOrder.mapped(normalized, map), live: DesiredOrder.mapped(live, map), positions: positions,
            userDragging: userDragging, editorDragging: editorDragging, explicit: explicit
        )
        let decision = decide(input)
        var save: [String]?
        if decision.action != .skipped, let plan = decision.plan, plan.desiredChanged {
            save = DesiredOrder.mapped(plan.desiredOrder, inverse)
        } else if layout.enforcesOrder, normalized != layout.shownOrder, decision.action != .skipped {
            save = normalized
        }
        var evaluation = Evaluation(decision: decision, orderToSave: save, spacerKeys: map)
        // Hidden sections: order file only, never while someone drags.
        guard let positions, !userDragging, !editorDragging else { return evaluation }
        var working = positions
        if decision.action == .writeOrderFile, let changes = decision.plan?.changes {
            working.merge(changes) { _, new in new }
        }
        for section in SectionOrder.sections {
            let saved = layout.order(for: section)
            guard !saved.isEmpty else { continue }
            let desired = DesiredOrder.normalized(saved, positions: positions)
            let plan = SectionOrder.plan(desired: desired, keys: sectionKeys[section] ?? [], positions: working)
            if !plan.isNoOp { evaluation.sectionPlans[section.rawValue] = plan }
            let next = plan.desiredChanged ? plan.desiredOrder : desired
            if next != saved { evaluation.sectionOrdersToSave[section.rawValue] = next }
        }
        return evaluation
    }

    /// The keys a reconcile orders: Shown items in the menu bar now, left to right. Apple's items count, except the
    /// clock and Control Center (macOS keeps them at the right end); third-party items count when their app is in
    /// Shown; SnugBar's own items count only as spacers (`spacerKey` names them), its icon doesn't.
    public static func liveKeys(
        _ items: [MenuBarItem], sections: AppSectionMap, ownBundleID: String, spacerKey: (MenuBarItem) -> String?
    ) -> [String] {
        items.compactMap { item in
            if item.ownerBundleID == ownBundleID { return spacerKey(item) }
            if item.isAppleItem { return isLocked(item) ? nil : item.id.rawValue }
            guard !item.ownerBundleID.isEmpty, sections.section(for: item) == .shown else { return nil }
            return item.id.rawValue
        }
    }

    /// The clock and Control Center can't be moved.
    public static func isLocked(_ item: MenuBarItem) -> Bool {
        item.axIdentifier == AppleItems.clockIdentifier || item.axIdentifier == AppleItems.controlCenterIdentifier
    }
}

/// Whether macOS was updated since SnugBar last looked (feature 78).
public enum SystemBuildCheck {
    public enum Result: Equatable, Sendable {
        /// First look: remember the build, nothing else.
        case firstSeen(String)
        case unchanged
        /// Updated: back up, then reconcile.
        case changed(from: String, to: String)
        /// The build can't be read.
        case unknown
    }

    public static func check(lastSeen: String?, current: String?) -> Result {
        guard let current, !current.isEmpty else { return .unknown }
        guard let lastSeen, !lastSeen.isEmpty else { return .firstSeen(current) }
        return lastSeen == current ? .unchanged : .changed(from: lastSeen, to: current)
    }
}
