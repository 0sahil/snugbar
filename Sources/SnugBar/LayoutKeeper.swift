import AppKit
import SnugBarCore
import SnugBarEngine

/// Keeps the menu bar the way the user arranged it (features 33, 78–80).
///
/// A reconcile re-applies the hider's allow-list (done by the app's own observers for launch, wake and display
/// changes; here for imports, restores and macOS updates), then fixes the order only when the planner finds something
/// out of place. Triggers are coalesced: one reconcile at a time, half a second after the last trigger.
///
/// Automatic reconciles only write the order file. They never use the ⌘-drag fallback: without Menu Bar folder
/// access the order part is skipped and logged. The fallback is only for explicit user actions (an editor drop).
/// Nothing is written while the user ⌘-drags items in the menu bar or drags in the editor. After a ⌘-drag the keeper
/// waits for the bar to settle, then a drag that changed the order (of Shown, or of Hidden while it was expanded)
/// becomes the saved order; reconciles wait until then, so they never undo the user's drag.
@MainActor
final class LayoutKeeper {
    nonisolated static let debounce: TimeInterval = 0.5
    /// How long to wait for a launched app's item to show up.
    static let launchWait: TimeInterval = 5

    private unowned let controller: AppController
    private var pending: Set<LayoutTrigger> = []
    private var work: DispatchWorkItem?
    private var running = false
    private var launchWaits: [String: Task<Void, Never>] = [:]
    private var orderAtDragStart: [String]?
    private var sectionOrdersAtDragStart: [SnugBarCore.Section: [String]] = [:]
    private var settleTask: Task<Void, Never>?
    private var stopped = false

    /// A drag is in progress in the layout editor.
    var editorDragging = false {
        didSet { if !editorDragging, !pending.isEmpty { schedule(after: Self.debounce) } }
    }

    /// The last automatic or explicit evaluation, for diagnostics.
    private(set) var lastEvaluation: LayoutReconcile.Evaluation?
    private(set) var lastTriggers: [LayoutTrigger] = []

    init(controller: AppController) {
        self.controller = controller
    }

    func start() {
        stopped = false
        switch SystemBuildCheck.check(lastSeen: controller.settings.lastSystemBuild, current: SystemInfo.build) {
        case let .firstSeen(build):
            if !controller.loadFailed { controller.update { $0.lastSystemBuild = build } }
        case .changed:
            trigger(.systemBuildChanged, after: 3)
        case .unchanged, .unknown:
            break
        }
        // Give the menu bar a moment to settle after SnugBar starts hiding.
        trigger(.launch, after: 3)
    }

    func stop() {
        stopped = true
        settleTask?.cancel()
        settleTask = nil
        work?.cancel()
        work = nil
        launchWaits.values.forEach { $0.cancel() }
        launchWaits = [:]
    }

    func trigger(_ trigger: LayoutTrigger, after delay: TimeInterval = LayoutKeeper.debounce) {
        guard !stopped else { return }
        pending.insert(trigger)
        schedule(after: delay)
    }

    /// An app launched: wait (up to 5 s) for its item, note it if it's new, then reconcile.
    func appLaunched(_ bundleID: String) {
        guard !stopped, bundleID != controller.ownBundleID else { return }
        launchWaits[bundleID]?.cancel()
        launchWaits[bundleID] = Task { @MainActor [weak self] in
            var found = false
            let deadline = Date().addingTimeInterval(Self.launchWait)
            while Date() < deadline {
                try? await Task.sleep(nanoseconds: 500_000_000)
                if Task.isCancelled { return }
                guard let self else { return }
                if self.controller.hasMenuBarItem(bundleID) {
                    found = true
                    break
                }
            }
            guard let self, !Task.isCancelled else { return }
            self.launchWaits[bundleID] = nil
            if found { self.controller.noteLaunchedApp(bundleID) }
            self.trigger(.appLaunched)
        }
    }

    // MARK: - ⌘-drag in the menu bar (feature 33)

    func userDragBegan() {
        // A drag that starts while the last one is still settling: that one's order is read after this one.
        settleTask?.cancel()
        settleTask = nil
        if orderAtDragStart == nil {
            orderAtDragStart = controller.liveLayoutKeys(controller.layoutLiveItems())
            sectionOrdersAtDragStart = controller.layoutSectionLiveOrders()
        }
    }

