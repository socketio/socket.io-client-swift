//
//  SocketIOClient.swift
//  Socket.IO-Client-Swift
//
//  Created by Erik Little on 11/23/14.
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

public final class SocketIOClient : NSObject, SocketEngineClient, SocketParsable {
    public let socketURL: NSURL

    public private(set) var engine: SocketEngineSpec?
    public private(set) var status = SocketIOClientStatus.notConnected {
        didSet {
            switch status {
            case .connected:
                reconnecting = false
                currentReconnectAttempt = 0
            default:
                break
            }
        }
    }

    public var forceNew = false
    public var nsp = "/"
    public var options: Set<SocketIOClientOption>
    public var reconnects = true
    public var reconnectWait = 10
    public var sid: String? {
        return nsp + "#" + (engine?.sid ?? "")
    }

    private let emitQueue = dispatch_queue_create("com.socketio.emitQueue", DISPATCH_QUEUE_SERIAL)!
    private let logType = "SocketIOClient"
    private let parseQueue = dispatch_queue_create("com.socketio.parseQueue", DISPATCH_QUEUE_SERIAL)!

    private var anyHandler: ((SocketAnyEvent) -> Void)?
    private var currentReconnectAttempt = 0
    private var handlers = [SocketEventHandler]()
    private var ackHandlers = SocketAckManager()
    private var reconnecting = false

    private(set) var currentAck = -1
    private(set) var handleQueue = dispatch_get_main_queue()!
    private(set) var reconnectAttempts = -1

    var waitingPackets = [SocketPacket]()
    
    /// Type safe way to create a new SocketIOClient. opts can be omitted
    public init(socketURL: NSURL, options: Set<SocketIOClientOption> = []) {
        self.options = options
        self.socketURL = socketURL
        
        if socketURL.absoluteString.hasPrefix("https://") {
            self.options.insertIgnore(element: .secure(true))
        }
        
        for option in options {
            switch option {
            case let .reconnects(reconnects):
                self.reconnects = reconnects
            case let .reconnectAttempts(attempts):
                reconnectAttempts = attempts
            case let .reconnectWait(wait):
                reconnectWait = abs(wait)
            case let .nsp(nsp):
                self.nsp = nsp
            case let .log(log):
                DefaultSocketLogger.Logger.log = log
            case let .logger(logger):
                DefaultSocketLogger.Logger = logger
            case let .handleQueue(queue):
                handleQueue = queue
            case let .forceNew(force):
                forceNew = force
            default:
                continue
            }
        }
        
        self.options.insertIgnore(element: .path("/socket.io/"))
        
        super.init()
    }
    
    /// Not so type safe way to create a SocketIOClient, meant for Objective-C compatiblity.
    /// If using Swift it's recommended to use `init(socketURL: NSURL, options: Set<SocketIOClientOption>)`
    public convenience init(socketURL: NSURL, options: NSDictionary?) {
        self.init(socketURL: socketURL, options: options?.toSocketOptionsSet() ?? [])
    }

    deinit {
        DefaultSocketLogger.Logger.log("Client is being released", type: logType)
        engine?.disconnect(reason: "Client Deinit")
    }

    private func addEngine() -> SocketEngineSpec {
        DefaultSocketLogger.Logger.log("Adding engine", type: logType, args: "")

        engine = SocketEngine(client: self, url: socketURL, options: options)

        return engine!
    }

    /// Connect to the server.
    public func connect() {
        connect(timeoutAfter: 0, handleWith: nil)
    }

    /// Connect to the server. If we aren't connected after timeoutAfter, call handler
    public func connect(timeoutAfter: Int, handleWith handler: (() -> Void)?) {
        assert(timeoutAfter >= 0, "Invalid timeout: \(timeoutAfter)")

        guard status != .connected else {
            DefaultSocketLogger.Logger.log("Tried connecting on an already connected socket", type: logType)
            return
        }

        status = .connecting

        if engine == nil || forceNew {
            addEngine().connect()
        } else {
            engine?.connect()
        }
        
        guard timeoutAfter != 0 else { return }

        let time = dispatch_time(DISPATCH_TIME_NOW, Int64(timeoutAfter) * Int64(NSEC_PER_SEC))

        dispatch_after(time, handleQueue) {[weak self] in
            if let this = self where this.status != .connected && this.status != .disconnected {
                this.status = .disconnected
                this.engine?.disconnect(reason: "Connect timeout")

                handler?()
            }
        }
    }

