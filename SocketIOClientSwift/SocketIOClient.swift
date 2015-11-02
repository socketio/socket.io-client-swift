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

public final class SocketIOClient: NSObject, SocketEngineClient {
    public let socketURL: String
    
    public private(set) var engine: SocketEngineSpec?
    public private(set) var secure = false
    public private(set) var status = SocketIOClientStatus.NotConnected
    
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
    private var handlers = ContiguousArray<SocketEventHandler>()
    private var connectParams: [String: AnyObject]?
    private var reconnectTimer: NSTimer?
    private var ackHandlers = SocketAckManager()
    
    private(set) var currentAck = -1
    private(set) var handleQueue = dispatch_get_main_queue()
    private(set) var reconnectAttempts = -1
    
    var waitingData = [SocketPacket]()
    
    /**
     Type safe way to create a new SocketIOClient. opts can be omitted
     */
    public init(var socketURL: String, options: Set<SocketIOClientOption> = []) {
        self.options = options
        
        if socketURL["https://"].matches().count != 0 {
            self.options.insertIgnore(.Secure(true))
        }
        
        socketURL = socketURL["http://"] ~= ""
        socketURL = socketURL["https://"] ~= ""
        
        self.socketURL = socketURL
        
        for option in options ?? [] {
            switch option {
            case .ConnectParams(let params):
                connectParams = params
            case .Reconnects(let reconnects):
                self.reconnects = reconnects
            case .ReconnectAttempts(let attempts):
                reconnectAttempts = attempts
            case .ReconnectWait(let wait):
                reconnectWait = abs(wait)
            case .Nsp(let nsp):
                self.nsp = nsp
            case .Log(let log):
                Logger.log = log
            case .Logger(let logger):
                Logger = logger
            case .HandleQueue(let queue):
                handleQueue = queue
            default:
                continue
            }
        }
        
        self.options.insertIgnore(.Path("/socket.io"))
        
        super.init()
    }
    
    /**
     Not so type safe way to create a SocketIOClient, meant for Objective-C compatiblity.
     If using Swift it's recommended to use `init(var socketURL: String, opts: SocketOptionsDictionary? = nil)`
     */
    public convenience init(socketURL: String, options: NSDictionary?) {
        self.init(socketURL: socketURL,
            options: Set<SocketIOClientOption>.NSDictionaryToSocketOptionsSet(options ?? [:]))
    }
    
    deinit {
        Logger.log("Client is being deinit", type: logType)
        engine?.close()
    }
    
    private func addEngine() -> SocketEngine {
        Logger.log("Adding engine", type: logType)
        
        let newEngine = SocketEngine(client: self, url: socketURL, options: options ?? [])
        
        engine = newEngine
        return newEngine
    }
    
    private func clearReconnectTimer() {
        reconnectTimer?.invalidate()
        reconnectTimer = nil
    }
    
    /**
     Closes the socket. Only reopen the same socket if you know what you're doing.
     Will turn off automatic reconnects.
     Pass true to fast if you're closing from a background task
     */
    public func close() {
        Logger.log("Closing socket", type: logType)
        
        reconnects = false
        didDisconnect("Closed")
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
    public func connect(timeoutAfter timeoutAfter: Int,
        withTimeoutHandler handler: (() -> Void)?) {
            assert(timeoutAfter >= 0, "Invalid timeout: \(timeoutAfter)")
            
            guard status != .Connected else {
                return
            }
            
            if status == .Closed {
                Logger.log("Warning! This socket was previously closed. This might be dangerous!",
                    type: logType)
            }
            
            status = SocketIOClientStatus.Connecting
            addEngine().open(connectParams)
            
            guard timeoutAfter != 0 else {
                return
            }
            
            let time = dispatch_time(DISPATCH_TIME_NOW, Int64(timeoutAfter) * Int64(NSEC_PER_SEC))
            
            dispatch_after(time, handleQueue) {[weak self] in
                if let this = self where this.status != .Connected {
                    this.status = .Closed
                    this.engine?.close()
                    
                    handler?()
                }
            }
    }
    
    private func createOnAck(items: [AnyObject]) -> OnAckCallback {
        return {[weak self, ack = ++currentAck] timeout, callback in
            if let this = self {
                this.ackHandlers.addAck(ack, callback: callback)
                
                dispatch_async(this.emitQueue) {
                    this._emit(items, ack: ack)
                }
                
                if timeout != 0 {
                    let time = dispatch_time(DISPATCH_TIME_NOW, Int64(timeout * NSEC_PER_SEC))
                    
                    dispatch_after(time, dispatch_get_main_queue()) {
                        this.ackHandlers.timeoutAck(ack)
                    }
                }
            }
        }
    }
    
    func didConnect() {
        Logger.log("Socket connected", type: logType)
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
        
        Logger.log("Disconnected: %@", type: logType, args: reason)
        
        status = .Closed
        reconnects = false
        
        // Make sure the engine is actually dead.
        engine?.close()
        handleEvent("disconnect", data: [reason], isInternalMessage: true)
    }
    
    /// error
    public func didError(reason: AnyObject) {
        Logger.error("%@", type: logType, args: reason)
        
        handleEvent("error", data: reason as? [AnyObject] ?? [reason],
            isInternalMessage: true)
    }
    
    /**
     Same as close
     */
    public func disconnect() {
        close()
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
            return
        }
        
        let packet = SocketPacket.packetFromEmit(data, id: ack ?? -1, nsp: nsp, ack: false)
        let str = packet.packetString
        
        Logger.log("Emitting: %@", type: logType, args: str)
        
        if packet.type == .BinaryEvent {
            engine?.send(str, withData: packet.binary)
        } else {
            engine?.send(str, withData: nil)
        }
    }
    
