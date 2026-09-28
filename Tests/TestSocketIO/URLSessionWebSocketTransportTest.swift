import Dispatch
import Foundation
import XCTest
@testable import SocketIO

final class URLSessionWebSocketTransportTest: XCTestCase {
    func testMessagesArriveOnlyThroughReceiveCompletion() {
        let harness = Harness()
        let connection = harness.open()
        harness.event(connection, .message(.text("duplicate delegate path")))
        harness.run {
            XCTAssertTrue(harness.log.messages.isEmpty)
            XCTAssertEqual(connection.receives.count, 1)
        }
        harness.receiveFinished(connection, .success(.text("actual receive")))
        harness.run {
            XCTAssertEqual(harness.log.messages, [.text("actual receive")])
            XCTAssertEqual(connection.receives.count, 1)
        }
    }

    private enum TestError: Error { case failed }

    private final class Connection: EngineWebSocketConnection {
        var onEvent: ((EngineWebSocketEvent) -> Void)?
        var sent = [EngineWebSocketMessage]()
        var sends = [(Error?) -> Void]()
        var receives = [(Result<EngineWebSocketMessage, Error>) -> Void]()
        var starts = 0
        var cancels = 0
        var closes = [Int]()
        func start() { starts += 1 }
        func send(_ message: EngineWebSocketMessage, completion: @escaping (Error?) -> Void) {
            sent.append(message)
            sends.append(completion)
        }
        func receive(completion: @escaping (Result<EngineWebSocketMessage, Error>) -> Void) {
            receives.append(completion)
        }
        // Deliberately retain outstanding callbacks to reproduce late callbacks.
        func close(code: Int, reason: Data?) { closes.append(code) }
        func cancel() { cancels += 1 }
    }

    private final class Log {
        var connections = [Connection]()
        var opens = 0
        var terminals = 0
        var messages = [EngineWebSocketMessage]()
    }

    private final class Harness {
        let queue = DispatchQueue(label: "native-transport-test")
        let log = Log()
        let transport: URLSessionWebSocketTransport

        init(bytes: Int = 1024, batches: Int = 16, messages: Int = 4096) {
            let log = self.log
            transport = URLSessionWebSocketTransport(queue: queue, maximumPendingBytes: bytes,
                                                     maximumPendingBatches: batches, maximumPendingMessages: messages) {
                let connection = Connection()
                log.connections.append(connection)
                return connection
            }
            transport.onEvent = { event in
                switch event {
                case .opened: log.opens += 1
                case .closed: log.terminals += 1
                case .message(let message): log.messages.append(message)
                }
            }
        }
        deinit { queue.sync { transport.abort() } }
        func run(_ block: () -> Void) { queue.sync(execute: block) }
        func drain() { run {} }
        func connect() -> Connection {
            run { transport.connect() }
            return queue.sync { log.connections.last! }
        }
        func open() -> Connection {
            let connection = connect()
            event(connection, .opened(protocol: nil))
            return connection
        }
        func event(_ connection: Connection, _ event: EngineWebSocketEvent) {
            let callback = queue.sync { connection.onEvent }
            callback?(event)
            drain()
        }
        func sendFinished(_ connection: Connection, error: Error? = nil) {
            let callback = queue.sync { connection.sends.removeFirst() }
            callback(error)
            drain()
        }
        func receiveFinished(_ connection: Connection, _ result: Result<EngineWebSocketMessage, Error>) {
            let callback = queue.sync { connection.receives.removeFirst() }
            callback(result)
            drain()
        }
    }

    func testOpenStartsExactlyOneReceiveAndDuplicateOpenIsIgnored() {
        let h = Harness()
        let c = h.connect()
        h.run { XCTAssertEqual(c.receives.count, 0); XCTAssertFalse(h.transport.isWritable) }
        h.event(c, .opened(protocol: nil))
        h.event(c, .opened(protocol: nil))
        h.run {
            XCTAssertEqual(c.receives.count, 1)
            XCTAssertEqual(h.log.opens, 1)
            XCTAssertTrue(h.transport.isWritable)
        }
    }

