import XCTest
@testable import SnugBarCore

final class MenuBarIconStyleTests: XCTestCase {
    func testRawValuesAndTitles() {
        XCTAssertEqual(MenuBarIconStyle.allCases, [.chevrons, .capsule])
        XCTAssertEqual(MenuBarIconStyle.chevrons.rawValue, "chevrons")
        XCTAssertEqual(MenuBarIconStyle.capsule.rawValue, "capsule")
        XCTAssertEqual(MenuBarIconStyle.chevrons.title, "Chevrons")
        XCTAssertEqual(MenuBarIconStyle.capsule.title, "Capsule")
    }

    func testDefaultIsChevrons() {
        XCTAssertEqual(MenuBarIconStyle.default, .chevrons)
        XCTAssertEqual(Settings().menuBarIcon, .chevrons)
        XCTAssertEqual(Settings.default.menuBarIcon, .chevrons)
    }

    func testChevronsAreTheSymbolsSnugBarAlwaysUsed() {
        let expected: [MenuBarIconState: String] = [
            .collapsed: "chevron.left", .expanded: "chevron.right", .all: "chevron.right.2",
            .swapped: "arrow.left.arrow.right", .zen: "eye.slash", .warning: "exclamationmark.triangle",
        ]
        for state in MenuBarIconState.allCases {
            XCTAssertEqual(MenuBarIconStyle.chevrons.symbolName(for: state), expected[state], "\(state)")
            XCTAssertNil(MenuBarIconStyle.capsule.symbolName(for: state), "capsule is drawn in code")
        }
    }

