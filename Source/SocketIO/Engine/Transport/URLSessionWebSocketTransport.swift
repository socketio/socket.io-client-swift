import Dispatch
import Foundation

/// Ordered, bounded, queue-confined transport. Each Socket.IO text header and its
/// binary attachments must be submitted together in one batch. A completion is a
/// local send result, never an acknowledgement from the Socket.IO server.
internal final class URLSessionWebSocketTransport: EngineWebSocketTransport {
    internal var onEvent: ((EngineWebSocketEvent) -> Void)?

    /// Defaults bound queued payload memory, not Engine.IO polling maxPayload.
    internal static let defaultMaximumPendingBytes = 16 * 1024 * 1024
    internal static let defaultMaximumPendingBatches = 1024
    internal static let defaultMaximumPendingMessages = 4096

    internal var isWritable: Bool {
        assertQueue()
        return state == .open && batches.isEmpty
    }

    private enum State { case idle, connecting, open, closed }
    private struct Batch {
        let messages: [EngineWebSocketMessage]
        let bytes: Int
        let completion: (Result<Void, Error>) -> Void
        var index = 0
    }

    private let queue: DispatchQueue
    private let makeConnection: () -> EngineWebSocketConnection
    private let maximumPendingBytes: Int
    private let maximumPendingBatches: Int
    private let maximumPendingMessages: Int
    private var state: State = .idle
    private var generation: UInt64 = 0
    private var connection: EngineWebSocketConnection?
    private var batches = [Batch]()
    private var pendingBytes = 0
    private var pendingMessages = 0
    private var sendToken: UUID?
    private var receiveToken: UUID?

    /// Factory injection makes lifecycle races testable without a network server.
    /// The factory must return a fresh connection/session/task for every attempt.
    internal init(queue: DispatchQueue,
                  maximumPendingBytes: Int = URLSessionWebSocketTransport.defaultMaximumPendingBytes,
                  maximumPendingBatches: Int = URLSessionWebSocketTransport.defaultMaximumPendingBatches,
                  maximumPendingMessages: Int = URLSessionWebSocketTransport.defaultMaximumPendingMessages,
                  makeConnection: @escaping () -> EngineWebSocketConnection) {
        precondition(maximumPendingBytes > 0 && maximumPendingBatches > 0 && maximumPendingMessages > 0)
        self.queue = queue
        self.maximumPendingBytes = maximumPendingBytes
        self.maximumPendingBatches = maximumPendingBatches
        self.maximumPendingMessages = maximumPendingMessages
        self.makeConnection = makeConnection
    }

    deinit {
        // Safety net only. Normal lifecycle uses close/abort/finish explicitly.
        let abandoned = connection
        let pending = batches
        queue.socketAsync {
            abandoned?.onEvent = nil
            abandoned?.cancel()
            for batch in pending { batch.completion(.failure(EngineWebSocketError.cancelled)) }
        }
    }

    internal func connect() {
        assertQueue()
        guard state == .idle || state == .closed else { return }
        generation &+= 1
        let attempt = generation
        let newConnection = makeConnection()
        let identity = ObjectIdentifier(newConnection)
        state = .connecting
        connection = newConnection
        let queue = self.queue
        newConnection.onEvent = { [weak self] event in
            queue.socketAsync { [weak self] in
                guard let self = self, self.isCurrent(attempt, identity) else { return }
                switch event {
                case .opened:
                    guard self.state == .connecting else { return }
                    self.state = .open
                    self.onEvent?(event)
                    // An event handler may synchronously abort or reconnect.
                    guard self.isCurrent(attempt, identity) else { return }
                    self.receiveNext()
                case .closed(let code, let reason, let error):
                    self.finish(code: code, reason: reason, error: error)
                case .message:
                    // Only receive() delivers messages, avoiding two receive paths.
                    break
                }
            }
        }
        newConnection.start()
    }

    internal func sendBatch(_ messages: [EngineWebSocketMessage],
                            completion: @escaping (Result<Void, Error>) -> Void) {
        assertQueue()
        guard state == .open else {
            completion(.failure(EngineWebSocketError.notOpen))
            return
        }
        guard messages.count <= maximumPendingMessages - pendingMessages else {
            completion(.failure(EngineWebSocketError.queueLimitExceeded))
            return
        }
        // Check incrementally to avoid integer overflow on oversized input.
        var bytes = 0
        for message in messages {
            guard message.byteCount <= maximumPendingBytes - bytes else {
                completion(.failure(EngineWebSocketError.queueLimitExceeded))
                return
            }
            bytes += message.byteCount
        }
        guard batches.count < maximumPendingBatches,
              bytes <= maximumPendingBytes - pendingBytes else {
            completion(.failure(EngineWebSocketError.queueLimitExceeded))
            return
        }
        // Even an empty batch participates in FIFO completion ordering.
        batches.append(Batch(messages: messages, bytes: bytes, completion: completion))
        pendingBytes += bytes
        pendingMessages += messages.count
        sendNext()
    }

