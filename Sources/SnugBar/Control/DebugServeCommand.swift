import Foundation
import SnugBarCore

/// `serve --fake --port <N> [--seconds <S>] [--token-file <path>]`: runs the real HTTP/MCP server on 127.0.0.1:N
/// for S seconds (default 30) with an in-memory engine (made-up items, no Accessibility, no hiding, no menu bar
/// changes), then writes a log of the requests and of what the fake engine was asked to do. With `--token-file`,
/// every request needs the token in that file (created when missing).
extension DebugRunner {
    struct ServeResult: Encodable {
        var port: Int
        var seconds: Double
        var engine: String
        var tokenFile: String?
        var requests: [String]
        var engineActions: [String]
    }

    private final class Log {
        var lines: [String] = []
    }

    func serve() async throws -> ServeResult {
        guard invocation.arguments.contains("--fake") else {
            throw Failure("serve needs --fake: a second live instance would fight the running SnugBar over the menu bar")
        }
        guard let text = invocation.value(after: "--port"), let port = Int(text), ControlServerSettings.portRange.contains(port) else {
            throw Failure("usage: serve --fake --port <1024-65535> [--seconds <S>] [--token-file <path>]")
        }
        let seconds = min(max(Double(invocation.value(after: "--seconds") ?? "30") ?? 30, 1), 3600)
        let tokenFile = invocation.value(after: "--token-file")
        var token: String?
        if let tokenFile {
            token = try TokenStore(url: URL(fileURLWithPath: tokenFile)).ensure()
        }

        let engine = InMemoryControlEngine.demo(version: AppInfo.version, port: port, tokenRequired: token != nil)
        let handler = ControlHTTPHandler(router: CommandRouter(engine: engine), serverVersion: AppInfo.version) {
            .init(port: port, requiredToken: token)
        }
        let server = ControlServer(handler: handler)
        let log = Log()
        server.onRequest = { log.lines.append($0) }
        server.start(port: port)

        let deadline = Date().addingTimeInterval(3)
        while Date() < deadline, case .starting = server.state {
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        switch server.state {
        case .listening:
            FileHandle.standardError.write(Data("serving the fake engine on 127.0.0.1:\(port) for \(Int(seconds)) s\n".utf8))
        case let .failed(_, message):
            throw Failure(message)
        default:
            server.stop()
            throw Failure("the server didn't start within 3 s (state: \(server.state))")
        }
        try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
        server.stop()
        return ServeResult(port: port, seconds: seconds, engine: "fake (in-memory demo items)", tokenFile: tokenFile,
                           requests: log.lines, engineActions: engine.actions)
    }
}
