import AppKit
import SnugBarCore
import SnugBarEngine

/// Layout persistence, spacers, new apps, backups and settings transfer (features 30–42, 78–82).
extension AppController {
    func startLayout() {
        orderFile.backupLayout = { [weak self] in self.map { LayoutBackup.Layout(settings: $0.settings) } }
        orderFile.didWrite = { [weak self] in self?.noteBarChanged() }
        syncSpacers()
        dragWatcher.onBegin = { [weak self] in self?.keeper.userDragBegan() }
        dragWatcher.onEnd = { [weak self] in self?.keeper.userDragEnded() }
        dragWatcher.start()
        keeper.start()
    }

    /// Spacers follow the settings; Zen shrinks them to zero width. Held back while the user ⌘-drags items.
    func syncSpacers() {
        guard !isPreview else { return }
        if barIsFrozen {
            deferSpacerSync()
            return
        }
        spacerBar.sync(settings.layout.spacers, zen: state.zen)
        noteBarChanged()
    }

    /// The order-file keys of the items of Hidden and Always Hidden that SnugBar knows (live, remembered, running).
    func layoutSectionKeys(positions: [String: Double]?) -> [SnugBarCore.Section: [String]] {
        guard let positions else { return [:] }
        var result: [SnugBarCore.Section: [String]] = [:]
        for item in allItems() where !item.isAppleItem {
            let section = settings.sections.section(for: item)
            guard SectionOrder.sections.contains(section), let key = SectionOrder.fileKey(for: item.id, positions: positions) else { continue }
            result[section, default: []].append(key)
        }
        return result
    }

    /// Hidden and Always Hidden as the order file has them now, left to right.
    func layoutSectionLiveOrders() -> [SnugBarCore.Section: [String]] {
        guard let positions = try? orderFile.readPositions() else { return [:] }
        return layoutSectionKeys(positions: positions).mapValues { SectionOrder.leftToRight($0, positions: positions) }
    }

    /// Items in the menu bar now whose app is on screen (hidden apps' items can linger in the Accessibility tree).
    func layoutLiveItems() -> [MenuBarItem] {
        guard Permissions.accessibility else { return [] }
        let allowed = currentAllowed
        return snapshotItems().filter {
            $0.isAppleItem || $0.ownerBundleID == ownBundleID || allowed?.contains($0.ownerBundleID) ?? true
        }
    }

    /// Shown keys left to right, with SnugBar's spacer items named by their spacer key.
    func liveLayoutKeys(_ items: [MenuBarItem]) -> [String] {
        let frames = spacerBar.frames()
        return LayoutReconcile.liveKeys(items, sections: settings.sections, ownBundleID: ownBundleID) { [spacerBar] in
            spacerBar.key(for: $0, frames: frames)
        }
    }

    /// The reader item a desired-order key stands for: the spacer's item, the item with that ID, or the item under
    /// its other ID (order-file key vs. fallback).
    func layoutItem(for key: String, in snapshot: MenuBarSnapshot) -> MenuBarItem? {
        if LayoutSpacer.isSpacerKey(key) {
            let frames = spacerBar.frames()
            return snapshot.items.first { $0.ownerBundleID == ownBundleID && spacerBar.key(for: $0, frames: frames) == key }
        }
        if let item = snapshot.items.first(where: { $0.id.rawValue == key }) { return item }
        let others = ItemIdentityResolver.equivalentIDs(of: ItemID(rawValue: key), orderPositions: try? orderFile.readPositions())
        return snapshot.items.first { others.contains($0.id) }
    }

    /// Something changed the layout: editors read it again.
    func layoutChanged() {
        bumpLayoutRevision()
    }

    /// The `order` command moved an item: the saved order follows (feature 79).
    func noteUserOrder(_ item: MenuBarItem, _ placement: ControlPlacement) {
        guard !isPreview else { return }
        let live = liveLayoutKeys(layoutLiveItems())
        let saved = settings.layout.shownOrder
        var order = saved.isEmpty ? live : DesiredOrder.merging(live: live, into: saved)
        switch placement {
        case let .before(anchor): order = DesiredOrder.moving([item.id.rawValue], to: .before(anchor.id.rawValue), in: order)
        case let .after(anchor): order = DesiredOrder.moving([item.id.rawValue], to: .after(anchor.id.rawValue), in: order)
        }
        update { $0.layout.shownOrder = order }
        layoutChanged()
    }

    // MARK: - New apps (feature 41)

    /// Records apps seen for the first time: their section, their place in Shown's order, and a notice for the menu.
    func noteNewApps(_ items: [MenuBarItem], seen: [String: String]) {
        guard !isPreview, !loadFailed else { return }
        let candidates = seen.map { (bundleID: $0.key, name: $0.value) }.sorted { $0.bundleID < $1.bundleID }
        let found = NewAppRule.detect(seen: candidates, settings: settings, ownBundleID: ownBundleID)
        guard !found.isEmpty else { return }
        var keys: [String: [String]] = [:]
        for item in items where !item.isAppleItem && !item.ownerBundleID.isEmpty {
            keys[item.ownerBundleID, default: []].append(item.id.rawValue)
        }
        update { NewAppRule.apply(found, keys: keys, to: &$0) }
        newAppNotices.add(found)
        if found.contains(where: { $0.section == .shown }) { keeper.trigger(.appLaunched) }
    }