    func userDragEnded() {
        controller.postDragSettling = true
        controller.noteBarChanged()
        settleTask = Task { @MainActor [weak self] in
            // Let the menu bar settle (frames still on two reads, a moment after the drop), then read the new order.
            await self?.controller.waitForBarToSettle()
            guard let self, !Task.isCancelled else { return }
            let before = self.orderAtDragStart
            let sectionsBefore = self.sectionOrdersAtDragStart
            self.orderAtDragStart = nil
            self.sectionOrdersAtDragStart = [:]
            self.settleTask = nil
            self.adoptUserOrder(before: before, sectionsBefore: sectionsBefore)
            self.controller.postDragSettling = false
            self.controller.barUnfrozen()
            if !self.pending.isEmpty { self.schedule(after: Self.debounce) }
        }
    }

    private func adoptUserOrder(before: [String]?, sectionsBefore: [SnugBarCore.Section: [String]]) {
        // Without Accessibility there is no live reader, so items can't be matched to the keys the layout is saved
        // under: nothing is adopted (reduced mode leaves the saved layout alone).
        guard !controller.loadFailed, !controller.dragWatcher.userIsDragging, Permissions.accessibility else { return }
        let positions = try? controller.orderFile.readPositions()
        var changed = false
        let live = controller.liveLayoutKeys(controller.layoutLiveItems())
        if !live.isEmpty, let before, before != live {
            let saved = DesiredOrder.normalized(controller.settings.layout.shownOrder, positions: positions)
            let adopted = DesiredOrder.adopting(live: live, into: saved)
            if adopted != controller.settings.layout.shownOrder {
                controller.update { $0.layout.shownOrder = adopted }
                NSLog("SnugBar: adopted the order arranged with ⌘-drag (%d items)", live.count)
                changed = true
            }
        }
        // Hidden items dragged while their section was expanded: the order file has their new order.
        let sectionsNow = controller.layoutSectionLiveOrders()
        for section in SectionOrder.sections {
            guard let now = sectionsNow[section], !now.isEmpty, let then = sectionsBefore[section], then != now else { continue }
            let saved = DesiredOrder.normalized(controller.settings.layout.order(for: section), positions: positions)
            let adopted = DesiredOrder.adopting(live: now, into: saved)
            guard adopted != controller.settings.layout.order(for: section) else { continue }
            controller.update { $0.layout.setOrder(adopted, for: section) }
            NSLog("SnugBar: adopted the %@ order arranged with ⌘-drag", section.title)
            changed = true
        }
        if changed { controller.layoutChanged() }
    }

    // MARK: - Explicit (user) order

