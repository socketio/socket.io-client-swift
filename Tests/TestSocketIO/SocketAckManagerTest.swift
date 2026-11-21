//
//  SocketAckManagerTest.swift
//  Socket.IO-Client-Swift
//
//  Created by Lukas Schmidt on 04.09.15.
//
//

import XCTest
@testable import SocketIO

class SocketAckManagerTest : XCTestCase {
    var ackManager = SocketAckManager()

    func testAddAcks() {
        let callbackExpection = expectation(description: "callbackExpection")
        let itemsArray = ["Hi", "ho"]

        func callback(_ items: [Any]) {
            callbackExpection.fulfill()
        }

        ackManager.addAck(1, callback: callback)
        ackManager.executeAck(1, with: itemsArray)

        wait(for: [callbackExpection], timeout: 3.0)
    }

    func testManagerTimeoutAck() {
        let callbackExpection = expectation(description: "Manager should timeout ack with noAck status")

        func callback(_ items: [Any]) {
            XCTAssertEqual(items.count, 1, "Timed out ack should have one value")
            guard let timeoutReason = items[0] as? String else {
                XCTFail("Timeout reason should be a string")

                return
            }

            XCTAssert(timeoutReason == SocketAckStatus.noAck)

            callbackExpection.fulfill()
        }

        ackManager.addAck(1, callback: callback)
        ackManager.timeoutAck(1)

        wait(for: [callbackExpection], timeout: 0.2)
    }

    // MARK: Review gate R5 — registry storage is thread-safe

    /// The modern paths allocate acknowledgement ids on `handleQueue`, but the
    /// legacy `emitWithAck` chain allocates on the caller's thread. Two
    /// registrations that received the same id would share a callback slot, so
    /// the allocator is lock-guarded. Without the lock this is the shape Thread
    /// Sanitizer reports.
    func testConcurrentAckIdAllocationNeverRepeats() {
        let manager = SocketManager(socketURL: URL(string: "http://localhost/")!, config: [.log(false)])
        let socket = manager.defaultSocket
        let lock = NSLock()
        var allocated = [Int]()

        DispatchQueue.concurrentPerform(iterations: 200) { _ in
            let id = socket.allocateAckId()
            lock.lock()
            allocated.append(id)
            lock.unlock()
        }

        XCTAssertEqual(allocated.count, 200)
        XCTAssertEqual(Set(allocated).count, 200, "every allocation must own its id")
        XCTAssertEqual(socket.currentAck, 199)
    }

    /// `SocketIOClient.clearRecoveryState()` is public and reads
    /// `pendingTimedAckIDs` from the caller's thread while `handleQueue` may be
    /// registering. Reading the dictionary unsynchronized is memory-unsafe, not
    /// merely mis-ordered.
    func testConcurrentSnapshotAndRegistrationDoNotCorruptTheRegistry() {
        let queue = DispatchQueue(label: "ack.registration")
        let done = expectation(description: "registrations finished")

        queue.async {
            for id in 0..<500 {
                self.ackManager.addTimedAck(id, on: queue, callback: { _, _ in }, timeout: .infinity)
            }
            done.fulfill()
        }

        for _ in 0..<500 {
            _ = ackManager.pendingTimedAckIDs
        }
        wait(for: [done], timeout: 10)

        queue.sync {
            XCTAssertEqual(self.ackManager.pendingTimedAckIDs.count, 500)
            self.ackManager.clearTimedAcks(reason: .disconnected)
            XCTAssertTrue(self.ackManager.pendingTimedAckIDs.isEmpty)
        }
    }
}