    /// Whether the app has a menu bar item: in the reader (even hidden ones linger there) or in the order file.
    func hasMenuBarItem(_ bundleID: String) -> Bool {
        if Permissions.accessibility, reader.snapshot(orderPositions: nil).items.contains(where: { $0.ownerBundleID == bundleID }) {
            return true
        }
        let prefix = "status:\(bundleID)::"
        return (try? orderFile.readPositions())?.keys.contains { $0.hasPrefix(prefix) } ?? false
    }

    /// A launched app showed an item: treat it as seen.
    func noteLaunchedApp(_ bundleID: String) {
        guard bundleID != ownBundleID, let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first else { return }
        let items = Permissions.accessibility ? reader.snapshot(orderPositions: try? orderFile.readPositions()).items.filter { $0.ownerBundleID == bundleID } : []
        noteNewApps(items, seen: [bundleID: app.localizedName ?? bundleID])
    }

    /// The notices to show in the menu that is opening; they are gone afterwards.
    func takeNewAppNotices() -> [NewApp] {
        newAppNotices.takeForMenu()
    }

    // MARK: - Layout editor

    struct LayoutEditorContent {
        var rows: [SnugBarCore.Section: [LayoutTile]]
        var images: [String: NSImage]
        var orderAccess: Bool
        var pictures: Bool
    }

    func layoutEditorContent() -> LayoutEditorContent {
        let live = layoutLiveItems()
        let items = catalog.merged(live: live.filter { $0.ownerBundleID != ownBundleID }, running: ItemGathering.runningBundleIDs(),
                                   knownApps: settings.knownApps)
            .filter { $0.ownerBundleID != ownBundleID }
        let positions = try? orderFile.readPositions()
        var images: [ItemID: ItemImager.ItemImage] = [:]
        for item in items { images[item.id] = itemImage(for: item, positions: positions) }
        let rows = LayoutEditorRows.rows(
            items: items, liveShown: liveLayoutKeys(live), sections: settings.sections, layout: settings.layout, positions: positions
        ) { images[$0.id].map { $0.source != .appIcon } ?? false }
        var tileImages: [String: NSImage] = [:]
        for tile in rows.values.joined() {
            guard let first = tile.items.first else { continue }
            tileImages[tile.key] = NSImage.forBarItem(images[first.id])
        }
        return LayoutEditorContent(rows: rows, images: tileImages, orderAccess: positions != nil,
                                   pictures: availability.showsItemPictures)
    }

    /// A drop that orders a section's row (and apps that move into the section). Hidden and Always Hidden are only
    /// offered this with the order file, which is what places their items.
    func editorReorder(_ section: SnugBarCore.Section, order: [String], appsIn: [String]) {
        if !appsIn.isEmpty { setSection(section, for: appsIn) }
        let positions = try? orderFile.readPositions()
        let live = section == .shown ? liveLayoutKeys(layoutLiveItems()) : layoutSectionLiveOrders()[section] ?? []
        let saved = settings.layout.order(for: section)
        let seed = DesiredOrder.normalized(saved.isEmpty ? live : saved, positions: positions)
        let next = DesiredOrder.adopting(live: DesiredOrder.normalized(order, positions: positions), into: seed)
        update { $0.layout.setOrder(next, for: section) }
        layoutChanged()
        // Apps coming into Shown appear a moment after the allow-list changes.
        keeper.applyUserOrder(after: appsIn.isEmpty ? 0 : 1.0)
    }

    func editorMoveApps(_ bundleIDs: [String], to section: SnugBarCore.Section) {
        guard !bundleIDs.isEmpty else { return }
        setSection(section, for: bundleIDs)
        let names = bundleIDs.map { settings.knownApps[$0] ?? visibleApps[$0] ?? $0 }
        layoutMessage = names.count == 1 ? "Moved \(names[0]) to \(section.title)." : "Moved \(names.count) apps to \(section.title)."
        layoutChanged()
    }

    func addSpacer() {
        let live = liveLayoutKeys(layoutLiveItems())
        update { $0.layout.addSpacer(LayoutSpacer(), live: live) }
        layoutMessage = "Added a spacer at the left end of Shown. Drag it where you want it."
        layoutChanged()
    }

    func removeSpacer(id: String) {
        guard let spacer = settings.layout.spacer(id: id) else { return }
        update { $0.layout.removeSpacer(id: id) }
        spacerBar.forget(spacer)
        layoutChanged()
    }

    func setSpacerWidth(id: String, _ width: Double) {
        update { $0.layout.setSpacerWidth(id: id, width) }
        layoutChanged()
    }

