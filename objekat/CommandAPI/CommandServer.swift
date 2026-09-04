import Foundation
import Network

/// Command server: a UNIX socket, a JSON-lines protocol (one JSON request per line, one JSON
/// response per line), several clients at once.
///
/// WHY EVERYTHING RUNS ON THE MAIN QUEUE — the listener and the connections get their callbacks
/// on `DispatchQueue.main`. This is not laziness: every command has to run on the `@MainActor`
/// anyway (it touches the model and the engine), the useful throughput is a few messages per
/// second, and making that choice removes every question of a race on the receive buffer at a
/// stroke. The only real cost would be serialising a very large `project.get_state` — which,
/// reading the model, has to happen there in any case.
@MainActor
final class CommandServer {

    static let shared = CommandServer()

    /// `~/Library/Application Support/Objekat/objekat.sock`. The app is not sandboxed, so there is
    /// no app group and no container to plan for.
    ///
    /// `nonisolated` BECAUSE this is the default value of `start(socketPath:)`: a default value is
    /// evaluated at the call site, hence outside the class's `@MainActor`. These two members only
    /// read `FileManager` and no actor state — taking them out of the isolation costs nothing and
    /// saves anyone who only wants to know the path from having to hop queues.
    nonisolated static var defaultSocketPath: String {
        supportDirectory().appendingPathComponent("objekat.sock").path
    }

