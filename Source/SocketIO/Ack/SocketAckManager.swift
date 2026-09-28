//
//  SocketAckManager.swift
//  Socket.IO-Client-Swift
//
//  Created by Erik Little on 4/3/15.
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

import Dispatch
import Foundation

/// The status of an ack.
public enum SocketAckStatus : String {
    // MARK: Cases

    /// The ack timed out.
    case noAck = "NO ACK"

    /// Tests whether a string is equal to a given SocketAckStatus
    public static func == (lhs: String, rhs: SocketAckStatus) -> Bool {
        return lhs == rhs.rawValue
    }

    /// Tests whether a string is equal to a given SocketAckStatus
    public static func == (lhs: SocketAckStatus, rhs: String) -> Bool {
        return rhs == lhs
    }
}

private struct SocketAck : Hashable {
    let ack: Int
    var callback: AckCallback!

    init(ack: Int) {
        self.ack = ack
    }

    init(ack: Int, callback: @escaping AckCallback) {
        self.ack = ack
        self.callback = callback
    }

    func hash(into hasher: inout Hasher) {
        ack.hash(into: &hasher)
    }

    fileprivate static func ==(lhs: SocketAck, rhs: SocketAck) -> Bool {
        return lhs.ack == rhs.ack
    }
}

class SocketAckManager {
    /// Guards **storage only**.
    ///
    /// The ordering contract below is unchanged: the timed-ack APIs are still
    /// meant to be invoked from the owning client's `handleQueue`, and one-shot
    /// delivery is still enforced by entry removal. The lock exists because two
    /// public entry points can reach this registry from the caller's thread —
    /// `SocketIOClient.clearRecoveryState()` snapshots `pendingTimedAckIDs`, and
    /// the legacy `emitWithAck` path registers through `addAck` — so the
    /// underlying `Set`/`Dictionary` could otherwise be mutated concurrently
    /// with a `handleQueue` write. That is memory-unsafe, not merely
    /// mis-ordered.
    ///
    /// Every method mutates under the lock and invokes callbacks **after**
    /// releasing it, so a callback that registers another acknowledgement (the
    /// documented re-entrancy of `cancelTimedAck(_:fireWith:)`) cannot deadlock.
    private let lock = NSLock()
    private var acks = Set<SocketAck>(minimumCapacity: 1)

    // MARK: Phase 9 — parallel timed-ack storage
    //
    // Legacy `acks` storage is intentionally untouched. The timed-ack APIs live
    // alongside it and are used exclusively by the new `SocketTimedEmitter`.
    //
    // All four timed-ack APIs (add/execute/cancel/clear) MUST be invoked from
    // the owning client's `manager.handleQueue`. One-shot delivery is enforced
    // by entry removal: the first path that sets `timedAcks[id] = nil` wins;
    // every other path's `timedAcks[id]` lookup returns nil and short-circuits.

    private struct TimedAckEntry {
        let callback: (Error?, [Any]) -> Void
        let identity: UUID
        let notifyOnDisconnect: Bool
        var timer: DispatchWorkItem?
    }

    private var timedAcks: [Int: TimedAckEntry] = [:]

    func addAck(_ ack: Int, callback: @escaping AckCallback) {
        lock.lock()
        acks.insert(SocketAck(ack: ack, callback: callback))
        lock.unlock()
    }

    /// Should be called on handle queue
    func executeAck(_ ack: Int, with items: [Any]) {
        lock.lock()
        let entry = acks.remove(SocketAck(ack: ack))
        lock.unlock()

        entry?.callback(items)
    }

    /// Should be called on handle queue
    func timeoutAck(_ ack: Int) {
        lock.lock()
        let entry = acks.remove(SocketAck(ack: ack))
        lock.unlock()

        entry?.callback?([SocketAckStatus.noAck.rawValue])
    }

