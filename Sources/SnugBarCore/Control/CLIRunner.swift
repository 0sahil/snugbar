import Foundation

/// Runs the `snugbar` command line: parses the arguments, sends the command to the running app's control server
/// and prints the answer. Exit status: 0 success, 1 the command failed, 2 usage error, 3 SnugBar not reachable.
public enum CLIRunner {
    public enum Exit {
        public static let ok: Int32 = 0
        public static let commandFailed: Int32 = 1
        public static let usage: Int32 = 2
        public static let unreachable: Int32 = 3
    }

    public enum TransportResult: Sendable {
        case response(status: Int, body: Data)
        /// Nothing listens on the port (or the connection broke before an answer).
        case unreachable(String)
        case failed(String)
    }

    public struct Context {
        public var arguments: [String]
        public var environment: [String: String]
        public var settingsURL: URL
        public var defaultTokenURL: URL
        public var write: (String) -> Void
        public var writeError: (String) -> Void
        /// Sends one request; replaceable in tests.
        public var send: (URLRequest) -> TransportResult

        public init(arguments: [String], environment: [String: String] = ProcessInfo.processInfo.environment,
                    settingsURL: URL = SettingsStore.defaultURL, defaultTokenURL: URL = TokenStore.defaultURL,
                    write: @escaping (String) -> Void = { FileHandle.standardOutput.write(Data($0.utf8)) },
                    writeError: @escaping (String) -> Void = { FileHandle.standardError.write(Data($0.utf8)) },
                    send: @escaping (URLRequest) -> TransportResult = CLIRunner.urlSessionSend) {
            self.arguments = arguments
            self.environment = environment
            self.settingsURL = settingsURL
            self.defaultTokenURL = defaultTokenURL
            self.write = write
            self.writeError = writeError
            self.send = send
        }
    }

    /// Request timeout. Opening a hidden item or moving one can take a couple of seconds.
    public static let timeout: TimeInterval = 30

    public static func run(_ context: Context) -> Int32 {
        let options: CLIOptions
        switch CLIParser.parse(context.arguments) {
        case let .failure(e):
            let help = e.command.map { "snugbar \($0.rawValue) --help" } ?? "snugbar --help"
            let usageLine = e.command.map { "Usage: \(CLIHelp.usage($0))\n" } ?? ""
            context.writeError("snugbar: \(e.message)\n\(usageLine)Run '\(help)' for more.\n")
            return Exit.usage
        case let .success(.help(command)):
            context.write(command.map(CLIHelp.command) ?? CLIHelp.general)
            return Exit.ok
        case let .success(.run(o)):
            options = o
        }

        let port = options.port ?? context.environment["SNUGBAR_PORT"].flatMap(Int.init) ?? configuredPort(context.settingsURL)
        let tokenURL = (options.tokenFile ?? context.environment["SNUGBAR_TOKEN_FILE"]).map { URL(fileURLWithPath: $0) }
            ?? context.defaultTokenURL
        let request = makeRequest(options.request, port: port, token: TokenStore(url: tokenURL).read())

        switch context.send(request) {
        case let .unreachable(why):
            context.writeError("""
                snugbar: can't reach SnugBar on 127.0.0.1:\(port) (\(why)).
                Make sure SnugBar is running and its control server is on (Settings > Control), and that the port matches.

                """)
            return Exit.unreachable
        case let .failed(why):
            context.writeError("snugbar: \(why)\n")
            return Exit.commandFailed
        case let .response(status, body):
            guard let response = try? JSONDecoder().decode(ControlResponse.self, from: body) else {
                context.writeError("snugbar: unexpected answer from 127.0.0.1:\(port) (HTTP \(status)); is SnugBar using this port?\n")
                return Exit.commandFailed
            }
            if options.json {
                context.write(String(decoding: body, as: UTF8.self) + (body.last == 0x0A ? "" : "\n"))
            } else {
                let output = CLIFormatter.format(response, for: options.request)
                if !output.stdout.isEmpty { context.write(output.stdout) }
                if !output.stderr.isEmpty { context.writeError(output.stderr) }
            }
            return response.ok ? Exit.ok : Exit.commandFailed
        }
    }

    /// The port from SnugBar's settings file, else the default.
    static func configuredPort(_ url: URL) -> Int {
        guard let data = try? Data(contentsOf: url), let settings = try? SettingsStore.decode(data) else {
            return ControlServerSettings.defaultPort
        }
        return settings.controlServer.effectivePort
    }

    public static func makeRequest(_ request: ControlRequest, port: Int, token: String?) -> URLRequest {
        var r = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/v1/\(request.command.rawValue)")!)
        r.httpMethod = "POST"
        r.timeoutInterval = timeout
        r.setValue("application/json", forHTTPHeaderField: "Content-Type")
        r.setValue("application/json", forHTTPHeaderField: "Accept")
        if let token { r.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        r.httpBody = try? encoder.encode(request.arguments)
        return r
    }

    /// Sends with URLSession and waits for the answer.
    public static func urlSessionSend(_ request: URLRequest) -> TransportResult {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.connectionProxyDictionary = [:]
        configuration.timeoutIntervalForRequest = timeout
        configuration.waitsForConnectivity = false
        let session = URLSession(configuration: configuration)
        defer { session.finishTasksAndInvalidate() }
        let done = DispatchSemaphore(value: 0)
        let box = ResultBox()
        session.dataTask(with: request) { data, response, error in
            if let error = error as? URLError {
                switch error.code {
                case .cannotConnectToHost, .networkConnectionLost, .cannotFindHost, .notConnectedToInternet:
                    box.value = .unreachable(error.code == .cannotConnectToHost ? "connection refused" : error.localizedDescription)
                case .timedOut:
                    box.value = .failed("SnugBar didn't answer within \(Int(timeout)) seconds")
                default:
                    box.value = .failed(error.localizedDescription)
                }
            } else if let error {
                box.value = .failed(error.localizedDescription)
            } else {
                box.value = .response(status: (response as? HTTPURLResponse)?.statusCode ?? 0, body: data ?? Data())
            }
            done.signal()
        }.resume()
        done.wait()
        return box.value ?? .failed("no answer")
    }

    private final class ResultBox: @unchecked Sendable {
        var value: TransportResult?
    }
}
