//
//  SocketTypes.swift
//  Socket.IO-Client-Swift
//
//  Created by Erik Little on 4/8/15.
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

/// A marking protocol that says a type can be represented in a socket.io packet.
///
/// Example:
///
/// ```swift
/// struct CustomData : SocketData {
///    let name: String
///    let age: Int
///
///    func socketRepresentation() -> SocketData {
///        return ["name": name, "age": age]
///    }
/// }
///
/// socket.emit("myEvent", CustomData(name: "Erik", age: 24))
/// ```
public protocol SocketData {
    // MARK: Methods

    /// A representation of self that can sent over socket.io.
    func socketRepresentation() throws -> SocketData
}

public extension SocketData {
    /// Default implementation. Only works for native Swift types and a few Foundation types.
    func socketRepresentation() -> SocketData {
        return self
    }
}

extension Array : SocketData { }
extension Bool : SocketData { }
extension Dictionary : SocketData { }
extension Double : SocketData { }
extension Int : SocketData { }
extension NSArray : SocketData { }
extension Data : SocketData { }
extension NSData : SocketData { }
extension NSDictionary : SocketData { }
extension NSString : SocketData { }
extension NSNull : SocketData { }
extension String : SocketData { }

/// A `Date` is emitted as the ISO-8601 string `Date.prototype.toJSON()`
/// produces in JS (`"2024-01-02T03:04:05.678Z"`), at the top level and nested
/// at any depth. See `SocketPacket.iso8601String(from:)`.
extension Date : SocketData { }
extension NSDate : SocketData { }

/// A typealias for an ack callback.
public typealias AckCallback = ([Any]) -> ()

/// A typealias for a normal callback.
public typealias NormalCallback = ([Any], SocketAckEmitter) -> ()

/// A typealias for a queued POST
public typealias Post = (msg: String, completion: (() -> ())?)

typealias JSON = [String: Any]
typealias Probe = (msg: String, type: SocketEnginePacketType, data: [Data], rawBinary: Bool, completion: (() -> ())?)
typealias ProbeWaitQueue = [Probe]

enum Either<E, V> {
    case left(E)
    case right(V)
}

// MARK: - Serial-queue isolation boundary

/// A one-shot handoff to the queue that owns the captured state. This is the
/// GCD equivalent of an executor hop, not a claim that its captures are safe to
/// use concurrently. Callers must never touch queue-owned captures before the
/// hop, and must not share mutable payloads with the producer after submission.
/// SocketIOClient and SocketManager intentionally remain non-Sendable.
internal final class SocketQueueWork: @unchecked Sendable {
    private let queue: DispatchQueue
    private let body: () -> Void

    internal init(queue: DispatchQueue, body: @escaping () -> Void) {
        self.queue = queue
        self.body = body
    }

    internal func run() {
        dispatchPrecondition(condition: .onQueue(queue))
        body()
    }
}

internal extension DispatchQueue {
    func socketAsync(execute body: @escaping () -> Void) {
        let work = SocketQueueWork(queue: self, body: body)
        async { work.run() }
    }

    func socketAsyncAfter(deadline: DispatchTime, execute body: @escaping () -> Void) {
        let work = SocketQueueWork(queue: self, body: body)
        asyncAfter(deadline: deadline) { work.run() }
    }

    func socketAsyncAfter(deadline: DispatchTime, execute work: DispatchWorkItem) {
        asyncAfter(deadline: deadline, execute: work)
    }
}

internal extension DispatchGroup {
    func socketNotify(queue: DispatchQueue, execute body: @escaping () -> Void) {
        let work = SocketQueueWork(queue: queue, body: body)
        notify(queue: queue) { work.run() }
    }
}
