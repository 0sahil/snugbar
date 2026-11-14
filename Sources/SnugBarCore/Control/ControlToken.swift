import Foundation

/// The optional access token for the control server (feature 73).
public enum ControlToken {
    /// 32 random bytes, base64url without padding (43 characters).
    public static func generate() -> String {
        // SystemRandomNumberGenerator is a cryptographically secure generator on Apple platforms.
        var rng = SystemRandomNumberGenerator()
        let bytes = (0..<32).map { _ in UInt8.random(in: .min ... .max, using: &rng) }
        return base64URL(Data(bytes))
    }

    public static func base64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    /// Compares in time that doesn't depend on where the strings differ.
    public static func constantTimeEquals(_ a: String, _ b: String) -> Bool {
        let x = Array(a.utf8), y = Array(b.utf8)
        var diff = UInt8(x.count == y.count ? 0 : 1)
        let n = max(x.count, y.count)
        for i in 0..<n {
            let p = i < x.count ? x[i] : 0
            let q = i < y.count ? y[i] : 0
            diff |= p ^ q
        }
        return diff == 0
    }

    /// The token in an `Authorization: Bearer <token>` header value, or nil.
    public static func bearer(fromAuthorization header: String?) -> String? {
        guard let header = header?.trimmingCharacters(in: .whitespaces) else { return nil }
        let parts = header.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
        guard parts.count == 2, parts[0].caseInsensitiveCompare("Bearer") == .orderedSame else { return nil }
        let token = parts[1].trimmingCharacters(in: .whitespaces)
        return token.isEmpty ? nil : token
    }

    /// True when the header carries `expected`.
    public static func authorizes(_ header: String?, expected: String) -> Bool {
        guard !expected.isEmpty, let given = bearer(fromAuthorization: header) else { return false }
        return constantTimeEquals(given, expected)
    }
}

/// Reads and writes the token file (`~/Library/Application Support/SnugBar/token`, mode 0600).
public struct TokenStore: Sendable {
    public let url: URL

    public init(url: URL = TokenStore.defaultURL) {
        self.url = url
    }

    public static var defaultURL: URL {
        SnugBarPaths.applicationSupport.appendingPathComponent("token")
    }

    /// The token, or nil when the file is missing or empty.
    public func read() -> String? {
        guard let data = try? Data(contentsOf: url),
              let text = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !text.isEmpty
        else { return nil }
        return text
    }

    /// The existing token, or a new one written to the file. Tightens the file's mode to 0600 if needed.
    @discardableResult
    public func ensure() throws -> String {
        if let token = read() {
            _ = chmod(url.path, 0o600)
            return token
        }
        return try regenerate()
    }

    /// Writes a new token, replacing any old one.
    @discardableResult
    public func regenerate() throws -> String {
        let token = ControlToken.generate()
        try write(token)
        return token
    }

    /// Writes to a temporary file created with mode 0600, then renames it over the token file.
    public func write(_ token: String) throws {
        let dir = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let temp = dir.appendingPathComponent(".token.\(UUID().uuidString).tmp")
        let fd = open(temp.path, O_WRONLY | O_CREAT | O_EXCL, 0o600)
        guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        let bytes = Array((token + "\n").utf8)
        let written = bytes.withUnsafeBytes { Foundation.write(fd, $0.baseAddress, $0.count) }
        let syncFailed = fsync(fd) != 0
        close(fd)
        guard written == bytes.count, !syncFailed, rename(temp.path, url.path) == 0 else {
            let code = POSIXErrorCode(rawValue: errno) ?? .EIO
            unlink(temp.path)
            throw POSIXError(code)
        }
    }
}