    func testBatchKeepsTextHeaderAndAllBinaryAttachmentsContiguous() {
        let h = Harness()
        let c = h.open()
        var completions = [String]()
        let messages: [EngineWebSocketMessage] = [.text("451-"), .binary(Data([1])), .binary(Data([2])), .text("42next")]
        h.run {
            h.transport.sendBatch(Array(messages.prefix(3))) { _ in completions.append("A") }
            h.transport.sendBatch([messages[3]]) { _ in completions.append("B") }
            XCTAssertEqual(c.sent, [messages[0]])
            XCTAssertFalse(h.transport.isWritable)
        }
        h.sendFinished(c)
        h.sendFinished(c)
        h.run { XCTAssertTrue(completions.isEmpty); XCTAssertEqual(c.sent, Array(messages.prefix(3))) }
        h.sendFinished(c)
        h.run { XCTAssertEqual(completions, ["A"]); XCTAssertEqual(c.sent, messages) }
        h.sendFinished(c)
        h.run { XCTAssertEqual(completions, ["A", "B"]); XCTAssertTrue(h.transport.isWritable) }
    }

    func testFailureMidBatchFailsAllBatchesExactlyOnceAndDoesNotReplay() {
        let h = Harness()
        let c = h.open()
        var failures = 0
        h.run {
            for _ in 0..<2 {
                h.transport.sendBatch([.text("header"), .binary(Data([1]))]) { result in
                    if case .failure = result { failures += 1 } else { XCTFail("Expected failure") }
                }
            }
        }
        h.sendFinished(c)
        h.sendFinished(c, error: TestError.failed)
        h.event(c, .closed(code: nil, reason: nil, error: TestError.failed))
        let fresh = h.open()
        h.run {
            XCTAssertEqual(failures, 2)
            XCTAssertEqual(h.log.terminals, 1)
            XCTAssertEqual(c.cancels, 1)
            XCTAssertTrue(fresh.sent.isEmpty)
        }
    }

    func testAbortWhileConnectingIgnoresLateOpenAndTerminalEvents() {
        let h = Harness()
        let old = h.connect()
        let callback = h.queue.sync { old.onEvent! }
        h.run { h.transport.abort(); h.transport.abort() }
        let fresh = h.open()
        callback(.opened(protocol: nil))
        callback(.closed(code: 1006, reason: nil, error: TestError.failed))
        h.drain()
        h.run {
            XCTAssertEqual(h.log.opens, 1)
            XCTAssertEqual(h.log.terminals, 1)
            XCTAssertEqual(old.cancels, 1)
            XCTAssertEqual(fresh.cancels, 0)
            XCTAssertTrue(old.receives.isEmpty)
            XCTAssertTrue(h.transport.isWritable)
        }
    }

    func testLateSendCompletionCannotAdvanceNewConnectionBatch() {
        let h = Harness()
        let old = h.open()
        var oldCompletions = 0
        var freshCompletions = 0
        h.run { h.transport.sendBatch([.text("old")]) { _ in oldCompletions += 1 } }
        let callback = h.queue.sync { old.sends[0] }
        h.run { h.transport.abort() }
        let fresh = h.open()
        h.run { h.transport.sendBatch([.text("new")]) { _ in freshCompletions += 1 } }
        callback(nil)
        callback(TestError.failed)
        h.drain()
        h.run { XCTAssertEqual(oldCompletions, 1); XCTAssertEqual(freshCompletions, 0); XCTAssertEqual(fresh.cancels, 0) }
        h.sendFinished(fresh)
        h.run { XCTAssertEqual(freshCompletions, 1) }
    }

    func testDuplicateSendCompletionDoesNotSkipNextAttachment() {
        let h = Harness()
        let c = h.open()
        var completions = 0
        h.run { h.transport.sendBatch([.text("header"), .binary(Data([1]))]) { _ in completions += 1 } }
        let callback = h.queue.sync { c.sends[0] }
        h.sendFinished(c)
        callback(nil)
        h.drain()
        h.run { XCTAssertEqual(completions, 0); XCTAssertEqual(c.sent.count, 2) }
        h.sendFinished(c)
        h.run { XCTAssertEqual(completions, 1) }
    }

    func testLateReceiveAfterReconnectIsIgnored() {
        let h = Harness()
        let old = h.open()
        let callback = h.queue.sync { old.receives[0] }
        h.run { h.transport.abort() }
        _ = h.open()
        callback(.success(.text("stale")))
        callback(.failure(TestError.failed))
        h.drain()
        h.run { XCTAssertTrue(h.log.messages.isEmpty); XCTAssertEqual(h.log.terminals, 1); XCTAssertTrue(h.transport.isWritable) }
    }