    nonisolated static func supportDirectory() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent("Objekat", isDirectory: true)
    }

    private var listener: NWListener?
    private var connections: [ObjectIdentifier: Connection] = [:]
    private(set) var socketPath: String?

    var isRunning: Bool { listener != nil }

    private init() {}

    // MARK: - Lifecycle

    func start(socketPath path: String = CommandServer.defaultSocketPath) throws {
        guard listener == nil else { return }
        CommandRegistry.shared.bootstrap()

        // LENGTH GUARD — `sockaddr_un.sun_path` is 104 bytes on Darwin, terminator included. Beyond
        // that, `NWListener` throws NOTHING and never goes `.failed`: it declares itself ready, no
        // socket appears on disk, and the client fails with "file not found". Seen while trying to
        // serve from a session temp folder (~140 characters): the app announced "listening" and was
        // not listening. A silent limit has to become a loud error.
        let byteCount = path.utf8.count
        guard byteCount < 104 else {
            throw CommandError(code: .bad_params,
                               message: "socket path too long (\(byteCount) bytes, "
                                      + "maximum 103): \(path)")
        }

        let fm = FileManager.default
        let directory = URL(fileURLWithPath: path).deletingLastPathComponent()
        try? fm.createDirectory(at: directory, withIntermediateDirectories: true)
        // A stale socket from a previous run (crash, kill -9): `bind` would fail on an existing
        // file. We remove it — the presence of the file does not prove a server is listening
        // behind it.
        if fm.fileExists(atPath: path) { try? fm.removeItem(atPath: path) }

        let parameters = NWParameters.tcp
        parameters.allowLocalEndpointReuse = true
        parameters.requiredLocalEndpoint = NWEndpoint.unix(path: path)

        let listener: NWListener
        do {
            listener = try NWListener(using: parameters)
        } catch {
            throw CommandError(code: .engine_error,
                               message: "could not open the socket \(path): \(error)")
        }

        listener.newConnectionHandler = { [weak self] connection in
            Task { @MainActor [weak self] in self?.accept(connection) }
        }
        listener.stateUpdateHandler = { [weak self] state in
            guard case .failed(let error) = state else { return }
            let text = String(describing: error)
            Task { @MainActor [weak self] in
                NSLog("[API] listener failed: %@", text)
                self?.stop()
            }
        }

        listener.start(queue: .main)
        self.listener = listener
        self.socketPath = path
        NSLog("[API] command server listening on %@", path)
    }

    func stop() {
        for connection in connections.values { connection.close() }
        connections.removeAll()
        listener?.cancel()
        listener = nil
        // The socket is a file: leaving it behind would make the next client believe a server is
        // listening.
        if let socketPath { try? FileManager.default.removeItem(atPath: socketPath) }
        socketPath = nil
    }

    // MARK: - Connections

    private func accept(_ nwConnection: NWConnection) {
        let connection = Connection(nwConnection) { [weak self] finished in
            self?.connections.removeValue(forKey: ObjectIdentifier(finished))
        }
        connections[ObjectIdentifier(connection)] = connection
        connection.start()
    }

    // MARK: - One client connection

    /// A JSON-lines stream. The requests of one client are handled IN SERIES: without that, two
    /// lines arriving in the same packet would leave as two concurrent tasks and the responses
    /// could swap — a script that writes then reads would see the state from before.
    @MainActor
    private final class Connection {

        private let connection: NWConnection
        private let onClose: @MainActor (Connection) -> Void
        private var buffer = Data()
        private var pending: [Data] = []
        private var isDraining = false
        private var closed = false

        /// A safeguard: a line that never ends (a client that never sends a `\n`) must not let the
        /// buffer grow without limit.
        private static let maxLineBytes = 32 * 1024 * 1024

        init(_ connection: NWConnection, onClose: @escaping @MainActor (Connection) -> Void) {
            self.connection = connection
            self.onClose = onClose
        }

        func start() {
            connection.stateUpdateHandler = { [weak self] state in
                switch state {
                case .cancelled, .failed:
                    Task { @MainActor [weak self] in self?.close() }
                default:
                    break
                }
            }
            connection.start(queue: .main)
            receive()
        }

        private func receive() {
            connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) {
                [weak self] data, _, isComplete, error in
                // `NWError` stays inside the callback: we only let a string of it cross, which avoids any
                // `Sendable` question about the framework's type.
                let failed = error != nil
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    if let data, !data.isEmpty { self.ingest(data) }
                    if isComplete || failed { self.close() } else { self.receive() }
                }
            }
        }

        private func ingest(_ data: Data) {
            buffer.append(data)
            guard buffer.count <= Self.maxLineBytes else {
                NSLog("[API] oversized line, connection closed")
                close()
                return
            }
            // Splits on newlines; the remainder (an incomplete line) stays in the buffer.
            while let index = buffer.firstIndex(of: UInt8(ascii: "\n")) {
                let line = buffer[buffer.startIndex..<index]
                buffer = buffer[buffer.index(after: index)...]
                let trimmed = Data(line).trimmingTrailingCarriageReturn()
                if !trimmed.isEmpty { pending.append(trimmed) }
            }
            // `buffer` has become a slice: we compact it again, otherwise the start indices drift
            // and `firstIndex(of:)` would work on storage that is never released.
            buffer = Data(buffer)
            drain()
        }

        private func drain() {
            guard !isDraining, !closed else { return }
            guard !pending.isEmpty else { return }
            isDraining = true
            let line = pending.removeFirst()
            Task { @MainActor [weak self] in
                guard let self else { return }
                await self.process(line)
                self.isDraining = false
                self.drain()
            }
        }

        private func process(_ line: Data) async {
            let response: JSONValue
            do {
                let request = try JSONValue.decode(line: line)
                response = await CommandRegistry.shared.handle(request: request)
            } catch {
                // Unreadable JSON: no `id` to send back, but the response stays structured.
                response = .object(["id": .null, "ok": .bool(false),
                                    "error": CommandError(code: .bad_params,
                                                          message: "invalid JSON: \(error)").jsonObject])
            }
            send(response)
        }

        private func send(_ value: JSONValue) {
            guard !closed else { return }
            guard var data = try? value.encodedLine() else {
                NSLog("[API] response not serialisable, ignored")
                return
            }
            data.append(UInt8(ascii: "\n"))
            connection.send(content: data, completion: .contentProcessed { _ in })
        }

        func close() {
            guard !closed else { return }
            closed = true
            connection.cancel()
            onClose(self)
        }
    }
}

private extension Data {
    /// Tolerates CRLF line endings (a Windows client, or a clumsy `printf`).
    func trimmingTrailingCarriageReturn() -> Data {
        guard last == UInt8(ascii: "\r") else { return self }
        return dropLast()
    }
}