    /// The user arranged items in the editor: apply the saved order now, with the ⌘-drag fallback if needed.
    func applyUserOrder(after delay: TimeInterval) {
        Task { @MainActor [weak self] in
            if delay > 0 { try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000)) }
            guard let self else { return }
            while self.running || self.controller.barIsFrozen { try? await Task.sleep(nanoseconds: 200_000_000) }
            // In Zen the apps and spacers are out of the menu bar: the order is applied when Zen ends (`zenEnded`).
            if self.controller.state.zen {
                self.pending.insert(.userOrder)
                return
            }
            self.running = true
            let evaluation = self.evaluate(explicit: true)
            await self.execute(evaluation, explicit: true)
            self.running = false
            if !self.pending.isEmpty { self.schedule(after: Self.debounce) }
        }
    }

    // MARK: - Reconcile

    private func schedule(after delay: TimeInterval) {
        work?.cancel()
        let item = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.run() }
        }
        work = item
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: item)
    }

    private func run() {
        guard !stopped, !pending.isEmpty else { return }
        // Nothing is checked or written in Zen: the triggers wait, and the end of Zen schedules them (`zenEnded`).
        if controller.state.zen { return }
        // One at a time; and not while the menu bar shows something other than the plan or someone is dragging.
        if running || controller.layoutIsBusy || controller.barIsFrozen || editorDragging {
            schedule(after: 1.0)
            return
        }
        let triggers = pending
        pending = []
        lastTriggers = triggers.sorted()
        running = true
        Task { @MainActor in
            if triggers.contains(.systemBuildChanged) {
                self.controller.backupNow(reason: "macOS update")
                if let build = SystemInfo.build, !self.controller.loadFailed {
                    self.controller.update { $0.lastSystemBuild = build }
                }
            }
            // Launch, wake, display and app launches already re-apply the allow-list in the app's observers.
            if !triggers.isDisjoint(with: [.settingsImported, .restored, .systemBuildChanged]) {
                self.controller.applyVisibility(force: true)
                try? await Task.sleep(nanoseconds: 800_000_000)
            }
            // Nothing to keep until the user arranges items: don't even read the menu bar.
            // Without Accessibility the menu bar can't be read, so the order isn't checked (reduced mode).
            if self.controller.settings.layout.enforcesAnyOrder, self.controller.checkAvailable(.keepOrder) {
                let evaluation = self.evaluate(explicit: false)
                await self.execute(evaluation, explicit: false)
            }
            self.running = false
            if !self.pending.isEmpty { self.schedule(after: Self.debounce) }
        }
    }

    func evaluate(explicit: Bool) -> LayoutReconcile.Evaluation {
        let items = controller.layoutLiveItems()
        let positions = try? controller.orderFile.readPositions()
        let evaluation = LayoutReconcile.evaluate(
            layout: controller.settings.layout, live: controller.liveLayoutKeys(items),
            positions: positions, ownBundleID: controller.ownBundleID,
            sectionKeys: controller.layoutSectionKeys(positions: positions), readerAvailable: Permissions.accessibility,
            userDragging: controller.barIsFrozen, editorDragging: editorDragging, explicit: explicit, zen: controller.state.zen
        )
        lastEvaluation = evaluation
        return evaluation
    }

    private func execute(_ evaluation: LayoutReconcile.Evaluation, explicit: Bool) async {
        let decision = evaluation.decision
        // The desired layout is only saved with a live reader (an evaluation without one has nothing to save).
        if !controller.loadFailed, Permissions.accessibility {
            if let order = evaluation.orderToSave, order != controller.settings.layout.shownOrder {
                controller.update { $0.layout.shownOrder = order }
            }
            for (raw, order) in evaluation.sectionOrdersToSave {
                guard let section = SnugBarCore.Section(rawValue: raw), order != controller.settings.layout.order(for: section) else { continue }
                controller.update { $0.layout.setOrder(order, for: section) }
            }
        }
        // One write for Shown and the hidden sections.
        let changes = evaluation.fileChanges
        var written = false
        var writeError: String?
        if !changes.isEmpty {
            do {
                try controller.arranger.writeOrder(changes)
                written = true
                NSLog("SnugBar: layout restored (%d positions written)", changes.count)
            } catch {
                writeError = String(describing: error)
                NSLog("SnugBar: layout write failed: %@", writeError!)
            }
        }
        switch decision.action {
        case .none:
            if explicit, writeError == nil { controller.layoutMessage = nil }
        case .skipped:
            NSLog("SnugBar: layout check skipped: %@", decision.reasons.joined(separator: "; "))
            if explicit { controller.layoutMessage = "The menu bar wasn’t rearranged: \(decision.reasons.joined(separator: "; "))." }
        case .writeOrderFile:
            if writeError == nil, let plan = decision.plan {
                for (key, value) in plan.freePositions {
                    guard let id = LayoutSpacer.id(fromKey: key), let spacer = controller.settings.layout.spacer(id: id) else { continue }
                    controller.spacerBar.place(spacer, at: value)
                    controller.noteBarChanged()
                    written = true
                }
                if explicit { controller.layoutMessage = nil }
            }
        case .dragMoves:
            // Moving the pointer is only acceptable when the user just asked for the move.
            guard explicit, let plan = decision.plan else { break }
            let result = await controller.arranger.dragMoves(plan.moves) { [controller] key, snapshot in
                controller.layoutItem(for: key, in: snapshot)
            }
            controller.noteBarChanged()
            controller.layoutMessage = result.failed.isEmpty ? nil
                : "Some items couldn’t be dragged into place (\(result.failed.count)); they may be in the system overflow."
            written = true
        }
        if let writeError, explicit { controller.layoutMessage = "The menu bar wasn’t rearranged: \(writeError)." }
        guard written || writeError != nil || decision.action == .skipped else { return }
        if written { try? await Task.sleep(nanoseconds: 1_200_000_000) }
        controller.layoutChanged()
    }
}
