//
//  SocketTimedEmitter.swift
//  Socket.IO-Client-Swift
//
//  Phase 9: per-emit ack with typed SocketAckError.
//
//  Permission is hereby granted, free of charge, to any person obtaining a copy
//  of this software and associated documentation files (the "Software"), to deal
//  in the Software without restriction, including without limitation the rights
//  to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
//  copies of the Software, and to permit persons to whom the Software is
//  furnished to do so, subject to the following conditions:
//
//  The above copyright notice and this permission notice shall be included in
//  all copies or substantial portions of the Software.
//
//  THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
//  IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
//  FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
//  AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
//  LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
//  OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
//  THE SOFTWARE.

import Foundation

/// A chainable handle returned from `SocketIOClient.timeout(after:)` that emits
/// an event with a typed-error per-emit ack callback.
///
/// JS analogue: `socket.timeout(2000).emit("ev", arg, (err, data) => ...)`.
///
/// Usage:
/// ```swift
/// socket.timeout(after: 2).emit("ping") { err, data in
///     if let err = err as? SocketAckError { /* .timeout or .disconnected */ }
///     else { /* server ack data in `data` */ }
/// }
/// ```
///
/// **Threading:** the underlying registration runs on
/// `socket.manager.handleQueue`, so the timer is scheduled before the emit
/// funnel is invoked. This means a disconnected emit still fires `.timeout`
/// after `seconds` — matching JS `_registerAckCallback` semantics.
public struct SocketTimedEmitter {
    let socket: SocketIOClient
    let timeout: Double

    /// Variadic callback overload.
    public func emit(_ event: String, _ items: SocketData...,
                     ack: @escaping (Error?, [Any]) -> Void) {
        emit(event, with: items, ack: ack)
    }

    /// Array callback overload.
    public func emit(_ event: String, with items: [SocketData],
                     ack: @escaping (Error?, [Any]) -> Void) {
        socket.emitTimed(event: event, items: items, timeout: timeout, ack: ack)
    }

    /// Variadic async/throws overload.
    public nonisolated(nonsending) func emit(_ event: String, _ items: SocketData...) async throws -> sending [Any] {
        return try await emit(event, with: items)
    }

    /// JS-named alias of the async overload — `socket.timeout(ms).emitWithAck(ev, ...)`.
    public nonisolated(nonsending) func emitWithAck(_ event: String, _ items: SocketData...) async throws -> sending [Any] {
        return try await emit(event, with: items)
    }

    /// Array form of `emitWithAck`.
    public nonisolated(nonsending) func emitWithAck(_ event: String, with items: [SocketData]) async throws -> sending [Any] {
        return try await emit(event, with: items)
    }

    /// Array async/throws overload.
    ///
    /// Throws `SocketAckError.timeout` / `.disconnected` for the corresponding
    /// fire reasons, or `CancellationError` if the awaiting `Task` is cancelled
    /// before the ack arrives.
    public nonisolated(nonsending) func emit(_ event: String, with items: [SocketData]) async throws -> sending [Any] {
        // The token is set synchronously by cancellation, even if cancellation
        // arrives before emitTimed's queue block. ID allocation and registration
        // happen together on handleQueue; no actor/executor mutates currentAck.
        let state = SocketAsyncAckState()
        let socket = self.socket
        // `onCancel` is @Sendable and `SocketIOClient` is not: the box carries the
        // reference across that boundary, and the socket is only ever touched on
        // its manager's serial handleQueue.
        let boxed = SocketUncheckedSendableBox(socket)
        let queue = socket.manager?.handleQueue
        let snapshot: [SocketValueSnapshot] = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                socket.emitTimed(event: event, items: items, timeout: timeout, cancellation: state) { error, data in
                    if let error = error { continuation.resume(throwing: error) }
                    else {
                        do { continuation.resume(returning: try data.map { try SocketValueSnapshot($0) }) }
                        catch { continuation.resume(throwing: error) }
                    }
                }
            }
        } onCancel: {
            state.cancel()
            queue?.socketAsync {
                boxed.value.cancelAsyncEmit(state)
            }
        }
        return snapshot.map { $0.value }
    }
}

/// Bridges Task cancellation to the serial ack registry. Only this tiny state
/// crosses executors; the socket and its ack IDs remain handleQueue-confined.
internal final class SocketAsyncAckState {
    private let lock = NSLock()
    private var cancelled = false
    private var id: Int?
    private var queueID: Int?
    var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return cancelled }
    var registeredID: Int? { lock.lock(); defer { lock.unlock() }; return id }
    var registeredQueueID: Int? { lock.lock(); defer { lock.unlock() }; return queueID }
    func registerQueue(_ id: Int) { lock.lock(); queueID = id; lock.unlock() }
    func cancel() { lock.lock(); cancelled = true; lock.unlock() }
    func register(_ id: Int) { lock.lock(); self.id = id; lock.unlock() }
}
#if compiler(>=5.5)
extension SocketAsyncAckState: @unchecked Sendable {}
#endif

/// Carries a handleQueue-confined reference across a `@Sendable` boundary.
/// Correctness relies on the caller dispatching to that queue, not on the box.
internal struct SocketUncheckedSendableBox<Value> {
    let value: Value
    init(_ value: Value) { self.value = value }
}
#if compiler(>=5.5)
extension SocketUncheckedSendableBox: @unchecked Sendable {}
#endif

/// The only values an acknowledgement can contain on the wire. Materializing a
/// snapshot creates fresh containers for the awaiting task, so mutable JSON
/// containers on handleQueue cannot be aliased across Swift concurrency domains.
internal indirect enum SocketValueSnapshot: Sendable {
    case null
    case string(String)
    case number(NSNumber)
    case binary(Data)
    case array([SocketValueSnapshot])
    case object([String: SocketValueSnapshot])

    internal init(_ value: Any, depth: Int = 0) throws {
        guard depth < 1025 else { throw SnapshotError.unsupportedValue }
        switch value {
        case is NSNull: self = .null
        case let value as String: self = .string(value)
        case let value as NSNumber: self = .number(value.copy() as! NSNumber)
        case let value as Data:
            self = .binary(value.withUnsafeBytes { Data($0) })
        case let value as [Any]:
            self = .array(try value.map { try Self($0, depth: depth + 1) })
        case let value as [String: Any]:
            self = .object(try value.mapValues { try Self($0, depth: depth + 1) })
        default: throw SnapshotError.unsupportedValue
        }
    }

    internal var value: Any {
        switch self {
        case .null: return NSNull()
        case .string(let value): return value
        case .number(let value): return value
        case .binary(let value): return value
        case .array(let value): return value.map { $0.value }
        case .object(let value): return value.mapValues { $0.value }
        }
    }

    private enum SnapshotError: Error { case unsupportedValue }
}
