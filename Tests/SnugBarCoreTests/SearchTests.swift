import XCTest
@testable import SnugBarCore

final class FuzzyMatcherTests: XCTestCase {
    private let chatter = Fixtures.item("status:com.example.chat::Item-0", bundle: Fixtures.chat, app: "Chatter")
    private let cpu = Fixtures.item("status:com.example.meters::CPU_mini", bundle: Fixtures.meters, app: "Meters", name: "Meters: CPU")
    private let ram = Fixtures.item("status:com.example.meters::RAM_mini", bundle: Fixtures.meters, app: "Meters", name: "Meters: RAM")
    private let monitor = Fixtures.item("com.example.light#0", bundle: "com.example.light", app: "LightControl")
    private let control = Fixtures.item("com.apple.menuextra.controlcenter#0", bundle: "com.apple.controlcenter",
                                        app: "Control Center", name: "Control Center", apple: true)
    private let clip = Fixtures.item("status:org.example.clipboard::Item-0", bundle: Fixtures.clipboard, app: "Clipboard Keeper")

    func testMatchKinds() {
        XCTAssertEqual(FuzzyMatcher.match("cha", in: "Chatter")?.kind, .prefix)
        XCTAssertEqual(FuzzyMatcher.match("CHA", in: "chatter")?.kind, .prefix, "case-insensitive")
        XCTAssertEqual(FuzzyMatcher.match("cent", in: "Control Center")?.kind, .wordStart)
        XCTAssertEqual(FuzzyMatcher.match("control", in: "LightControl")?.kind, .wordStart, "camelCase word")
        XCTAssertEqual(FuzzyMatcher.match("cc", in: "Control Center")?.kind, .wordStart, "initials")
        XCTAssertEqual(FuzzyMatcher.match("mtr", in: "Meters")?.kind, .subsequence)
        XCTAssertNil(FuzzyMatcher.match("xyz", in: "Meters"))
        XCTAssertNil(FuzzyMatcher.match("", in: "Meters"))
        XCTAssertEqual(FuzzyMatcher.match("ecran", in: "Écran")?.kind, .prefix, "diacritics ignored")
    }

    func testTiersOrderPrefixThenWordStartThenSubsequence() {
        let a = FuzzyMatcher.match("con", in: "Control Center")!
        let b = FuzzyMatcher.match("con", in: "LightControl")!
        let c = FuzzyMatcher.match("con", in: "Clipboard Keeper on")
        XCTAssertGreaterThan(a.score, b.score)
        XCTAssertEqual(a.kind, .prefix)
        XCTAssertEqual(b.kind, .wordStart)
        XCTAssertEqual(c?.kind, .subsequence)
        XCTAssertGreaterThan(b.score, c!.score)
    }

    func testTighterSubsequenceScoresHigher() {
        let tight = FuzzyMatcher.match("mtr", in: "xmtrx")!
        let loose = FuzzyMatcher.match("mtr", in: "xmxxtxxr")!
        XCTAssertEqual(tight.kind, .subsequence)
        XCTAssertGreaterThan(tight.score, loose.score)
    }

    func testRankOrdersByTier() {
        let items = [monitor, control, clip, cpu]
        let ranked = FuzzyMatcher.rank("con", items: items, recents: [])
        XCTAssertEqual(ranked.map(\.item.id), [control.id, monitor.id])
        XCTAssertEqual(ranked.map(\.kind), [.prefix, .wordStart])
    }

    func testMatchesItemNameAfterAppName() {
        let ranked = FuzzyMatcher.rank("ram", items: [cpu, ram], recents: [])
        XCTAssertEqual(ranked.first?.item.id, ram.id)
        XCTAssertEqual(ranked.first?.kind, .prefix, "'RAM' is the item's own name")
        // Both share the app name, so "met" finds both, in their given order.
        XCTAssertEqual(FuzzyMatcher.rank("met", items: [cpu, ram], recents: []).map(\.item.id), [cpu.id, ram.id])
    }

    func testRecentBoostReordersWithinTier() {
        let ranked = FuzzyMatcher.rank("met", items: [cpu, ram], recents: [ram.id])
        XCTAssertEqual(ranked.map(\.item.id), [ram.id, cpu.id])
        XCTAssertEqual(ranked.first?.recentRank, 0)
    }

    func testRecentBoostNeverBeatsABetterKind() {
        // "con": Control Center is a prefix match; LightControl only a word-start match, even when recent.
        let ranked = FuzzyMatcher.rank("con", items: [monitor, control], recents: [monitor.id])
        XCTAssertEqual(ranked.map(\.item.id), [control.id, monitor.id])
    }

    func testMoreRecentGetsMoreBoost() {
        let ranked = FuzzyMatcher.rank("met", items: [cpu, ram], recents: [cpu.id, ram.id])
        XCTAssertEqual(ranked.map(\.item.id), [cpu.id, ram.id])
        let swapped = FuzzyMatcher.rank("met", items: [cpu, ram], recents: [ram.id, cpu.id])
        XCTAssertEqual(swapped.map(\.item.id), [ram.id, cpu.id])
    }

    func testEmptyQueryListsRecentsFirstThenEverything() {
        let items = [chatter, cpu, ram, clip]
        let ranked = FuzzyMatcher.rank("  ", items: items, recents: [clip.id, ItemID(rawValue: "gone#0"), cpu.id])
        XCTAssertEqual(ranked.map(\.item.id), [clip.id, cpu.id, chatter.id, ram.id])
        XCTAssertEqual(ranked.map(\.recentRank), [0, 2, nil, nil])
    }

