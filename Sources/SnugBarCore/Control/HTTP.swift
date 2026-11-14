import Foundation

/// Header fields in arrival order, looked up case-insensitively.
public struct HTTPHeaders: Equatable, Sendable {
    public private(set) var fields: [(name: String, value: String)]

    public init(_ fields: [(name: String, value: String)] = []) {
        self.fields = fields
    }

    /// The first value of a header.
    public subscript(name: String) -> String? {
        fields.first { $0.name.caseInsensitiveCompare(name) == .orderedSame }?.value
    }

    public func values(_ name: String) -> [String] {
        fields.filter { $0.name.caseInsensitiveCompare(name) == .orderedSame }.map(\.value)
    }

    public mutating func add(_ name: String, _ value: String) {
        fields.append((name, value))
    }

    public static func == (a: HTTPHeaders, b: HTTPHeaders) -> Bool {
        a.fields.count == b.fields.count && zip(a.fields, b.fields).allSatisfy { $0.name == $1.name && $0.value == $1.value }
    }
}

public struct HTTPRequest: Equatable, Sendable {
    public var method: String
    /// The request target as sent (`/v1/list?x=1`).
    public var target: String
    /// The target without its query.
    public var path: String
    public var version: String
    public var headers: HTTPHeaders
    public var body: Data

    public init(method: String, target: String, version: String = "HTTP/1.1", headers: HTTPHeaders = HTTPHeaders(), body: Data = Data()) {
        self.method = method
        self.target = target
        self.path = String(target.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false).first ?? "")
        self.version = version
        self.headers = headers
        self.body = body
    }

    /// Whether the connection stays open after the response (HTTP/1.1 unless `Connection: close`; HTTP/1.0 only with
    /// `Connection: keep-alive`).
    public var keepAlive: Bool {
        let tokens = headers.values("Connection").flatMap { $0.lowercased().split(separator: ",") }
            .map { $0.trimmingCharacters(in: .whitespaces) }
        if tokens.contains("close") { return false }
        if version == "HTTP/1.0" { return tokens.contains("keep-alive") }
        return true
    }
}

public struct HTTPLimits: Sendable {
    /// Request line and headers together.
    public var maxHeaderBytes: Int
    public var maxBodyBytes: Int
    public var maxHeaderCount: Int

    public init(maxHeaderBytes: Int = 16 * 1024, maxBodyBytes: Int = 256 * 1024, maxHeaderCount: Int = 64) {
        self.maxHeaderBytes = maxHeaderBytes
        self.maxBodyBytes = maxBodyBytes
        self.maxHeaderCount = maxHeaderCount
    }

    public static let standard = HTTPLimits()
}

public enum HTTPParseError: Error, Equatable, Sendable {
    case badRequest(String)
    case headersTooLarge
    case payloadTooLarge
    case notImplemented(String)
    case versionNotSupported

    public var status: Int {
        switch self {
        case .badRequest: return 400
        case .headersTooLarge: return 431
        case .payloadTooLarge: return 413
        case .notImplemented: return 501
        case .versionNotSupported: return 505
        }
    }

    public var message: String {
        switch self {
        case let .badRequest(why): return "bad request: \(why)"
        case .headersTooLarge: return "request headers are too large"
        case .payloadTooLarge: return "request body is too large"
        case let .notImplemented(what): return "\(what) is not supported"
        case .versionNotSupported: return "only HTTP/1.1 and HTTP/1.0 are supported"
        }
    }
}

/// Parses HTTP/1.1 requests from a byte buffer that grows as data arrives. Strict: CRLF line endings, no folded
/// headers, `Content-Length` bodies only (no chunked transfer coding).
public enum HTTPRequestParser {
    public enum Result: Equatable, Sendable {
        /// More bytes are needed.
        case incomplete
        /// A whole request, and how many bytes of the buffer it used (the rest may be the next request).
        case complete(HTTPRequest, consumed: Int)
        case invalid(HTTPParseError)
    }

    private static let crlfcrlf = Data("\r\n\r\n".utf8)

