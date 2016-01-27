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

public final class SocketIOClient: NSObject, SocketEngineClient, SocketParsable {
    public let socketURL: NSURL

    public private(set) var engine: SocketEngineSpec?
    public private(set) var status = SocketIOClientStatus.NotConnected

    public var forceNew = false
    public var nsp = "/"
    public var options: Set<SocketIOClientOption>
    public var reconnects = true
    public var reconnectWait = 10
    public var sid: String? {
        return engine?.sid
    }

    private let emitQueue = dispatch_queue_create("com.socketio.emitQueue", DISPATCH_QUEUE_SERIAL)
    private let logType = "SocketIOClient"
    private let parseQueue = dispatch_queue_create("com.socketio.parseQueue", DISPATCH_QUEUE_SERIAL)

    private var anyHandler: ((SocketAnyEvent) -> Void)?
    private var currentReconnectAttempt = 0
    private var handlers = [SocketEventHandler]()
    private var reconnectTimer: NSTimer?
    private var ackHandlers = SocketAckManager()

    private(set) var currentAck = -1
    private(set) var handleQueue = dispatch_get_main_queue()
    private(set) var reconnectAttempts = -1

    var waitingData = [SocketPacket]()
    
    /**
     Type safe way to create a new SocketIOClient. opts can be omitted
     */
    public init(socketURL: NSURL, options: Set<SocketIOClientOption> = []) {
        self.options = options
        self.socketURL = socketURL
        
        if socketURL.absoluteString.hasPrefix("https://") {
            self.options.insertIgnore(.Secure(true))
        }
        
        for option in options {
            switch option {
            case let .Reconnects(reconnects):
                self.reconnects = reconnects
            case let .ReconnectAttempts(attempts):
                reconnectAttempts = attempts
            case let .ReconnectWait(wait):
                reconnectWait = abs(wait)
            case let .Nsp(nsp):
                self.nsp = nsp
            case let .Log(log):
                DefaultSocketLogger.Logger.log = log
            case let .Logger(logger):
                DefaultSocketLogger.Logger = logger
            case let .HandleQueue(queue):
                handleQueue = queue
            case let .ForceNew(force):
                forceNew = force
            default:
                continue
            }
        }
        
        self.options.insertIgnore(.Path("/socket.io/"))
        
        super.init()
    }
    
    /**
     Not so type safe way to create a SocketIOClient, meant for Objective-C compatiblity.
     If using Swift it's recommended to use `init(socketURL: NSURL, options: Set<SocketIOClientOption>)`
     */
    public convenience init(socketURL: NSURL, options: NSDictionary?) {
        self.init(socketURL: socketURL, options: options?.toSocketOptionsSet() ?? [])
    }

    /// Please use the NSURL based init
    @available(*, deprecated=5.3)
    public convenience init(socketURLString: String, options: Set<SocketIOClientOption> = []) {
        guard let url = NSURL(string: socketURLString) else { fatalError("Incorrect url") }
        self.init(socketURL: url, options: options)
    }
    
    /// Please use the NSURL based init
    @available(*, deprecated=5.3)
    public convenience init(socketURLString: String, options: NSDictionary?) {
        guard let url = NSURL(string: socketURLString) else { fatalError("Incorrect url") }
        self.init(socketURL: url, options: options?.toSocketOptionsSet() ?? [])
    }

    deinit {
        DefaultSocketLogger.Logger.log("Client is being released", type: logType)
        engine?.close("Client Deinit")
    }

    private func addEngine() -> SocketEngineSpec {
        DefaultSocketLogger.Logger.log("Adding engine", type: logType)

        engine = SocketEngine(client: self, url: socketURL, options: options)

        return engine!
    }

    private func clearReconnectTimer() {
        reconnectTimer?.invalidate()
        reconnectTimer = nil
    }

    @available(*, deprecated=5.3)
    public func close() {
        disconnect()
    }

    /**
     Connect to the server.
     */
    public func connect() {
        connect(timeoutAfter: 0, withTimeoutHandler: nil)
    }

    /**
     Connect to the server. If we aren't connected after timeoutAfter, call handler
     */
    public func connect(timeoutAfter timeoutAfter: Int, withTimeoutHandler handler: (() -> Void)?) {
        assert(timeoutAfter >= 0, "Invalid timeout: \(timeoutAfter)")

        guard status != .Connected else {
            DefaultSocketLogger.Logger.log("Tried connecting on an already connected socket",
                type: logType)
            return
        }

        status = .Connecting

        if engine == nil || forceNew {
            addEngine().open()
        } else {
            engine?.open()
        }

        guard timeoutAfter != 0 else { return }

        let time = dispatch_time(DISPATCH_TIME_NOW, Int64(timeoutAfter) * Int64(NSEC_PER_SEC))

        dispatch_after(time, handleQueue) {[weak self] in
            if let this = self where this.status != .Connected {
                this.status = .Closed
                this.engine?.close("Connect timeout")

                handler?()
            }
        }
    }

