import XCTest
@testable import SnugBarCore

final class SettingsStoreTests: XCTestCase {
    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("SnugBarTests-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDownWithError() throws {
        // Restore write permission in case a test removed it.
        try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dir.path)
        try? FileManager.default.removeItem(at: dir)
    }

    private var sample: Settings {
        var s = Settings()
        s.sections.set(.shown, forBundleID: Fixtures.clipboard)
        s.sections.set(.alwaysHidden, forBundleID: Fixtures.chat)
        s.hider = .overflowDivider
        return s
    }

    func testMissingFileLoadsDefaults() throws {
        let store = SettingsStore(url: dir.appendingPathComponent("settings.json"))
        XCTAssertEqual(try store.load(), .default)
        XCTAssertEqual(Settings.default.sections.defaultSection, .hidden)
        XCTAssertTrue(Settings.default.sections.apps.isEmpty)
    }

    func testRoundTrip() throws {
        let store = SettingsStore(url: dir.appendingPathComponent("nested/settings.json"))
        try store.save(sample)
        XCTAssertEqual(try store.load(), sample)
    }

    func testFileIsReadableJSONWithSchemaVersion() throws {
        let url = dir.appendingPathComponent("settings.json")
        try SettingsStore(url: url).save(sample)
        let json = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any]
        XCTAssertEqual(json?["schemaVersion"] as? Int, 1)
        XCTAssertEqual(json?["hider"] as? String, "overflowDivider")
        let sections = json?["sections"] as? [String: Any]
        XCTAssertEqual((sections?["apps"] as? [String: String])?[Fixtures.chat], "alwaysHidden")
        XCTAssertEqual(sections?["defaultSection"] as? String, "hidden")
        let text = try String(contentsOf: url, encoding: .utf8)
        XCTAssertTrue(text.contains("\n  "), "pretty printed")
    }

    func testAtomicWriteReplacesAndLeavesNoTemporaryFiles() throws {
        let url = dir.appendingPathComponent("settings.json")
        let store = SettingsStore(url: url)
        try store.save(.default)
        try store.save(sample)
        XCTAssertEqual(try store.load(), sample)
        let names = try FileManager.default.contentsOfDirectory(atPath: dir.path)
        XCTAssertEqual(names, ["settings.json"])
    }

    func testFailedWriteKeepsPreviousFile() throws {
        let url = dir.appendingPathComponent("settings.json")
        let store = SettingsStore(url: url)
        try store.save(sample)
        let before = try Data(contentsOf: url)
        // A read-only directory makes the temporary file impossible to create.
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: dir.path)
        XCTAssertThrowsError(try store.save(.default))
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dir.path)
        XCTAssertEqual(try Data(contentsOf: url), before)
        XCTAssertEqual(try store.load(), sample)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: dir.path), ["settings.json"])
    }

    func testNewerSchemaIsRejected() throws {
        let url = dir.appendingPathComponent("settings.json")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data(#"{"schemaVersion": 2, "hider": "automatic"}"#.utf8).write(to: url)
        XCTAssertThrowsError(try SettingsStore(url: url).load()) {
            XCTAssertEqual($0 as? SettingsError, .unsupportedSchemaVersion(2))
        }
    }

    func testMissingSchemaIsRejected() throws {
        XCTAssertThrowsError(try SettingsStore.decode(Data(#"{"hider": "automatic"}"#.utf8))) {
            XCTAssertEqual($0 as? SettingsError, .missingSchemaVersion)
        }
    }

    func testMissingKeysTakeDefaultsAndUnknownKeysAreIgnored() throws {
        let s = try SettingsStore.decode(Data(#"{"schemaVersion": 1, "futureThing": true}"#.utf8))
        XCTAssertEqual(s, .default)
    }

    func testCorruptFileThrows() throws {
        XCTAssertThrowsError(try SettingsStore.decode(Data("{not json".utf8)))
    }
}

final class AppSectionMapTests: XCTestCase {
    func testDefaultsAndAppleItems() {
        var map = AppSectionMap()
        map.set(.shown, forBundleID: Fixtures.clipboard)
        XCTAssertEqual(map.section(forBundleID: Fixtures.clipboard), .shown)
        XCTAssertEqual(map.section(forBundleID: Fixtures.chat), .hidden)
        XCTAssertEqual(map.section(forBundleID: "com.apple.controlcenter", isAppleItem: true), .shown)
    }

    func testAllowedBundleIDs() {
        var map = AppSectionMap()
        map.set(.shown, forBundleID: Fixtures.clipboard)
        map.set(.hidden, forBundleID: Fixtures.meters)
        map.set(.alwaysHidden, forBundleID: Fixtures.chat)
        let seen: Set = [Fixtures.clipboard, Fixtures.meters, Fixtures.chat, "com.example.unlisted"]
        XCTAssertEqual(map.allowedBundleIDs(expanded: false, seenBundleIDs: seen), [Fixtures.clipboard])
        XCTAssertEqual(map.allowedBundleIDs(expanded: true, seenBundleIDs: seen),
                       [Fixtures.clipboard, Fixtures.meters, "com.example.unlisted"])
        XCTAssertEqual(map.bundleIDs(in: .alwaysHidden), [Fixtures.chat])
    }
}

final class LayoutBackupTests: XCTestCase {
    func testRoundTrip() throws {
        let backup = LayoutBackup(createdAt: Date(timeIntervalSince1970: 1_800_000_000), systemBuild: "26B123", positions: Fixtures.positions)
        XCTAssertEqual(try LayoutBackup.decode(backup.encoded()), backup)
    }

    func testFileNameSortsChronologically() {
        let a = LayoutBackupPolicy.fileName(for: Date(timeIntervalSince1970: 1_800_000_000))
        let b = LayoutBackupPolicy.fileName(for: Date(timeIntervalSince1970: 1_800_000_000.5))
        XCTAssertEqual(a, "20270115-080000-000.json")
        XCTAssertLessThan(a, b)
        XCTAssertTrue(LayoutBackupPolicy.isBackupName(a))
    }

    func testPruneKeepsNewest() {
        let names = (0..<25).map { String(format: "20261113-1200%02d-000.json", $0) } + ["notes.txt", "keep.json"]
        let pruned = LayoutBackupPolicy.namesToPrune(names.shuffled(), keep: 20)
        XCTAssertEqual(pruned, (0..<5).map { String(format: "20261113-1200%02d-000.json", $0) })
        XCTAssertEqual(LayoutBackupPolicy.namesToPrune(Array(names.prefix(3))), [])
    }
}

final class ItemQueryTests: XCTestCase {
    let items = [
        Fixtures.item("status:com.example.chat::Item-0", bundle: Fixtures.chat, app: "Chat"),
        Fixtures.item("status:com.example.meters::CPU_mini", bundle: Fixtures.meters, app: "Meters", name: "Meters: CPU"),
        Fixtures.item("status:com.example.meters::RAM_mini", bundle: Fixtures.meters, app: "Meters", name: "Meters: RAM"),
        Fixtures.item("com.apple.menuextra.clock#0", bundle: "com.apple.controlcenter", app: "Control Center", name: "Clock",
                      apple: true, axID: "com.apple.menuextra.clock"),
        Fixtures.item("com.apple.menuextra.wifi#0", bundle: "com.apple.controlcenter", app: "Control Center", name: "Wi-Fi",
                      apple: true, axID: "com.apple.menuextra.wifi"),
    ]

    func testExactID() {
        XCTAssertEqual(try ItemQuery.find("status:com.example.meters::RAM_mini", in: items).get().displayName, "Meters: RAM")
    }

    func testBundleIDPicksFirstItemOfApp() {
        XCTAssertEqual(try ItemQuery.find("com.example.meters", in: items).get().displayName, "Meters: CPU")
    }

    func testAXIdentifier() {
        XCTAssertEqual(try ItemQuery.find("com.apple.menuextra.wifi", in: items).get().displayName, "Wi-Fi")
    }

    func testFuzzyName() {
        XCTAssertEqual(try ItemQuery.find("chat", in: items).get().ownerBundleID, Fixtures.chat)
        XCTAssertEqual(try ItemQuery.find("ram", in: items).get().displayName, "Meters: RAM")
        XCTAssertEqual(try ItemQuery.find("clock", in: items).get().displayName, "Clock")
    }

    func testAmbiguousAcrossAppsListsCandidates() {
        let more = items + [Fixtures.item("status:com.example.metro::Item-0", bundle: "com.example.metro", app: "Metro")]
        guard case let .failure(.ambiguous(_, candidates)) = ItemQuery.find("met", in: more) else {
            return XCTFail("expected ambiguity")
        }
        XCTAssertEqual(candidates.count, 3)
    }

    func testNotFound() {
        guard case .failure(.notFound("zzz")) = ItemQuery.find("zzz", in: items) else { return XCTFail() }
    }
}
