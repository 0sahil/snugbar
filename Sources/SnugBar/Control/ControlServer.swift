import Foundation
import Network
import SnugBarCore

/// The control server: HTTP/1.1 on 127.0.0.1 only, answering through `ControlHTTPHandler`.
///
/// Connections are handled on one serial queue; each request is answered on the main actor. Requests on one
/// connection are answered in order (keep-alive and pipelining work). A request must arrive completely within
/// `requestTimeout`; idle keep-alive connections close after `idleTimeout`.
@MainActor
final class ControlServer {
    enum State: Equatable {
        case off
        case starting(port: Int)
        case listening(port: Int)
        case failed(port: Int, message: String)

        var port: Int? {
            switch self {
            case .off: return nil
            case let .starting(p), let .listening(p), let .failed(p, _): return p
            }
        }
    }

    private(set) var state: State = .off {
        didSet { if state != oldValue { onStateChange?(state) } }
    }
    var onStateChange: ((State) -> Void)?
    /// One line per answered request ("POST /v1/list 200"), for the debug harness.
    var onRequest: ((String) -> Void)?

    private let handler: ControlHTTPHandler
    private let queue = DispatchQueue(label: "app.snugbar.control-server")
    private var listener: NWListener?
    private let pool: ConnectionPool

    init(handler: ControlHTTPHandler) {
        self.handler = handler
        pool = ConnectionPool(queue: queue)
    }

    /// Starts listening on 127.0.0.1:`port`, replacing a running listener.
    func start(port: Int) {
        stop()
        guard (1...65535).contains(port), let nwPort = NWEndpoint.Port(rawValue: UInt16(port)) else {
            state = .failed(port: port, message: "Port \(port) is not a valid port.")
            return
        }
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: nwPort)
        parameters.acceptLocalOnly = true
        let listener: NWListener
        do {
            listener = try NWListener(using: parameters)
        } catch {
            state = .failed(port: port, message: Self.describe(error, port: port))
            return
        }
        self.listener = listener
        state = .starting(port: port)

        let handler = self.handler
        let respond: ConnectionPool.Respond = { request in await handler.respond(to: request) }
        let log: @Sendable (String) -> Void = { [weak self] line in
            Task { @MainActor in self?.onRequest?(line) }
        }
        listener.newConnectionHandler = { [pool] connection in
            pool.accept(connection, respond: respond, log: log)
        }
        listener.stateUpdateHandler = { [weak self, weak listener] newState in
            Task { @MainActor in
                guard let self, let listener, self.listener === listener else { return }
                switch newState {
                case .ready:
                    self.state = .listening(port: port)
                case let .failed(error), let .waiting(error):
                    // `waiting` means the address can't be bound now (usually: the port is in use). Don't wait for it.
                    listener.cancel()
                    self.listener = nil
                    self.state = .failed(port: port, message: Self.describe(error, port: port))
                    NSLog("SnugBar: control server not started on port %d: %@", port, String(describing: error))
                default:
                    break
                }
            }
        }
        listener.start(queue: queue)
    }

    func stop() {
        listener?.stateUpdateHandler = nil
        listener?.newConnectionHandler = nil
        listener?.cancel()
        listener = nil
        pool.closeAll()
        state = .off
    }

    private static func describe(_ error: Error, port: Int) -> String {
        if case let .posix(code) = error as? NWError, code == .EADDRINUSE {
            return "Port \(port) is in use by another app. Choose another port."
        }
        if case let .posix(code) = error as? NWError, code == .EACCES {
            return "SnugBar isn't allowed to use port \(port). Choose another port."
        }
        return "The control server couldn't start on port \(port): \(error.localizedDescription)"
    }
}

/// Open connections. Only touched on the server queue.
final class ConnectionPool: @unchecked Sendable {
    typealias Respond = @Sendable (HTTPRequest) async -> HTTPResponse

    static let maxConnections = 16

    private let queue: DispatchQueue
    private var connections: [ObjectIdentifier: HTTPConnection] = [:]

    init(queue: DispatchQueue) {
        self.queue = queue
    }

    /// Called on the queue by the listener.
    func accept(_ nw: NWConnection, respond: @escaping Respond, log: @escaping @Sendable (String) -> Void) {
        guard connections.count < Self.maxConnections else {
            nw.cancel()
            return
        }
        let connection = HTTPConnection(nw, queue: queue, respond: respond, log: log)
        let id = ObjectIdentifier(connection)
        connections[id] = connection
        connection.onClose = { [weak self] in self?.connections.removeValue(forKey: id) }
        connection.start()
    }