    internal func close(code: Int, reason: Data?) {
        assertQueue()
        // Standard wire-sendable close codes supported by Foundation. Reserved
        // status codes and oversized reasons must never be put on the wire.
        guard [1000, 1001, 1002, 1003, 1007, 1008, 1009, 1010, 1011].contains(code),
              (reason?.count ?? 0) <= 123 else {
            finish(code: nil, reason: nil, error: EngineWebSocketError.invalidCloseFrame)
            return
        }
        finish(code: code, reason: reason, error: nil, localClose: true)
    }

    internal func abort() {
        assertQueue()
        finish(code: nil, reason: nil, error: EngineWebSocketError.cancelled)
    }

    private func assertQueue() {
        dispatchPrecondition(condition: .onQueue(queue))
    }

    private func isCurrent(_ attempt: UInt64, _ identity: ObjectIdentifier) -> Bool {
        guard generation == attempt, let connection = connection else { return false }
        return ObjectIdentifier(connection) == identity && (state == .connecting || state == .open)
    }

    private func receiveNext() {
        guard state == .open, receiveToken == nil, let connection = connection else { return }
        let attempt = generation
        let identity = ObjectIdentifier(connection)
        let token = UUID()
        receiveToken = token
        let queue = self.queue
        connection.receive { [weak self] result in
            queue.socketAsync { [weak self] in
                guard let self = self, self.isCurrent(attempt, identity), self.receiveToken == token else { return }
                self.receiveToken = nil
                switch result {
                case .success(let message):
                    self.onEvent?(.message(message))
                    guard self.isCurrent(attempt, identity) else { return }
                    self.receiveNext()
                case .failure(let error):
                    self.finish(code: nil, reason: nil, error: error)
                }
            }
        }
    }

    private func sendNext() {
        guard state == .open, sendToken == nil, let connection = connection else { return }
        let attempt = generation
        let identity = ObjectIdentifier(connection)
        // Empty batches finish in order without sending an empty wire message.
        while let batch = batches.first, batch.index == batch.messages.count {
            batches.removeFirst()
            pendingBytes -= batch.bytes
            pendingMessages -= batch.messages.count
            batch.completion(.success(()))
            guard isCurrent(attempt, identity), sendToken == nil else { return }
        }
        guard let batch = batches.first else { return }
        let token = UUID()
        sendToken = token
        let queue = self.queue
        connection.send(batch.messages[batch.index]) { [weak self] error in
            queue.socketAsync { [weak self] in
                guard let self = self, self.isCurrent(attempt, identity), self.sendToken == token else { return }
                self.sendToken = nil
                if let error = error {
                    // Never replay a partially delivered batch on another connection.
                    self.finish(code: nil, reason: nil, error: error)
                } else {
                    self.batches[0].index += 1
                    self.sendNext()
                }
            }
        }
    }

    private func finish(code: Int?, reason: Data?, error: Error?, localClose: Bool = false) {
        guard state == .connecting || state == .open else { return }
        let previousState = state
        let oldConnection = connection
        let code = code ?? oldConnection?.closeDetails.code
        let reason = reason ?? oldConnection?.closeDetails.reason
        let pending = batches
        // Every transport end passes through here: log the native detail before
        // the connection is torn down, so a dropped socket can be diagnosed.
        let native = error.map { $0 as NSError }
        let underlying = native?.userInfo[NSUnderlyingErrorKey] as? NSError
        DefaultSocketLogger.Logger.log(
            "WebSocket finish: state=\(previousState), localClose=\(localClose), "
                + "closeCode=\(code.map { String($0) } ?? "none"), "
                + "reason=\(reason.flatMap { String(data: $0, encoding: .utf8) } ?? "none"), "
                + "error=\(native.map { "\($0.domain)/\($0.code): \($0.localizedDescription)" } ?? "none"), "
                + "underlying=\(underlying.map { "\($0.domain)/\($0.code): \($0.localizedDescription)" } ?? "none")",
            type: "URLSessionWebSocketTransport")
        state = .closed
        connection = nil
        batches.removeAll(keepingCapacity: false)
        pendingBytes = 0
        pendingMessages = 0
        sendToken = nil
        receiveToken = nil
        oldConnection?.onEvent = nil
        if localClose && previousState == .open {
            oldConnection?.close(code: code ?? 1000, reason: reason)
        } else {
            oldConnection?.cancel()
        }
        // State and resources are detached before invoking reentrant client code.
        onEvent?(.closed(code: code, reason: reason, error: error))
        let failure = error ?? EngineWebSocketError.closed
        for batch in pending { batch.completion(.failure(failure)) }
    }
}