    /// Add a timed ack. Caller MUST be on `queue` (the owning client's
    /// `manager.handleQueue`). Schedules a `DispatchWorkItem` via
    /// `queue.asyncAfter`; when the timer body runs it removes the entry and,
    /// if removal succeeded (i.e., no other path raced ahead), invokes the
    /// user callback with `(.timeout, [])`.
    ///
    /// One-shot is enforced by `timedAcks.removeValue(forKey: id)` returning
    /// non-nil for exactly one caller across the timer / execute / cancel /
    /// clear paths — all of which run serialized on `queue`.
    func addTimedAck(_ id: Int,
                     on queue: DispatchQueue,
                     callback: @escaping (Error?, [Any]) -> Void,
                     timeout: Double,
                     notifyOnDisconnect: Bool = true) {
        let identity = UUID()
        lock.lock()
        timedAcks[id]?.timer?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            guard let self = self else { return }
            // Already on `queue`. Removal is the one-shot signal; if another
            // path already removed the entry, removeValue returns nil and we
            // short-circuit.
            self.lock.lock()
            guard self.timedAcks[id]?.identity == identity,
                  let entry = self.timedAcks.removeValue(forKey: id) else {
                self.lock.unlock()

                return
            }
            self.lock.unlock()

            entry.callback(SocketAckError.timeout, [])
        }
        timedAcks[id] = TimedAckEntry(callback: callback, identity: identity,
                                      notifyOnDisconnect: notifyOnDisconnect,
                                      timer: timeout == .infinity ? nil : workItem)
        lock.unlock()
        // No queued timer or captured work item is needed for an infinite wait.
        guard timeout != .infinity else { return }
        let bounded = timeout.isFinite ? min(max(0, timeout), 2_147_483.647) : 0
        queue.socketAsyncAfter(deadline: .now() + bounded, execute: workItem)
    }

    /// Execute the timed ack with server-supplied data. Caller MUST be on the
    /// owning queue. One-shot via entry-removal — duplicate calls or late
    /// server acks after the timer fires are silently dropped because
    /// `removeValue` returns nil.
    func executeTimedAck(_ id: Int, with items: [Any]) {
        lock.lock()
        let removed = timedAcks.removeValue(forKey: id)
        lock.unlock()

        guard let entry = removed else { return }
        entry.timer?.cancel()
        entry.callback(nil, items)
    }

    /// Cancel a timed ack. Caller MUST be on the owning queue.
    ///
    /// - parameter id: the ack id to cancel.
    /// - parameter fireWith: when non-nil, invokes the user callback with
    ///   `(error, [])` as the canonical one-shot fire (used by the async
    ///   overload's `withTaskCancellationHandler` to deliver `CancellationError`
    ///   through the same atomic path that timeout/disconnect use). When nil,
    ///   the entry is removed silently — no callback is invoked.
    ///
    /// This deviates from the original plan (which had silent-only cancel) so
    /// that the async cancel path can route through one fire site instead of
    /// racing the continuation against the timer.
    ///
    /// **Re-entrancy:** when `fireWith` is non-nil, the user callback is
    /// invoked synchronously here while still on the owning queue
    /// (`handleQueue`), and a new emit issued from inside that callback may
    /// register its ack under this very stack frame. That is safe because this
    /// entry is already removed from `timedAcks` before the callback runs: the
    /// nested registration can only touch a different id, and no path can fire
    /// this entry a second time.
    func cancelTimedAck(_ id: Int, fireWith error: Error? = nil) {
        lock.lock()
        let removed = timedAcks.removeValue(forKey: id)
        lock.unlock()

        guard let entry = removed else { return }
        entry.timer?.cancel()
        if let error = error {
            entry.callback(error, [])
        }
    }

    /// Fire all outstanding timed acks with `reason` and clear storage.
    /// Caller MUST be on the owning queue. Snapshot-and-clear before iterating
    /// so any timer body that races between the snapshot and its own
    /// `removeValue` short-circuits (its lookup will return nil).
    ///
    /// - parameter keeping: ack ids to leave registered, with their timers still
    ///   running. JS `_clearAcks` skips acks whose packet is still in the send
    ///   buffer: that packet has not reached the server yet, so its ack is still
    ///   owed once the socket reconnects.
    /// Identifies only the entries owned by the connection being retired.
    var pendingTimedAckIDs: Set<Int> {
        lock.lock()
        defer { lock.unlock() }

        return Set(timedAcks.keys)
    }

    func clearTimedAcks(reason: SocketAckError, keeping: Set<Int> = [], only ids: Set<Int>? = nil) {
        lock.lock()
        let snapshot = timedAcks.filter { !keeping.contains($0.key) && (ids?.contains($0.key) ?? true) }
        for id in snapshot.keys {
            timedAcks.removeValue(forKey: id)
        }
        lock.unlock()

        for (_, entry) in snapshot {
            entry.timer?.cancel()
            if reason != .disconnected || entry.notifyOnDisconnect { entry.callback(reason, []) }
        }
    }
}