    func closeAll() {
        queue.async {
            let all = Array(self.connections.values)
            self.connections = [:]
            all.forEach { $0.close() }
        }
    }
}

/// One client connection. Only touched on the server queue.
final class HTTPConnection: @unchecked Sendable {
    static let requestTimeout: TimeInterval = 10
    static let idleTimeout: TimeInterval = 30

    var onClose: (() -> Void)?

    private let nw: NWConnection
    private let queue: DispatchQueue
    private let respond: ConnectionPool.Respond
    private let log: @Sendable (String) -> Void
    private var buffer = Data()
    private var busy = false
    private var closed = false
    private var peerFinished = false
    /// When the first byte of the request being received arrived.
    private var requestStarted: Date?
    private var lastActivity = Date()
    private var timer: DispatchSourceTimer?

    init(_ nw: NWConnection, queue: DispatchQueue, respond: @escaping ConnectionPool.Respond, log: @escaping @Sendable (String) -> Void) {
        self.nw = nw
        self.queue = queue
        self.respond = respond
        self.log = log
    }

    func start() {
        nw.stateUpdateHandler = { [weak self] state in
            switch state {
            case .failed, .cancelled: self?.close()
            default: break
            }
        }
        nw.start(queue: queue)
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 1, repeating: 1)
        timer.setEventHandler { [weak self] in self?.checkTimeouts() }
        timer.resume()
        self.timer = timer
        receive()
    }

    func close() {
        guard !closed else { return }
        closed = true
        timer?.cancel()
        timer = nil
        nw.cancel()
        onClose?()
        onClose = nil
    }

    private func receive() {
        guard !closed, !busy, !peerFinished else { return }
        nw.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, isComplete, error in
            guard let self, !self.closed else { return }
            if let data, !data.isEmpty {
                if self.buffer.isEmpty { self.requestStarted = Date() }
                self.buffer.append(data)
                self.lastActivity = Date()
            }
            if error != nil { self.close(); return }
            if isComplete { self.peerFinished = true }
            self.processBuffer()
        }
    }

    /// Answers the next complete request in the buffer, or reads more.
    private func processBuffer() {
        guard !closed, !busy else { return }
        if buffer.isEmpty {
            if peerFinished { close() } else { receive() }
            return
        }
        switch HTTPRequestParser.parse(buffer) {
        case .incomplete:
            if peerFinished { close() } else { receive() }
        case let .invalid(error):
            let code: ControlErrorCode = error == .payloadTooLarge ? .payloadTooLarge : .badRequest
            var response = ControlHTTPHandler.error(ControlError(code, error.message))
            response.status = error.status
            send(response, keepAlive: false, summary: "invalid request \(error.status)")
        case let .complete(request, consumed):
            buffer.removeFirst(consumed)
            requestStarted = buffer.isEmpty ? nil : Date()
            busy = true
            let respond = self.respond
            Task {
                let response = await respond(request)
                self.queue.async {
                    self.busy = false
                    self.send(response, keepAlive: request.keepAlive && !self.peerFinished,
                              summary: "\(request.method) \(request.path) \(response.status)")
                }
            }
        }
    }

    private func send(_ response: HTTPResponse, keepAlive: Bool, summary: String) {
        guard !closed else { return }
        log(summary)
        busy = true
        nw.send(content: response.serialized(keepAlive: keepAlive), completion: .contentProcessed { [weak self] error in
            guard let self else { return }
            self.busy = false
            self.lastActivity = Date()
            if error != nil || !keepAlive {
                self.close()
            } else {
                self.processBuffer()
            }
        })
    }

    private func checkTimeouts() {
        guard !closed, !busy else { return }
        let now = Date()
        if let started = requestStarted, now.timeIntervalSince(started) > Self.requestTimeout {
            var response = ControlHTTPHandler.error(ControlError(.timeout, "the request didn't arrive completely within \(Int(Self.requestTimeout)) seconds"))
            response.status = 408
            send(response, keepAlive: false, summary: "timeout 408")
        } else if buffer.isEmpty, now.timeIntervalSince(lastActivity) > Self.idleTimeout {
            close()
        }
    }
}