    private func createOnAck(items: [AnyObject]) -> OnAckCallback {
        currentAck += 1

        return {[weak self, ack = currentAck] timeout, callback in
            if let this = self {
                this.ackHandlers.addAck(ack, callback: callback)
                this._emit(data: items, ack: ack)

                if timeout != 0 {
                    let time = dispatch_time(DISPATCH_TIME_NOW, Int64(timeout * NSEC_PER_SEC))

                    dispatch_after(time, this.handleQueue) {
                        this.ackHandlers.timeoutAck(ack)
                    }
                }
            }
        }
    }

    func didConnect() {
        DefaultSocketLogger.Logger.log("Socket connected", type: logType)
        status = .connected

        // Don't handle as internal because something crazy could happen where
        // we disconnect before it's handled
        handleEvent("connect", data: [], isInternalMessage: false)
    }

    func didDisconnect(reason: String) {
        guard status != .disconnected else { return }

        DefaultSocketLogger.Logger.log("Disconnected: %@", type: logType, args: reason)

        status = .disconnected

        // Make sure the engine is actually dead.
        engine?.disconnect(reason: reason)
        handleEvent("disconnect", data: [reason as AnyObject], isInternalMessage: true)
    }

    /// Disconnects the socket.
    public func disconnect() {
        assert(status != .notConnected, "Tried closing a NotConnected client")
        
        DefaultSocketLogger.Logger.log("Closing socket", type: logType)

        didDisconnect(reason: "Disconnect")
    }

    /// Send a message to the server
    public func emit(_ event: String, _ items: SocketData...) {
        emit(event, with: socketDataToAnyObject(data: items))
    }

    /// Same as emit, but meant for Objective-C
    public func emit(_ event: String, with items: [AnyObject]) {
        guard status == .connected else {
            handleEvent("error", data: ["Tried emitting \(event) when not connected" as AnyObject], isInternalMessage: true)
            return
        }
        
        _emit(data: [event as AnyObject] + items)
    }

    /// Sends a message to the server, requesting an ack. Use the onAck method of SocketAckHandler to add
    /// an ack.
    public func emitWithAck(_ event: String, _ items: SocketData...) -> OnAckCallback {
        return emitWithAck(event, with: socketDataToAnyObject(data: items))
    }

    /// Same as emitWithAck, but for Objective-C
    public func emitWithAck(_ event: String, with items: [AnyObject]) -> OnAckCallback {
        return createOnAck(items: [event as AnyObject] + items)
    }

    private func _emit(data: [AnyObject], ack: Int? = nil) {
        dispatch_async(emitQueue) {
            guard self.status == .connected else {
                self.handleEvent("error", data: ["Tried emitting when not connected"], isInternalMessage: true)
                return
            }
            
            let packet = SocketPacket.packetFromEmit(items: data, id: ack ?? -1, nsp: self.nsp, ack: false)
            let str = packet.packetString
            
            DefaultSocketLogger.Logger.log("Emitting: %@", type: self.logType, args: str)
            
            self.engine?.send(str, withData: packet.binary)
        }
    }

    // If the server wants to know that the client received data
    func emitAck(_ ack: Int, with items: [AnyObject]) {
        dispatch_async(emitQueue) {
            if self.status == .connected {
                let packet = SocketPacket.packetFromEmit(items: items, id: ack ?? -1, nsp: self.nsp, ack: true)
                let str = packet.packetString

                DefaultSocketLogger.Logger.log("Emitting Ack: %@", type: self.logType, args: str)

                self.engine?.send(str, withData: packet.binary)
            }
        }
    }

    public func engineDidClose(reason: String) {
        waitingPackets.removeAll()
        
        if status != .disconnected {
            status = .notConnected
        }

        if status == .disconnected || !reconnects {
            didDisconnect(reason: reason)
        } else if !reconnecting {
            reconnecting = true
            tryReconnect(reason: reason)
        }
    }

    /// error
    public func engineDidError(reason: String) {
        DefaultSocketLogger.Logger.error("%@", type: logType, args: reason)

        handleEvent("error", data: [reason as AnyObject], isInternalMessage: true)
    }
    
    public func engineDidOpen(reason: String) {
        DefaultSocketLogger.Logger.log(reason, type: "SocketEngineClient")
    }

    // Called when the socket gets an ack for something it sent
    func handleAck(_ ack: Int, data: [AnyObject]) {
        guard status == .connected else { return }

        DefaultSocketLogger.Logger.log("Handling ack: %@ with data: %@", type: logType, args: ack, data)

        ackHandlers.executeAck(ack, items: data)
    }

    /// Causes an event to be handled. Only use if you know what you're doing.
    public func handleEvent(_ event: String, data: [AnyObject], isInternalMessage: Bool, withAck ack: Int = -1) {
        guard status == .connected || isInternalMessage else { return }

        DefaultSocketLogger.Logger.log("Handling event: %@ with data: %@", type: logType, args: event, data ?? "")

        dispatch_async(handleQueue) {
            self.anyHandler?(SocketAnyEvent(event: event, items: data))

            for handler in self.handlers where handler.event == event {
                handler.executeCallback(items: data, withAck: ack, withSocket: self)
            }
        }
    }

