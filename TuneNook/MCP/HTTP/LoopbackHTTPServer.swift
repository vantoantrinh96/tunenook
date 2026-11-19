import Foundation
import MCP
import Network
import os

/// A tiny HTTP/1.1 server bound to IPv4 loopback only. One request per connection, then close.
/// Headers and bodies are never logged: they carry the bearer token.
final class LoopbackHTTPServer: Sendable {
    enum StartError: Error, Equatable {
        case portInUse
        case failed(String)
    }

    private struct State {
        var listener: NWListener?
        var connections: [ObjectIdentifier: NWConnection] = [:]
        var stopped = false
    }

    /// Simultaneous connections served; extras are closed immediately.
    static let maxConnections = 16

    private let port: UInt16
    private let idleTimeout: TimeInterval
    private let handler: @Sendable (HTTPRequest) async -> HTTPResponse
    private let queue = DispatchQueue(label: "tunenook.mcp.http")
    private let listenerClosed = DispatchSemaphore(value: 0)
    private let state = OSAllocatedUnfairLock(initialState: State())

    init(
        port: UInt16,
        idleTimeout: TimeInterval = 10,
        handler: @escaping @Sendable (HTTPRequest) async -> HTTPResponse
    ) {
        self.port = port
        self.idleTimeout = idleTimeout
        self.handler = handler
    }

    /// The local endpoint the listener is required to bind to (always 127.0.0.1).
    var localEndpoint: NWEndpoint? {
        state.withLock { $0.listener?.parameters.requiredLocalEndpoint }
    }

    /// Returns once the listener is ready. Throws `StartError`.
    func start() async throws {
        guard let nwPort = NWEndpoint.Port(rawValue: port) else { throw StartError.failed("invalid port") }
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: nwPort)
        parameters.allowLocalEndpointReuse = true

        let listener: NWListener
        do {
            listener = try NWListener(using: parameters)
        } catch {
            throw Self.map(error)
        }
        let accepted: Bool = state.withLock {
            guard !$0.stopped, $0.listener == nil else { return false }
            $0.listener = listener
            return true
        }
        guard accepted else { throw StartError.failed("already started or stopped") }

        listener.newConnectionHandler = { [weak self] connection in
            self?.accept(connection)
        }
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            let once = OSAllocatedUnfairLock(initialState: false)
            let resume: @Sendable (Result<Void, Error>) -> Void = { result in
                let first = once.withLock { done -> Bool in
                    defer { done = true }
                    return !done
                }
                if first { cont.resume(with: result) }
            }
            listener.stateUpdateHandler = { [listenerClosed] newState in
                switch newState {
                case .ready: resume(.success(()))
                case .failed(let error): resume(.failure(Self.map(error)))
                case .cancelled:
                    resume(.failure(StartError.failed("cancelled")))
                    listenerClosed.signal()
                default: break
                }
            }
            listener.start(queue: queue)
        }
    }

    func stop() {
        let (listener, connections): (NWListener?, [NWConnection]) = state.withLock {
            $0.stopped = true
            let result = ($0.listener, Array($0.connections.values))
            $0.listener = nil
            $0.connections.removeAll()
            return result
        }
        if let listener {
            listener.cancel()
            // Wait for the socket to actually close so the port is reusable when stop() returns.
            _ = listenerClosed.wait(timeout: .now() + 1)
        }
        connections.forEach { $0.cancel() }
    }

    private static func map(_ error: Error) -> StartError {
        if let nw = error as? NWError, case .posix(let code) = nw, code == .EADDRINUSE {
            return .portInUse
        }
        return .failed(String(describing: error))
    }

    // MARK: - Connections

    private func accept(_ connection: NWConnection) {
        let id = ObjectIdentifier(connection)
        let keep: Bool = state.withLock {
            guard !$0.stopped, $0.connections.count < Self.maxConnections else { return false }
            $0.connections[id] = connection
            return true
        }
        guard keep else {
            connection.cancel()
            return
        }
        connection.stateUpdateHandler = { [weak self] newState in
            switch newState {
            case .failed, .cancelled:
                self?.state.withLock { _ = $0.connections.removeValue(forKey: id) }
            default: break
            }
        }
        let idle = IdleTimer { connection.cancel() }
        queue.asyncAfter(deadline: .now() + idleTimeout, execute: idle.item)
        connection.start(queue: queue)
        receive(on: connection, buffer: Data(), head: nil, scanned: 0, idle: idle)
    }

    /// All callbacks run on `queue`, which serialises access to `buffer`.
    private func receive(on connection: NWConnection, buffer: Data, head: HTTPMessage.Head?, scanned: Int, idle: IdleTimer) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            if error != nil {
                idle.cancel()
                connection.cancel()
                return
            }
            var buffer = buffer
            if let data { buffer.append(data) }
            var head = head
            if head == nil {
                switch HTTPMessage.parseHead(buffer, searchFrom: scanned) {
                case .failure(let status):
                    idle.cancel()
                    self.reply(HTTPMessage.serialize(status: status), on: connection)
                    return
                case .head(let parsed): head = parsed
                case .incomplete:
                    if isComplete {
                        idle.cancel()
                        connection.cancel()
                    } else {
                        // The terminator may straddle reads: rescan the last 3 bytes next time.
                        self.receive(on: connection, buffer: buffer, head: nil, scanned: max(0, buffer.count - 3), idle: idle)
                    }
                    return
                }
            }
            if let head, let request = head.request(from: buffer) {
                // A complete request is in hand; the handler may legitimately take longer than the idle limit.
                idle.cancel()
                let handler = self.handler
                Task {
                    let response = await handler(request)
                    self.reply(HTTPMessage.serialize(response), on: connection)
                }
            } else if isComplete {
                idle.cancel()
                connection.cancel()
            } else {
                self.receive(on: connection, buffer: buffer, head: head, scanned: scanned, idle: idle)
            }
        }
    }

    private func reply(_ data: Data, on connection: NWConnection) {
        connection.send(content: data, contentContext: .finalMessage, isComplete: true, completion: .contentProcessed { _ in
            connection.cancel()
        })
    }
}

/// Wraps the idle-timeout work item so it can be captured by the receive callbacks.
private final class IdleTimer: @unchecked Sendable {
    let item: DispatchWorkItem
    init(_ onFire: @escaping @Sendable () -> Void) { item = DispatchWorkItem(block: onFire) }
    func cancel() { item.cancel() }
}
