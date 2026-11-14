import Foundation

/// Moving several apps to a section in one step, as the Settings > Sections list does with its selection.
public enum BulkSectionMove {
    /// The "Move To…" command's title: plain for one app, with the count for several ("Move 3 Apps To…").
    public static func title(count: Int) -> String {
        count > 1 ? "Move \(count) Apps To…" : "Move To…"
    }

    /// The same wording as a submenu title, which takes no ellipsis: "Move To", "Move 3 Apps To".
    public static func submenuTitle(count: Int) -> String {
        count > 1 ? "Move \(count) Apps To" : "Move To"
    }

    /// The selected apps in list order, leaving out any that are no longer listed.
    public static func targets(selection: Set<String>, rows: [String]) -> [String] {
        guard !selection.isEmpty else { return [] }
        var seen = Set<String>()
        return rows.filter { selection.contains($0) && seen.insert($0).inserted }
    }
}