    /// Leaves nsp and goes back to /
    public func leaveNamespace() {
        if nsp != "/" {
            engine?.send("1\(nsp)", withData: [])
            nsp = "/"
        }
    }

    /// Joins namespace
    public func joinNamespace(_ namespace: String) {
        nsp = namespace

        if nsp != "/" {
            DefaultSocketLogger.Logger.log("Joining namespace", type: logType)
            engine?.send("0\(nsp)", withData: [])
        }
    }

    /// Removes handler(s) based on name
    public func off(event: String) {
        DefaultSocketLogger.Logger.log("Removing handler for event: %@", type: logType, args: event)

        handlers = handlers.filter({ $0.event != event })
    }

    /// Removes a handler with the specified UUID gotten from an `on` or `once`
    public func off(id: NSUUID) {
        DefaultSocketLogger.Logger.log("Removing handler with id: %@", type: logType, args: id)

        handlers = handlers.filter({ $0.id != id })
    }

    /// Adds a handler for an event.
    /// Returns: A unique id for the handler
    @discardableResult
    public func on(_ event: String, callback: NormalCallback) -> NSUUID {
        DefaultSocketLogger.Logger.log("Adding handler for event: %@", type: logType, args: event)

        let handler = SocketEventHandler(event: event, id: NSUUID(), callback: callback)
        handlers.append(handler)

        return handler.id
    }

    /// Adds a single-use handler for an event.
    /// Returns: A unique id for the handler
    @discardableResult
    public func once(event: String, callback: NormalCallback) -> NSUUID {
        DefaultSocketLogger.Logger.log("Adding once handler for event: %@", type: logType, args: event)

        let id = NSUUID()

        let handler = SocketEventHandler(event: event, id: id) {[weak self] data, ack in
            guard let this = self else { return }
            this.off(id: id)
            callback(data, ack)
        }

        handlers.append(handler)

        return handler.id
    }

    /// Adds a handler that will be called on every event.
    public func onAny(handler: (SocketAnyEvent) -> Void) {
        anyHandler = handler
    }

    public func parseEngineMessage(_ msg: String) {
        DefaultSocketLogger.Logger.log("Should parse message: %@", type: "SocketIOClient", args: msg)

        dispatch_async(parseQueue) {
            self.parseSocketMessage(msg)
        }
    }

    public func parseEngineBinaryData(_ data: NSData) {
        dispatch_async(parseQueue) {
            self.parseBinaryData(data)
        }
    }

    /// Tries to reconnect to the server.
    public func reconnect() {
        guard !reconnecting else { return }
        
        engine?.disconnect(reason: "manual reconnect")
    }

    /// Removes all handlers.
    /// Can be used after disconnecting to break any potential remaining retain cycles.
    public func removeAllHandlers() {
        handlers.removeAll(keepingCapacity: false)
    }
    
    func socketDataToAnyObject(data: [SocketData]) -> [AnyObject] {
        return data.flatMap({$0 as? AnyObject})
    }

    private func tryReconnect(reason: String) {
        if reconnecting {
            DefaultSocketLogger.Logger.log("Starting reconnect", type: logType)
            handleEvent("reconnect", data: [reason as AnyObject], isInternalMessage: true)
            
            _tryReconnect()
        }
    }

    private func _tryReconnect() {
        if !reconnecting {
            return
        }

        if reconnectAttempts != -1 && currentReconnectAttempt + 1 > reconnectAttempts || !reconnects {
            return didDisconnect(reason: "Reconnect Failed")
        }

        DefaultSocketLogger.Logger.log("Trying to reconnect", type: logType)
        handleEvent("reconnectAttempt", data: [(reconnectAttempts - currentReconnectAttempt) as AnyObject],
            isInternalMessage: true)

        currentReconnectAttempt += 1
        connect()
        
        let dispatchAfter = dispatch_time(DISPATCH_TIME_NOW, Int64(UInt64(reconnectWait) * NSEC_PER_SEC))
        
        dispatch_after(dispatchAfter, dispatch_get_main_queue(), _tryReconnect)
    }
}

// Test extensions
extension SocketIOClient {
    var testHandlers: [SocketEventHandler] {
        return handlers
    }

    func setTestable() {
        status = .connected
    }

    func setTestEngine(engine: SocketEngineSpec?) {
        self.engine = engine
    }

    func emitTest(event: String, _ data: AnyObject...) {
        self._emit(data: [event as AnyObject] + data)
    }
}
