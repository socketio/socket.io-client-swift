//
//  SocketBufferLimits.swift
//  Socket.IO-Client-Swift
//
//  Round 3 of the JavaScript-parity port: review gate R1, "bound the entire
//  pipeline, not only individual native packets".
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

/// One resource policy for every queue this client retains data in.
///
/// The JavaScript client has no such policy: `sendBuffer`, `_queue` and its
/// receive path are unbounded, and so are this client's by default. **Every
/// limit here is off unless you set it**, which is what keeps the default
/// behaviour JavaScript-equal. Setting one opts into a hard bound with an
/// explicit, never-silent failure.
///
/// This is the pipeline-wide layer of three:
///
/// * `.parserOptions(SocketParserOptions)` bounds *one* incoming Socket.IO
///   packet (attachment count, text/binary bytes, nesting depth).
/// * `.webSocketOptions(SocketWebSocketOptions)` bounds *one* native WebSocket
///   message and the native send queue.
/// * `.bufferLimits(SocketBufferLimits)` bounds everything that accumulates
///   *across* packets: the application send buffer, the retry queue, the
///   pre-connect receive buffer (including recovery), the engine-to-manager handoff,
///   one incoming polling HTTP body, and how long a half-reconstructed binary
///   packet may stay outstanding.
///
/// ## Overflow behaviour
///
/// Overflow is never silent and never partial:
///
/// * **Outgoing** (`sendBuffer`, `retryQueue`): the *new* emit fails locally.
///   Its write completion runs once, its acknowledgement settles once with a
///   `SocketBufferLimitError`, the `.error` client event carries the same
///   error, and no packet is buffered, queued or written. Already-accepted
///   emits are never evicted — dropping a reliable emit that the caller
///   believes is queued is exactly the silent data loss this gate forbids.
/// * **Incoming** (replay buffer, handoff backlog, polling body): the
///   connection is closed with `"transport error"`, the reason engine.io-client
///   reports from `_onError` → `_onClose`. A half-reconstructed binary packet
///   that outlives its deadline is a decoder failure and closes with
///   `"parse error"`, the reason `Manager.ondata` reports when the decoder
///   throws. Reconnection then proceeds normally if it is enabled; nothing is
///   replayed from a partial packet.
public struct SocketBufferLimits : Equatable, Sendable {
    // MARK: Properties

    /// Maximum number of packets held in `SocketIOClient`'s send buffer — the
    /// emits made while the socket is not connected. `Int.max` (the default)
    /// imposes no limit, like JS `sendBuffer`.
    public var maximumSendBufferPackets: Int

    /// Maximum estimated payload bytes held in the send buffer.
    /// `Int.max` (the default) imposes no limit.
    public var maximumSendBufferBytes: Int

    /// Maximum number of entries in the `.retries` queue.
    /// `Int.max` (the default) imposes no limit, like JS `_queue`.
    public var maximumRetryQueuePackets: Int

    /// Maximum estimated payload bytes held in the retry queue.
    /// `Int.max` (the default) imposes no limit.
    public var maximumRetryQueueBytes: Int

    /// Maximum number of received events buffered before CONNECT, including
    /// initial connections and recovery replay. The historical name is retained.
    /// `Int.max` (the default) imposes no limit.
    public var maximumRecoveryReplayPackets: Int

    /// Maximum estimated payload bytes held in the pre-connect receive buffer.
    /// `Int.max` (the default) imposes no limit.
    public var maximumRecoveryReplayBytes: Int

    /// Maximum number of packets the engine may hand to the manager's queue
    /// without them having been parsed yet. The permit is taken when the packet
    /// is dispatched and released when parsing has *finished*, so a consumer
    /// that cannot keep up stops the transport instead of letting the queue
    /// grow. `Int.max` (the default) imposes no limit.
    public var maximumUnparsedPackets: Int

    /// Maximum bytes dispatched to the manager's queue but not yet parsed.
    /// `Int.max` (the default) imposes no limit.
    public var maximumUnparsedBytes: Int

    /// Maximum bytes of one incoming long-polling HTTP response body. The body
    /// is bounded **while it is received**: an announced `Content-Length` above
    /// the limit is refused before any body arrives, and a chunked response is
    /// cancelled as soon as the accumulated bytes cross it.
    /// `Int.max` (the default) imposes no limit.
    public var maximumPollingResponseBytes: Int

    /// How long (seconds) a half-reconstructed binary packet may wait for its
    /// remaining attachments before the session is closed with `"parse error"`.
    /// `.infinity` (the default) waits forever, like JS.
    public var binaryReconstructionTimeout: Double

    // MARK: Initializers