    func testDecodesKnownAndUnknownValues() throws {
        let decoder = JSONDecoder()
        XCTAssertEqual(try decoder.decode([MenuBarIconStyle].self, from: Data(#"["capsule","chevrons"]"#.utf8)), [.capsule, .chevrons])
        XCTAssertEqual(try decoder.decode([MenuBarIconStyle].self, from: Data(#"["sparkles",""]"#.utf8)), [.chevrons, .chevrons])
        XCTAssertThrowsError(try decoder.decode([MenuBarIconStyle].self, from: Data("[3]".utf8)))
    }

    func testEncodesRawValue() throws {
        let data = try JSONEncoder().encode([MenuBarIconStyle.capsule])
        XCTAssertEqual(String(decoding: data, as: UTF8.self), #"["capsule"]"#)
    }
}

final class MenuBarIconStateTests: XCTestCase {
    private func resolve(_ state: BarState, ax: Bool = true, error: Bool = false) -> MenuBarIconState {
        MenuBarIconState.resolve(state, accessibilityGranted: ax, hasError: error)
    }

    func testRevealLevels() {
        XCTAssertEqual(resolve(BarState()), .collapsed)
        XCTAssertEqual(resolve(BarState(reveal: .expanded)), .expanded)
        XCTAssertEqual(resolve(BarState(reveal: .all)), .all)
        XCTAssertEqual(resolve(BarState(reveal: .expanded, revealInBar: true)), .expanded, "the icon follows the reveal, wherever it shows")
    }

    func testSwappedOnlyWhileCollapsed() {
        XCTAssertEqual(resolve(BarState(swapped: true)), .swapped)
        XCTAssertEqual(resolve(BarState(reveal: .expanded, swapped: true)), .expanded)
    }

    func testPriorities() {
        XCTAssertEqual(resolve(BarState(zen: true)), .zen)
        XCTAssertEqual(resolve(BarState(swapped: true, zen: true)), .zen)
        XCTAssertEqual(resolve(BarState(zen: true), ax: false), .warning)
        XCTAssertEqual(resolve(BarState(reveal: .all), error: true), .warning)
    }
}

final class CapsuleGlyphGeometryTests: XCTestCase {
    let g = CapsuleGlyphGeometry()

    func testCapsuleIsCentred17By9() {
        XCTAssertEqual(CapsuleGlyphGeometry.canvas, CGSize(width: 18, height: 18))
        XCTAssertEqual(g.outer.size, CGSize(width: 17, height: 9))
        XCTAssertEqual(g.outer.midX, 9, accuracy: 0.001)
        XCTAssertEqual(g.outer.midY, 9, accuracy: 0.001)
        // The stroke is centred on the path, so the outline's outer edge is the 17×9 rect.
        XCTAssertEqual(g.capsule.width + CapsuleGlyphGeometry.strokeWidth, 17, accuracy: 0.001)
        XCTAssertEqual(g.corner, g.capsule.height / 2, accuracy: 0.001)
    }

    func testDots() {
        let one = g.dots(1)
        XCTAssertEqual(one.count, 1)
        XCTAssertEqual(one[0].midX, g.outer.midX, accuracy: 0.001)
        let three = g.dots(3)
        XCTAssertEqual(three.count, 3)
        XCTAssertEqual(three[1].midX - three[0].midX, 4.2, accuracy: 0.001)
        XCTAssertEqual(three[2].midX - three[1].midX, 4.2, accuracy: 0.001)
        for dot in one + three {
            XCTAssertEqual(dot.width, 2.6, accuracy: 0.001)
            XCTAssertEqual(dot.midY, g.outer.midY, accuracy: 0.001)
            // Inside the outline's inner edge, with room to spare.
            XCTAssertTrue(g.capsule.insetBy(dx: CapsuleGlyphGeometry.strokeWidth / 2, dy: CapsuleGlyphGeometry.strokeWidth / 2).contains(dot))
        }
    }

    func testSlashAndSwappedFillStayOnTheCanvas() {
        let canvas = CGRect(origin: .zero, size: CapsuleGlyphGeometry.canvas)
        XCTAssertTrue(canvas.contains(g.slash.from))
        XCTAssertTrue(canvas.contains(g.slash.to))
        XCTAssertLessThan(g.slash.from.x, g.slash.to.x)
        XCTAssertLessThan(g.slash.from.y, g.slash.to.y)
        XCTAssertEqual(g.swappedFill.minX, g.outer.minX)
        XCTAssertEqual(g.swappedFill.width, g.outer.width / 2, accuracy: 0.001)
    }
}

final class SettingsMigrationTests: XCTestCase {
    /// A settings file as SnugBar wrote it before the menu bar icon setting (schema version 1).
    private let version1File = #"""
    {
      "hider" : "automatic",
      "knownApps" : { "com.example.meters" : "Meters" },
      "schemaVersion" : 1,
      "sections" : { "apps" : { "com.example.meters" : "shown" }, "defaultSection" : "hidden" },
      "setupCompleted" : true,
      "showIcon" : false
    }
    """#

    func testCurrentSchemaIsTwo() {
        XCTAssertEqual(Settings.currentSchemaVersion, 2)
        XCTAssertEqual(Settings.default.schemaVersion, 2)
    }

    func testVersion1FileMigratesToChevrons() throws {
        let s = try SettingsStore.decode(Data(version1File.utf8))
        XCTAssertEqual(s.schemaVersion, Settings.currentSchemaVersion)
        XCTAssertEqual(s.menuBarIcon, .chevrons)
        // Everything else is kept.
        XCTAssertFalse(s.showIcon)
        XCTAssertEqual(s.setupCompleted, true)
        XCTAssertEqual(s.sections.apps["com.example.meters"], .shown)
        XCTAssertEqual(s.knownApps["com.example.meters"], "Meters")
    }

    func testVersion1FileWithAStyleStillGetsChevrons() throws {
        // Version 1 never had the key; whatever is there isn't a choice the user made.
        let json = #"{"schemaVersion": 1, "menuBarIcon": "capsule"}"#
        XCTAssertEqual(try SettingsStore.decode(Data(json.utf8)).menuBarIcon, .chevrons)
    }

    func testVersion2KeepsTheChoiceAndUnknownFallsBack() throws {
        XCTAssertEqual(try SettingsStore.decode(Data(#"{"schemaVersion": 2, "menuBarIcon": "capsule"}"#.utf8)).menuBarIcon, .capsule)
        XCTAssertEqual(try SettingsStore.decode(Data(#"{"schemaVersion": 2, "menuBarIcon": "hologram"}"#.utf8)).menuBarIcon, .chevrons)
        XCTAssertEqual(try SettingsStore.decode(Data(#"{"schemaVersion": 2}"#.utf8)).menuBarIcon, .chevrons)
    }

    func testMigratedFileSavesAsCurrentSchemaAndRoundTrips() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("SnugBarTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = SettingsStore(url: dir.appendingPathComponent("settings.json"))
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data(version1File.utf8).write(to: store.url)
        var s = try store.load()
        s.menuBarIcon = .capsule
        try store.save(s)
        let json = try JSONSerialization.jsonObject(with: Data(contentsOf: store.url)) as? [String: Any]
        XCTAssertEqual(json?["schemaVersion"] as? Int, 2)
        XCTAssertEqual(json?["menuBarIcon"] as? String, "capsule")
        XCTAssertEqual(try store.load(), s)
    }

    func testImportOfVersion1FileMigrates() throws {
        let s = try SettingsTransfer.decodeImport(Data(version1File.utf8))
        XCTAssertEqual(s.schemaVersion, 2)
        XCTAssertEqual(s.menuBarIcon, .chevrons)
    }

    func testNewerThanCurrentIsStillRefused() {
        XCTAssertThrowsError(try SettingsStore.decode(Data(#"{"schemaVersion": 3}"#.utf8))) {
            XCTAssertEqual($0 as? SettingsError, .unsupportedSchemaVersion(3))
        }
    }
}

final class ProjectInfoTests: XCTestCase {
    func testVersionString() {
        XCTAssertEqual(ProjectInfo.versionString(short: "1.0.0", build: "42"), "1.0.0 (42)")
        XCTAssertEqual(ProjectInfo.versionString(short: "1.0.0", build: nil), "1.0.0")
        XCTAssertEqual(ProjectInfo.versionString(short: "1.0.0", build: "1.0.0"), "1.0.0")
        XCTAssertEqual(ProjectInfo.versionString(short: nil, build: "42"), "dev")
    }

    func testOwnershipAndLinks() {
        XCTAssertEqual(ProjectInfo.ownership,
                       "SnugBar is an independent open-source project, created and maintained by 0sahil. It is not affiliated with Apple.")
        XCTAssertEqual(ProjectInfo.repositoryURL.absoluteString, "https://github.com/0sahil/snugbar")
        XCTAssertEqual(ProjectInfo.license, "MIT License")
    }

    func testBundleVersionFromHelperAndLink() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("SnugBarTests-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: root) }
        let contents = root.appendingPathComponent("Example.app/Contents")
        try fm.createDirectory(at: contents.appendingPathComponent("Helpers"), withIntermediateDirectories: true)
        let plist: [String: Any] = ["CFBundleShortVersionString": "1.0.0", "CFBundleVersion": "321"]
        try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
            .write(to: contents.appendingPathComponent("Info.plist"))
        let helper = contents.appendingPathComponent("Helpers/snugbar")
        try Data().write(to: helper)
        XCTAssertEqual(ProjectInfo.bundleVersion(forExecutable: helper), "1.0.0 (321)")
        // A link in a bin directory resolves to the app it points into.
        let bin = root.appendingPathComponent("bin")
        try fm.createDirectory(at: bin, withIntermediateDirectories: true)
        let link = bin.appendingPathComponent("snugbar")
        try fm.createSymbolicLink(at: link, withDestinationURL: helper)
        XCTAssertEqual(ProjectInfo.bundleVersion(forExecutable: link), "1.0.0 (321)")
        // Not inside an app bundle.
        XCTAssertEqual(ProjectInfo.bundleVersion(forExecutable: bin.appendingPathComponent("other")), "dev")
    }
}