    // MARK: - Backups (feature 81)

    var backupStore: LayoutBackupStore { LayoutBackupStore(directory: orderFile.backupDirectory) }

    /// Saves the positions (when readable) and SnugBar's layout. Returns false when it couldn't be written.
    @discardableResult
    func backupNow(reason: String) -> Bool {
        guard !isPreview else { return false }
        do {
            try orderFile.saveBackup(reason: reason)
            return true
        } catch {
            NSLog("SnugBar: layout backup failed: %@", String(describing: error))
            return false
        }
    }

    func layoutBackups() -> [LayoutBackupStore.Entry] {
        isPreview ? previewBackups : backupStore.list()
    }

    /// Restores a backup: SnugBar's layout, and the system positions when the order file can be written.
    func restoreBackup(_ entry: LayoutBackupStore.Entry) {
        let backup: LayoutBackup
        do {
            backup = try backupStore.load(entry.url)
        } catch {
            layoutMessage = "The backup couldn’t be read: \(error.localizedDescription)"
            return
        }
        guard backupNow(reason: "restore") else {
            layoutMessage = "Nothing was restored: a backup of the current layout couldn’t be saved first."
            return
        }
        if let layout = backup.layout {
            update { layout.apply(to: &$0) }
        }
        var positionsRestored = false
        var problem: String?
        if !backup.positions.isEmpty {
            if (try? orderFile.readPositions()) != nil {
                do {
                    try orderFile.restore(backup.positions, takeBackup: false)
                    positionsRestored = true
                } catch {
                    problem = String(describing: error)
                }
            }
        }
        let date = entry.createdAt.formatted(date: .abbreviated, time: .shortened)
        switch (backup.layout != nil, positionsRestored) {
        case (_, true): layoutMessage = "Restored the layout from \(date)."
        case (true, false):
            layoutMessage = problem.map { "Restored sections and order from \(date); item positions weren’t written: \($0)." }
                ?? "Restored sections and order from \(date). Item positions need Menu Bar folder access; SnugBar arranges items once it has it."
        case (false, false):
            layoutMessage = "This backup only has item positions, which need Menu Bar folder access to restore."
        }
        keeper.trigger(.restored)
        layoutChanged()
    }

    /// Every third-party app back in the default section; no kept order, no spacers. Backs up first.
    func resetLayout() {
        guard backupNow(reason: "reset") else {
            layoutMessage = "The layout wasn’t reset: a backup couldn’t be saved first."
            return
        }
        for spacer in settings.layout.spacers { spacerBar.forget(spacer) }
        update { $0 = LayoutReset.reset($0) }
        newAppNotices = NewAppNotices()
        layoutMessage = "Layout reset. Every app is in \(settings.sections.defaultSection.title); a backup was saved first."
        layoutChanged()
    }

    // MARK: - Settings file (feature 82)

    func exportSettings(to url: URL) throws {
        try AtomicFile.write(SettingsTransfer.export(settings), to: url)
    }

    /// Imports a settings file after checking it and backing up the layout. Returns an error message, or nil.
    func importSettings(from url: URL) -> String? {
        let imported: SnugBarCore.Settings
        do {
            imported = try SettingsTransfer.decodeImport(Data(contentsOf: url))
        } catch let error as SettingsTransfer.ImportError {
            return error.description
        } catch {
            return error.localizedDescription
        }
        backupNow(reason: "import")
        let removed = settings.layout.spacers.filter { old in !imported.layout.spacers.contains { $0.id == old.id } }
        for spacer in removed { spacerBar.forget(spacer) }
        // Whether setup was done belongs to this Mac, not to the imported file.
        update { [setupCompleted = settings.setupCompleted] in
            $0 = imported
            $0.setupCompleted = setupCompleted
        }
        layoutMessage = "Imported settings from \(url.lastPathComponent). A backup of the layout was saved first."
        keeper.trigger(.settingsImported)
        layoutChanged()
        return nil
    }

    /// Made-up backups for offscreen renders of the Layout pane.
    private var previewBackups: [LayoutBackupStore.Entry] {
        let base = Date(timeIntervalSince1970: 1_794_650_000)
        let dir = URL(fileURLWithPath: "/tmp/snugbar-preview-backups", isDirectory: true)
        let samples: [(offset: Double, build: String, count: Int, reason: String)] = [
            (0, "27C101", 24, "order"), (-3_600, "27C101", 24, "reset"), (-86_400 * 2, "27C100", 22, "macOS update"),
            (-86_400 * 5, "27C100", 21, "order"),
        ]
        return samples.map { sample -> LayoutBackupStore.Entry in
            let date = base.addingTimeInterval(sample.offset)
            return LayoutBackupStore.Entry(
                url: dir.appendingPathComponent(LayoutBackupPolicy.fileName(for: date)), createdAt: date, systemBuild: sample.build,
                positionCount: sample.count, orderCount: 9, appSectionCount: 6, spacerCount: 1, reason: sample.reason
            )
        }
    }
}