    func testNoMatchIsLeftOut() {
        XCTAssertTrue(FuzzyMatcher.rank("zzz", items: [chatter, cpu], recents: []).isEmpty)
    }
}

final class RecentItemsTests: XCTestCase {
    func testNotingMovesToFrontWithoutDuplicates() {
        let a = ItemID(rawValue: "a#0"), b = ItemID(rawValue: "b#0"), c = ItemID(rawValue: "c#0")
        XCTAssertEqual(RecentItems.noting(a, in: []), [a])
        XCTAssertEqual(RecentItems.noting(c, in: [a, b]), [c, a, b])
        XCTAssertEqual(RecentItems.noting(b, in: [a, b, c]), [b, a, c])
    }

    func testKeepsTwenty() {
        let list = (0..<20).map { ItemID(rawValue: "app\($0)#0") }
        let next = RecentItems.noting(ItemID(rawValue: "new#0"), in: list)
        XCTAssertEqual(next.count, 20)
        XCTAssertEqual(next.first?.rawValue, "new#0")
        XCTAssertFalse(next.contains(ItemID(rawValue: "app19#0")))
    }

    func testSettingsNoteRecent() {
        var s = Settings()
        s.noteRecent(ItemID(rawValue: "a#0"))
        s.noteRecent(ItemID(rawValue: "b#0"))
        s.noteRecent(ItemID(rawValue: "a#0"))
        XCTAssertEqual(s.recentItems.map(\.rawValue), ["a#0", "b#0"])
    }
}

final class LetterAssignerTests: XCTestCase {
    private func item(_ bundle: String, _ app: String, name: String? = nil, index: Int = 0) -> MenuBarItem {
        Fixtures.item("\(bundle)#\(index)", bundle: bundle, app: app, name: name)
    }

    func testUniqueInitialsAreUsed() {
        let items = [item("com.example.chat", "Chatter"), item("com.example.meters", "Meters"), item("com.example.notes", "Notes")]
        let keys = LetterAssigner.assign(items)
        XCTAssertEqual(keys[items[0].id], "c")
        XCTAssertEqual(keys[items[1].id], "m")
        XCTAssertEqual(keys[items[2].id], "n")
    }

    func testSharedInitialGoesToFirstAndOthersGetAnotherLetter() {
        let items = [
            item("com.example.meters", "Meters", name: "Meters: CPU", index: 0),
            item("com.example.meters", "Meters", name: "Meters: RAM", index: 1),
            item("com.example.chat", "Chatter"),
        ]
        let keys = LetterAssigner.assign(items)
        XCTAssertEqual(keys[items[2].id], "c", "unique initial wins first")
        XCTAssertEqual(keys[items[0].id], "m")
        XCTAssertEqual(keys[items[1].id], "r", "first letter of its own name")
    }

    func testSkipsAmbiguousLetters() {
        let items = [item("com.example.ink", "Ink"), item("com.example.lamp", "Lamp"), item("com.example.owl", "Owl")]
        let keys = LetterAssigner.assign(items)
        XCTAssertEqual(keys.count, 3)
        for key in keys.values { XCTAssertFalse(LetterAssigner.skipped.contains(key)) }
        XCTAssertEqual(keys[items[0].id], "n", "next letter of the app name")
        XCTAssertEqual(keys[items[1].id], "a")
        XCTAssertEqual(keys[items[2].id], "w")
    }

    func testKeysAreUnique() {
        let items = (0..<30).map { item("com.example.app\($0)", "Same") }
        let keys = LetterAssigner.assign(items)
        XCTAssertEqual(LetterAssigner.keys.count, 31, "23 letters plus 8 digits")
        XCTAssertEqual(keys.count, 30)
        XCTAssertEqual(Set(keys.values).count, keys.count)
        let many = (0..<40).map { item("com.example.many\($0)", "Same") }
        XCTAssertEqual(LetterAssigner.assign(many).count, LetterAssigner.keys.count, "extra items get no key")
    }

    func testStableForTheSameList() {
        let items = [item("com.example.chat", "Chatter"), item("com.example.b", "Beta"), item("com.example.c", "Charts")]
        XCTAssertEqual(LetterAssigner.assign(items), LetterAssigner.assign(items))
        XCTAssertEqual(LetterAssigner.assign(items), LetterAssigner.assign(items.map { $0 }))
    }

    func testNonLetterInitialFallsBack() {
        let items = [item("com.example.digits", "1Pass Keeper"), item("com.example.emoji", "★ Star")]
        let keys = LetterAssigner.assign(items)
        XCTAssertEqual(keys.count, 2)
        XCTAssertEqual(keys[items[1].id], "s")
    }

    func testTypedLookup() {
        let items = [item("com.example.chat", "Chatter")]
        let keys = LetterAssigner.assign(items)
        XCTAssertEqual(LetterAssigner.item(for: "c", in: keys), items[0].id)
        XCTAssertEqual(LetterAssigner.item(for: "C", in: keys), items[0].id)
        XCTAssertNil(LetterAssigner.item(for: "x", in: keys))
        XCTAssertNil(LetterAssigner.item(for: "", in: keys))
        XCTAssertNil(LetterAssigner.item(for: "cc", in: keys))
    }
}