    /// Every limit defaults to "no limit", which is the JavaScript behaviour.
    public init(maximumSendBufferPackets: Int = .max,
                maximumSendBufferBytes: Int = .max,
                maximumRetryQueuePackets: Int = .max,
                maximumRetryQueueBytes: Int = .max,
                maximumRecoveryReplayPackets: Int = .max,
                maximumRecoveryReplayBytes: Int = .max,
                maximumUnparsedPackets: Int = .max,
                maximumUnparsedBytes: Int = .max,
                maximumPollingResponseBytes: Int = .max,
                binaryReconstructionTimeout: Double = .infinity) {
        self.maximumSendBufferPackets = maximumSendBufferPackets
        self.maximumSendBufferBytes = maximumSendBufferBytes
        self.maximumRetryQueuePackets = maximumRetryQueuePackets
        self.maximumRetryQueueBytes = maximumRetryQueueBytes
        self.maximumRecoveryReplayPackets = maximumRecoveryReplayPackets
        self.maximumRecoveryReplayBytes = maximumRecoveryReplayBytes
        self.maximumUnparsedPackets = maximumUnparsedPackets
        self.maximumUnparsedBytes = maximumUnparsedBytes
        self.maximumPollingResponseBytes = maximumPollingResponseBytes
        self.binaryReconstructionTimeout = binaryReconstructionTimeout
    }

    /// The JavaScript-equal default: nothing is bounded.
    public static let unlimited = SocketBufferLimits()

    // MARK: Internal

    /// Rejected before connecting, like an invalid `SocketParserOptions`.
    internal var isValid: Bool {
        maximumSendBufferPackets > 0 && maximumSendBufferBytes > 0 &&
        maximumRetryQueuePackets > 0 && maximumRetryQueueBytes > 0 &&
        maximumRecoveryReplayPackets > 0 && maximumRecoveryReplayBytes > 0 &&
        maximumUnparsedPackets > 0 && maximumUnparsedBytes > 0 &&
        maximumPollingResponseBytes > 0 &&
        (binaryReconstructionTimeout.isInfinite || binaryReconstructionTimeout > 0)
    }

    /// `true` when nothing has been configured, so every enforcement point can
    /// keep the previous, measured code path untouched.
    internal var isUnlimited: Bool { self == SocketBufferLimits.unlimited }

    /// Whether anything on the receive side is bounded.
    internal var boundsReceive: Bool {
        maximumUnparsedPackets != .max || maximumUnparsedBytes != .max
    }

    /// Estimated retained size of a normalized emit payload, in bytes.
    ///
    /// The payload reaching a buffer has already been through
    /// `SocketPacket.jsonSafeEmitData`, so it only contains `String`,
    /// `NSNumber`, `NSNull`, `Data`, `[Any]` and `[String: Any]` — a finite
    /// graph with a bounded depth and node count. This is an accounting
    /// estimate for the limit, not the exact wire size: the caller's intent is
    /// "do not retain more than N bytes of my payloads".
    internal static func retainedBytes(of items: [Any]) -> Int {
        items.reduce(0) { $0 &+ retainedBytes(ofValue: $1) }
    }

    private static func retainedBytes(ofValue value: Any) -> Int {
        switch value {
        case let string as String:
            return string.utf8.count
        case let data as Data:
            return data.count
        case let array as [Any]:
            return array.reduce(8) { $0 &+ retainedBytes(ofValue: $1) }
        case let dictionary as [String: Any]:
            return dictionary.reduce(8) { $0 &+ $1.key.utf8.count &+ retainedBytes(ofValue: $1.value) }
        case is NSNull:
            return 4
        default:
            // Numbers, booleans and anything else Foundation boxes.
            return 8
        }
    }
}

/// Reported when a `SocketBufferLimits` bound would be exceeded.
///
/// Outgoing overflows deliver this through the operation's acknowledgement and
/// through the `.error` client event; incoming overflows log it and close the
/// connection, because there is no caller to hand it to.
public struct SocketBufferLimitError : LocalizedError, Equatable, CustomStringConvertible {
    // MARK: Cases

    /// Which bounded buffer overflowed.
    public enum Buffer : String, Sendable {
        /// `SocketIOClient`'s buffer of emits made while disconnected.
        case sendBuffer

        /// The ordered `.retries` queue.
        case retryQueue

        /// The connection-state-recovery replay buffer.
        case recoveryReplay

        /// Packets dispatched from the engine to the manager but not yet parsed.
        case receiveBacklog

        /// One incoming long-polling HTTP response body.
        case pollingResponse

        /// A binary packet still waiting for its attachments.
        case binaryReconstruction
    }

    // MARK: Properties

    /// The buffer whose limit was reached.
    public let buffer: Buffer

    /// The configured limit.
    public let limit: Int

    /// What the buffer would have held had the operation been accepted.
    public let attempted: Int

    /// `true` when `limit`/`attempted` are byte counts, `false` for item counts.
    public let measuringBytes: Bool

    /// :nodoc:
    public var description: String {
        let unit = measuringBytes ? "bytes" : "packets"

        return "\(buffer.rawValue) limit exceeded: \(attempted) \(unit) would exceed the configured \(limit)"
    }

    /// `LocalizedError`, so the reason survives the trip through an existential
    /// `Error` — the polling transport reports it as `didError(reason:)`.
    public var errorDescription: String? { description }
}