    func testReceiveLoopDeliversUnicodeAndBinaryOnce() {
        let h = Harness()
        let c = h.open()
        let callback = h.queue.sync { c.receives[0] }
        h.receiveFinished(c, .success(.text("Grüße 👋")))
        callback(.success(.text("duplicate")))
        h.drain()
        h.run { XCTAssertEqual(c.receives.count, 1) }
        h.receiveFinished(c, .success(.binary(Data([0, 255]))))
        h.run {
            XCTAssertEqual(h.log.messages, [.text("Grüße 👋"), .binary(Data([0, 255]))])
            XCTAssertEqual(c.receives.count, 1)
        }
    }

    func testReceiveAndDelegateFailuresProduceOneTerminalEvent() {
        let h = Harness()
        let c = h.open()
        let callback = h.queue.sync { c.onEvent! }
        h.receiveFinished(c, .failure(TestError.failed))
        callback(.closed(code: 1006, reason: nil, error: TestError.failed))
        callback(.closed(code: nil, reason: nil, error: nil))
        h.drain()
        h.run { XCTAssertEqual(h.log.terminals, 1); XCTAssertEqual(c.cancels, 1); XCTAssertFalse(h.transport.isWritable) }
    }

    func testByteLimitCountsUTF8AndReleasesCapacityAfterCompletion() {
        let h = Harness(bytes: 4)
        let c = h.open()
        var failures = 0
        h.run {
            h.transport.sendBatch([.text("👋")]) { _ in }
            h.transport.sendBatch([.text("a")]) { result in
                if case .failure(EngineWebSocketError.queueLimitExceeded) = result { failures += 1 }
            }
            XCTAssertEqual(c.sent.count, 1)
        }
        h.sendFinished(c)
        h.run {
            h.transport.sendBatch([.binary(Data([1, 2, 3, 4]))]) { _ in }
            XCTAssertEqual(failures, 1)
            XCTAssertEqual(c.sent.count, 2)
            XCTAssertEqual(h.log.terminals, 0)
        }
    }

    func testBatchCountLimitAlsoBoundsZeroByteMessages() {
        let h = Harness(batches: 1)
        _ = h.open()
        var failures = 0
        h.run {
            h.transport.sendBatch([.text("")]) { _ in }
            h.transport.sendBatch([.text("")]) { result in
                if case .failure(EngineWebSocketError.queueLimitExceeded) = result { failures += 1 }
            }
            XCTAssertEqual(failures, 1)
        }
    }

    func testMessageCountLimitBoundsManyEmptyMessagesInOneBatch() {
        let h = Harness(messages: 2)
        let c = h.open()
        var failures = 0
        h.run {
            h.transport.sendBatch([.text(""), .text(""), .text("")]) { result in
                if case .failure(EngineWebSocketError.queueLimitExceeded) = result { failures += 1 }
            }
            XCTAssertEqual(failures, 1)
            XCTAssertTrue(c.sent.isEmpty)
            h.transport.sendBatch([.text(""), .text("")]) { _ in }
        }
        h.sendFinished(c)
        h.sendFinished(c)
        h.run {
            h.transport.sendBatch([.text(""), .text("")]) { _ in }
            XCTAssertEqual(c.sent.count, 3)
        }
    }

    func testOversizedBatchIsRejectedAtomicallyWithoutSendingHeader() {
        let h = Harness(bytes: 4)
        let c = h.open()
        var failures = 0
        h.run {
            h.transport.sendBatch([.text("head"), .binary(Data([1]))]) { result in
                if case .failure(EngineWebSocketError.queueLimitExceeded) = result { failures += 1 }
            }
            XCTAssertEqual(failures, 1)
            XCTAssertTrue(c.sent.isEmpty)
            XCTAssertTrue(h.transport.isWritable)
        }
    }

    func testEmptyBatchCompletionPreservesFIFO() {
        let h = Harness()
        let c = h.open()
        var completed = [String]()
        h.run {
            h.transport.sendBatch([.text("first")]) { _ in completed.append("first") }
            h.transport.sendBatch([]) { _ in completed.append("empty") }
            XCTAssertTrue(completed.isEmpty)
        }
        h.sendFinished(c)
        h.run { XCTAssertEqual(completed, ["first", "empty"]); XCTAssertEqual(c.sent.count, 1) }
    }