    // If the server wants to know that the client received data
    func emitAck(ack: Int, withItems items: [AnyObject]) {
        dispatch_async(emitQueue) {
            if self.status == .Connected {
                let packet = SocketPacket.packetFromEmit(items, id: ack ?? -1, nsp: self.nsp, ack: true)
                let str = packet.packetString
                
                Logger.log("Emitting Ack: %@", type: self.logType, args: str)
                
                if packet.type == SocketPacket.PacketType.BinaryAck {
                    self.engine?.send(str, withData: packet.binary)
                } else {
                    self.engine?.send(str, withData: nil)
                }
                
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
    
    // Called when the socket gets an ack for something it sent
    func handleAck(ack: Int, data: AnyObject?) {
        guard status == .Connected else {return}
        
        Logger.log("Handling ack: %@ with data: %@", type: logType, args: ack, data ?? "")
        
        ackHandlers.executeAck(ack,
            items: (data as? [AnyObject]) ?? (data != nil ? [data!] : []))
    }
    
    /**
     Causes an event to be handled. Only use if you know what you're doing.
     */
    public func handleEvent(event: String, data: [AnyObject], isInternalMessage: Bool,
        wantsAck ack: Int? = nil) {
            guard status == .Connected || isInternalMessage else {
                return
            }
            
            Logger.log("Handling event: %@ with data: %@", type: logType, args: event, data ?? "")
            
            dispatch_async(handleQueue) {
                self.anyHandler?(SocketAnyEvent(event: event, items: data))
                
                for handler in self.handlers where handler.event == event {
                    if let ack = ack {
                        handler.executeCallback(data, withAck: ack, withSocket: self)
                    } else {
                        handler.executeCallback(data, withAck: ack, withSocket: self)
                    }
                }
            }
            
    }
    
    /**
     Leaves nsp and goes back to /
     */
    public func leaveNamespace() {
        if nsp != "/" {
            engine?.send("1\(nsp)", withData: nil)
            nsp = "/"
        }
    }
    
    /**
     Joins nsp if it is not /
     */
    public func joinNamespace() {
        Logger.log("Joining namespace", type: logType)
        
        if nsp != "/" {
            engine?.send("0\(nsp)", withData: nil)
        }
    }
    
    /**
     Joins namespace /
     */
    public func joinNamespace(namespace: String) {
        self.nsp = namespace
        joinNamespace()
    }
    
    /**
     Removes handler(s)
     */
    public func off(event: String) {
        Logger.log("Removing handler for event: %@", type: logType, args: event)
        
        handlers = ContiguousArray(handlers.filter { $0.event != event })
    }
    
    /**
     Adds a handler for an event.
     */
    public func on(event: String, callback: NormalCallback) {
        Logger.log("Adding handler for event: %@", type: logType, args: event)
        
        let handler = SocketEventHandler(event: event, callback: callback)
        handlers.append(handler)
    }
    
    /**
     Adds a single-use handler for an event.
     */
    public func once(event: String, callback: NormalCallback) {
        Logger.log("Adding once handler for event: %@", type: logType, args: event)
        
        let id = NSUUID()
        
        let handler = SocketEventHandler(event: event, id: id) {[weak self] data, ack in
            guard let this = self else {return}
            this.handlers = ContiguousArray(this.handlers.filter {$0.id != id})
            callback(data, ack)
        }
        
        handlers.append(handler)
    }
    
    /**
     Removes all handlers.
     Can be used after disconnecting to break any potential remaining retain cycles.
     */
    public func removeAllHandlers() {
        handlers.removeAll(keepCapacity: false)
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
    public func open() {
        connect()
    }
    
    public func parseSocketMessage(msg: String) {
        dispatch_async(parseQueue) {
            SocketParser.parseSocketMessage(msg, socket: self)
        }
    }
    
    public func parseBinaryData(data: NSData) {
        dispatch_async(parseQueue) {
            SocketParser.parseBinaryData(data, socket: self)
        }
    }
    
    /**
     Tries to reconnect to the server.
     */
    public func reconnect() {
        tryReconnect()
    }
    
    private func tryReconnect() {
        if reconnectTimer == nil {
            Logger.log("Starting reconnect", type: logType)
            
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
        
        Logger.log("Trying to reconnect", type: logType)
        handleEvent("reconnectAttempt", data: [reconnectAttempts - currentReconnectAttempt],
            isInternalMessage: true)
        
        currentReconnectAttempt++
        connect()
    }
}

// Test extensions
extension SocketIOClient {
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
