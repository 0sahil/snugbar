import Foundation

/// Fixed facts about SnugBar shown in the About panel, the README and `snugbar --version`.
public enum ProjectInfo {
    public static let name = "SnugBar"
    public static let summary = "A menu bar manager for macOS, with search, a command line and an MCP server."
    /// Who owns and maintains the project. The README carries the same sentence.
    public static let ownership = "SnugBar is an independent open-source project, created and maintained by 0sahil. It is not affiliated with Apple."
    public static let license = "MIT License"
    public static let repositoryURL = URL(string: "https://github.com/0sahil/snugbar")!

    /// "1.0.0 (42)", or "1.0.0" without a build number, or "dev" outside an app bundle.
    public static func versionString(short: String?, build: String?) -> String {
        guard let short, !short.isEmpty else { return "dev" }
        guard let build, !build.isEmpty, build != short else { return short }
        return "\(short) (\(build))"
    }

    /// The version of the app bundle an executable lives in (`Contents/MacOS/…` or `Contents/Helpers/…`), read from
    /// the bundle's Info.plist. Symbolic links are resolved first, so a `snugbar` link in PATH finds its app.
    public static func bundleVersion(forExecutable executable: URL) -> String {
        let resolved = executable.resolvingSymlinksInPath()
        let parent = resolved.deletingLastPathComponent()
        let contents = parent.deletingLastPathComponent()
        guard ["MacOS", "Helpers"].contains(parent.lastPathComponent), contents.lastPathComponent == "Contents",
              let data = try? Data(contentsOf: contents.appendingPathComponent("Info.plist")),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        else { return versionString(short: nil, build: nil) }
        return versionString(short: plist["CFBundleShortVersionString"] as? String, build: plist["CFBundleVersion"] as? String)
    }

    /// The running executable's bundle version.
    public static var currentExecutableVersion: String {
        let path = Bundle.main.executableURL ?? URL(fileURLWithPath: CommandLine.arguments.first ?? "")
        return bundleVersion(forExecutable: path)
    }
}