    public static func parse(_ buffer: Data, limits: HTTPLimits = .standard) -> Result {
        let bytes = [UInt8](buffer)
        guard let headerEnd = find(crlfcrlf, in: bytes, limit: limits.maxHeaderBytes + 4) else {
            if bytes.count > limits.maxHeaderBytes { return .invalid(.headersTooLarge) }
            // Reject garbage early instead of waiting for a blank line that never comes.
            if let firstLineEnd = bytes.firstIndex(of: 0x0A), case let .failure(e) = requestLine(bytes[..<firstLineEnd]) {
                return .invalid(e)
            }
            return .incomplete
        }
        guard headerEnd <= limits.maxHeaderBytes else { return .invalid(.headersTooLarge) }
        guard let head = String(bytes: bytes[..<headerEnd], encoding: .utf8) else {
            return .invalid(.badRequest("headers are not UTF-8"))
        }
        var lines = head.components(separatedBy: "\r\n")
        let first = lines.removeFirst()
        let method: String, target: String, version: String
        switch requestLine(Array(first.utf8)[...]) {
        case let .success(parts): (method, target, version) = parts
        case let .failure(e): return .invalid(e)
        }

        var headers = HTTPHeaders()
        for line in lines {
            guard headers.fields.count < limits.maxHeaderCount else { return .invalid(.headersTooLarge) }
            guard let first = line.first else { return .invalid(.badRequest("empty header line")) }
            if first == " " || first == "\t" { return .invalid(.badRequest("folded headers are not allowed")) }
            guard let colon = line.firstIndex(of: ":") else { return .invalid(.badRequest("header without a colon")) }
            let name = String(line[..<colon])
            guard !name.isEmpty, name.allSatisfy(isTokenChar) else { return .invalid(.badRequest("invalid header name")) }
            let value = line[line.index(after: colon)...].trimmingCharacters(in: CharacterSet(charactersIn: " \t"))
            guard !value.contains(where: { $0 == "\r" || $0 == "\n" || $0 == "\0" }) else {
                return .invalid(.badRequest("invalid header value"))
            }
            headers.add(name, value)
        }

        if !headers.values("Transfer-Encoding").isEmpty { return .invalid(.notImplemented("Transfer-Encoding")) }
        if version == "HTTP/1.1" {
            let hosts = headers.values("Host")
            guard hosts.count == 1 else { return .invalid(.badRequest(hosts.isEmpty ? "missing Host header" : "several Host headers")) }
        }
        let lengths = Set(headers.values("Content-Length").flatMap { $0.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) } })
        var length = 0
        if !lengths.isEmpty {
            guard lengths.count == 1, let text = lengths.first, !text.isEmpty, text.count <= 12,
                  text.allSatisfy({ $0.isASCII && $0.isNumber }), let n = Int(text)
            else { return .invalid(.badRequest("invalid Content-Length")) }
            length = n
        }
        guard length <= limits.maxBodyBytes else { return .invalid(.payloadTooLarge) }

        let bodyStart = headerEnd + 4
        guard bytes.count >= bodyStart + length else { return .incomplete }
        let body = Data(bytes[bodyStart..<(bodyStart + length)])
        let request = HTTPRequest(method: method, target: target, version: version, headers: headers, body: body)
        return .complete(request, consumed: bodyStart + length)
    }

    private static func requestLine(_ line: ArraySlice<UInt8>) -> Swift.Result<(String, String, String), HTTPParseError> {
        var raw = Array(line)
        if raw.last == 0x0D { raw.removeLast() }
        guard let text = String(bytes: raw, encoding: .utf8) else { return .failure(.badRequest("request line is not UTF-8")) }
        let parts = text.split(separator: " ", omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 3, !parts[0].isEmpty, parts[0].allSatisfy(isTokenChar) else {
            return .failure(.badRequest("malformed request line"))
        }
        let target = parts[1]
        guard target.hasPrefix("/"), target.count <= 2048, !target.contains(where: { $0.isWhitespace || !$0.isASCII }) else {
            return .failure(.badRequest("malformed request target"))
        }
        guard parts[2].hasPrefix("HTTP/") else { return .failure(.badRequest("malformed HTTP version")) }
        guard parts[2] == "HTTP/1.1" || parts[2] == "HTTP/1.0" else { return .failure(.versionNotSupported) }
        return .success((parts[0], target, parts[2]))
    }

    private static func isTokenChar(_ c: Character) -> Bool {
        guard c.isASCII, let v = c.asciiValue, v > 32, v < 127 else { return false }
        return !"()<>@,;:\\\"/[]?={}".contains(c)
    }

    /// Index of the first occurrence of `needle`, looking at most `limit` bytes into `haystack`.
    private static func find(_ needle: Data, in haystack: [UInt8], limit: Int) -> Int? {
        let n = [UInt8](needle)
        let end = min(haystack.count, limit) - n.count
        guard end >= 0 else { return nil }
        var i = 0
        while i <= end {
            if haystack[i] == n[0], Array(haystack[i..<(i + n.count)]) == n { return i }
            i += 1
        }
        return nil
    }
}

public struct HTTPResponse: Equatable, Sendable {
    public var status: Int
    public var headers: HTTPHeaders
    public var body: Data

    public init(status: Int, headers: HTTPHeaders = HTTPHeaders(), body: Data = Data()) {
        self.status = status
        self.headers = headers
        self.body = body
    }

    public static func json(_ status: Int, _ body: Data) -> HTTPResponse {
        var h = HTTPHeaders()
        h.add("Content-Type", "application/json; charset=utf-8")
        return HTTPResponse(status: status, headers: h, body: body)
    }

    /// The response bytes, with `Content-Length`, `Connection` and `Cache-Control` added.
    public func serialized(keepAlive: Bool) -> Data {
        var text = "HTTP/1.1 \(status) \(Self.reason(status))\r\n"
        for field in headers.fields { text += "\(field.name): \(field.value)\r\n" }
        text += "Content-Length: \(body.count)\r\n"
        text += "Cache-Control: no-store\r\n"
        text += "Connection: \(keepAlive ? "keep-alive" : "close")\r\n\r\n"
        var data = Data(text.utf8)
        data.append(body)
        return data
    }

    public static func reason(_ status: Int) -> String {
        switch status {
        case 200: return "OK"
        case 202: return "Accepted"
        case 204: return "No Content"
        case 400: return "Bad Request"
        case 401: return "Unauthorized"
        case 403: return "Forbidden"
        case 404: return "Not Found"
        case 405: return "Method Not Allowed"
        case 408: return "Request Timeout"
        case 409: return "Conflict"
        case 413: return "Content Too Large"
        case 415: return "Unsupported Media Type"
        case 431: return "Request Header Fields Too Large"
        case 500: return "Internal Server Error"
        case 501: return "Not Implemented"
        case 503: return "Service Unavailable"
        case 505: return "HTTP Version Not Supported"
        default: return "Status \(status)"
        }
    }
}