    private func createOnAck(items: [AnyObject]) -> OnAckCallback {
        currentAck += 1

        return {[weak self, ack = currentAck] timeout, callback in
            if let this = self {
                this.ackHandlers.addAck(ack, callback: callback)

                dispatch_async(this.emitQueue) {
                    this._emit(items, ack: ack)
                }

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
        status = .Connected
        currentReconnectAttempt = 0
        clearReconnectTimer()

        // Don't handle as internal because something crazy could happen where
        // we disconnect before it's handled
        handleEvent("connect", data: [], isInternalMessage: false)
    }

    func didDisconnect(reason: String) {
        guard status != .Closed else {
            return
        }

        DefaultSocketLogger.Logger.log("Disconnected: %@", type: logType, args: reason)

        status = .Closed
        reconnects = false

        // Make sure the engine is actually dead.
        engine?.close(reason)
        handleEvent("disconnect", data: [reason], isInternalMessage: true)
    }

    /**
     Disconnects the socket. Only reconnect the same socket if you know what you're doing.
     Will turn off automatic reconnects.
     */
    public func disconnect() {
        DefaultSocketLogger.Logger.log("Closing socket", type: logType)

        reconnects = false
        didDisconnect("Disconnect")
    }

    /**
     Send a message to the server
     */
    public func emit(event: String, _ items: AnyObject...) {
        emit(event, withItems: items)
    }

    /**
     Same as emit, but meant for Objective-C
     */
    public func emit(event: String, withItems items: [AnyObject]) {
        guard status == .Connected else {
            handleEvent("error", data: ["Tried emitting \(event) when not connected"], isInternalMessage: true)
            return
        }

        dispatch_async(emitQueue) {
            self._emit([event] + items)
        }
    }

    /**
     Sends a message to the server, requesting an ack. Use the onAck method of SocketAckHandler to add
     an ack.
     */
    public func emitWithAck(event: String, _ items: AnyObject...) -> OnAckCallback {
        return emitWithAck(event, withItems: items)
    }

    /**
     Same as emitWithAck, but for Objective-C
     */
    public func emitWithAck(event: String, withItems items: [AnyObject]) -> OnAckCallback {
        return createOnAck([event] + items)
    }

    private func _emit(data: [AnyObject], ack: Int? = nil) {
        guard status == .Connected else {
            handleEvent("error", data: ["Tried emitting when not connected"], isInternalMessage: true)
            return
        }

        let packet = SocketPacket.packetFromEmit(data, id: ack ?? -1, nsp: nsp, ack: false)
        let str = packet.packetString

        DefaultSocketLogger.Logger.log("Emitting: %@", type: logType, args: str)

        engine?.send(str, withData: packet.binary)
    }

    // If the server wants to know that the client received data
    func emitAck(ack: Int, withItems items: [AnyObject]) {
        dispatch_async(emitQueue) {
            if self.status == .Connected {
                let packet = SocketPacket.packetFromEmit(items, id: ack ?? -1, nsp: self.nsp, ack: true)
                let str = packet.packetString

                DefaultSocketLogger.Logger.log("Emitting Ack: %@", type: self.logType, args: str)

                self.engine?.send(str, withData: packet.binary)
            }
        }
    }

    public func engineDidClose(reason: String) {
        waitingData.removeAll()

        if status == .Closed || !reconnects {
            didDisconnect(reason)
        } else if status != .Reconnecting {
            status = .Reconnecting
            handleEvent("reconnect", data: [reason], isInternalMessage: true)
            tryReconnect()
        }
    }

    /// error
    public func engineDidError(reason: String) {
        DefaultSocketLogger.Logger.error("%@", type: logType, args: reason)

        handleEvent("error", data: [reason], isInternalMessage: true)
    }

    // Called when the socket gets an ack for something it sent
    func handleAck(ack: Int, data: [AnyObject]) {
        guard status == .Connected else {return}

        DefaultSocketLogger.Logger.log("Handling ack: %@ with data: %@", type: logType, args: ack, data ?? "")

        ackHandlers.executeAck(ack, items: data)
    }

    /**
     Causes an event to be handled. Only use if you know what you're doing.
     */
    public func handleEvent(event: String, data: [AnyObject], isInternalMessage: Bool, withAck ack: Int = -1) {
        guard status == .Connected || isInternalMessage else {
            return
        }

        DefaultSocketLogger.Logger.log("Handling event: %@ with data: %@", type: logType, args: event, data ?? "")

        dispatch_async(handleQueue) {
            self.anyHandler?(SocketAnyEvent(event: event, items: data))

            for handler in self.handlers where handler.event == event {
                handler.executeCallback(data, withAck: ack, withSocket: self)
            }
        }
    }

    /**
     Leaves nsp and goes back to /
     */
    public func leaveNamespace() {
        if nsp != "/" {
            engine?.send("1\(nsp)", withData: [])
            nsp = "/"
        }
    }

    /**
     Joins namespace
     */
    public func joinNamespace(namespace: String) {
        nsp = namespace

        if nsp != "/" {
            DefaultSocketLogger.Logger.log("Joining namespace", type: logType)
            engine?.send("0\(nsp)", withData: [])
        }
    }

    /**
     Removes handler(s)
     */
    public func off(event: String) {
        DefaultSocketLogger.Logger.log("Removing handler for event: %@", type: logType, args: event)

        handlers = handlers.filter { $0.event != event }
    }

    /**
    Removes a handler with the specified UUID gotten from an `on` or `once`
    */
    public func off(id id: NSUUID) {
        DefaultSocketLogger.Logger.log("Removing handler with id: %@", type: logType, args: id)

        handlers = handlers.filter { $0.id != id }
    }

    /**
     Adds a handler for an event.
     Returns: A unique id for the handler
     */
    public func on(event: String, callback: NormalCallback) -> NSUUID {
        DefaultSocketLogger.Logger.log("Adding handler for event: %@", type: logType, args: event)

        let handler = SocketEventHandler(event: event, id: NSUUID(), callback: callback)
        handlers.append(handler)

        return handler.id
    }

    /**
     Adds a single-use handler for an event.
     Returns: A unique id for the handler
     */
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

    /**
     Adds a handler that will be called on every event.
     */
    public func onAny(handler: (SocketAnyEvent) -> Void) {
        anyHandler = handler
    }

    /**
     Same as connect
     */
    @available(*, deprecated=5.3)
    public func open() {
        connect()
    }

    public func parseEngineMessage(msg: String) {
        DefaultSocketLogger.Logger.log("Should parse message: %@", type: "SocketIOClient", args: msg)

        dispatch_async(parseQueue) {
            self.parseSocketMessage(msg)
        }
    }

    public func parseEngineBinaryData(data: NSData) {
        dispatch_async(parseQueue) {
            self.parseBinaryData(data)
        }
    }

    /**
     Tries to reconnect to the server.
     */
    public func reconnect() {
        tryReconnect()
    }

    /**
     Removes all handlers.
     Can be used after disconnecting to break any potential remaining retain cycles.
     */
    public func removeAllHandlers() {
        handlers.removeAll(keepCapacity: false)
    }

    private func tryReconnect() {
        if reconnectTimer == nil {
            DefaultSocketLogger.Logger.log("Starting reconnect", type: logType)

            status = .Reconnecting

            dispatch_async(dispatch_get_main_queue()) {
                self.reconnectTimer = NSTimer.scheduledTimerWithTimeInterval(Double(self.reconnectWait),
                    target: self, selector: "_tryReconnect", userInfo: nil, repeats: true)
            }
        }
    }

    @objc private func _tryReconnect() {
        if status == .Connected {
            clearReconnectTimer()

            return
        }

        if reconnectAttempts != -1 && currentReconnectAttempt + 1 > reconnectAttempts || !reconnects {
            clearReconnectTimer()
            didDisconnect("Reconnect Failed")

            return
        }

        DefaultSocketLogger.Logger.log("Trying to reconnect", type: logType)
        handleEvent("reconnectAttempt", data: [reconnectAttempts - currentReconnectAttempt],
            isInternalMessage: true)

        currentReconnectAttempt += 1
        connect()
    }
}

// Test extensions
extension SocketIOClient {
    var testHandlers: [SocketEventHandler] {
        return handlers
    }

    func setTestable() {
        status = .Connected
    }

    func setTestEngine(engine: SocketEngineSpec?) {
        self.engine = engine
    }

    func emitTest(event: String, _ data: AnyObject...) {
        self._emit([event] + data)
    }
}