    func testCloseDrainsCompletionsExactlyOnceAndUsesCloseNotCancel() {
        let h = Harness()
        let c = h.open()
        var completions = 0
        h.run {
            h.transport.sendBatch([.text("one")]) { result in
                if case .failure = result { completions += 1 }
            }
            h.transport.sendBatch([.text("two")]) { result in
                if case .failure = result { completions += 1 }
            }
            h.transport.close(code: 1000, reason: nil)
            h.transport.abort()
            h.transport.close(code: 1000, reason: nil)
            XCTAssertEqual(c.closes, [1000])
            XCTAssertEqual(c.cancels, 0)
            XCTAssertEqual(h.log.terminals, 1)
            XCTAssertEqual(completions, 2)
        }
        h.sendFinished(c)
        h.run { XCTAssertEqual(completions, 2) }
    }

    func testCloseBeforeOpenCancelsHandshake() {
        let h = Harness()
        let c = h.connect()
        h.run {
            h.transport.close(code: 1000, reason: nil)
            XCTAssertEqual(c.cancels, 1)
            XCTAssertTrue(c.closes.isEmpty)
        }
    }

    func testInvalidCloseCodeOrOversizedReasonCancelsInsteadOfSendingInvalidFrame() {
        for (code, reason) in [(1006, Data()), (1000, Data(repeating: 0, count: 124))] {
            let h = Harness()
            let c = h.open()
            h.run {
                h.transport.close(code: code, reason: reason)
                XCTAssertEqual(c.cancels, 1)
                XCTAssertTrue(c.closes.isEmpty)
                XCTAssertEqual(h.log.terminals, 1)
            }
        }
    }

    func testSendBeforeOpenAndAfterAbortFailsLocally() {
        let h = Harness()
        var failures = 0
        let completion: (Result<Void, Error>) -> Void = { result in
            if case .failure(EngineWebSocketError.notOpen) = result { failures += 1 }
        }
        h.run { h.transport.sendBatch([.text("idle")], completion: completion) }
        _ = h.connect()
        h.run {
            h.transport.sendBatch([.text("connecting")], completion: completion)
            h.transport.abort()
            h.transport.sendBatch([.text("closed")], completion: completion)
            XCTAssertEqual(failures, 3)
        }
    }

    func testReentrantCompletionCannotOvertakeAlreadyQueuedBatch() {
        let h = Harness()
        let c = h.open()
        h.run {
            h.transport.sendBatch([.text("A")]) { _ in h.transport.sendBatch([.text("C")]) { _ in } }
            h.transport.sendBatch([.text("B")]) { _ in }
        }
        h.sendFinished(c)
        h.sendFinished(c)
        h.sendFinished(c)
        h.run { XCTAssertEqual(c.sent, [.text("A"), .text("B"), .text("C")]) }
    }

    func testOpenHandlerCanAbortWithoutStartingReceive() {
        let h = Harness()
        h.run {
            h.transport.onEvent = { event in
                if case .opened = event { h.transport.abort() }
            }
        }
        let c = h.open()
        h.run {
            XCTAssertEqual(c.cancels, 1)
            XCTAssertTrue(c.receives.isEmpty)
            h.transport.onEvent = nil
        }
    }

    func testDuplicateConnectDoesNotCreateAnotherSession() {
        let h = Harness()
        let c = h.connect()
        h.run { h.transport.connect(); XCTAssertEqual(h.log.connections.count, 1); XCTAssertEqual(c.starts, 1) }
    }

    func testDroppingTransportSchedulesCleanupAndPendingCompletionsOnEngineQueue() {
        let queue = DispatchQueue(label: "native-transport-release-test")
        let c = Connection()
        var completions = 0
        var transport: URLSessionWebSocketTransport? = URLSessionWebSocketTransport(queue: queue) { c }
        weak var weakTransport = transport
        queue.sync { transport?.connect() }
        let callback = queue.sync { c.onEvent! }
        callback(.opened(protocol: nil))
        queue.sync {}
        queue.sync {
            transport?.sendBatch([.text("pending")]) { result in
                dispatchPrecondition(condition: .onQueue(queue))
                if case .failure = result { completions += 1 }
            }
        }
        transport = nil
        queue.sync {}
        XCTAssertNil(weakTransport)
        queue.sync { XCTAssertEqual(c.cancels, 1); XCTAssertEqual(completions, 1) }
    }
}
