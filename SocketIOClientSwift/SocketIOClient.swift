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

public final class SocketIOClient: NSObject, SocketEngineClient, SocketLogClient {
    private var anyHandler: ((SocketAnyEvent) -> Void)?
    private var currentReconnectAttempt = 0
    private var handlers = ContiguousArray<SocketEventHandler>()
    private var connectParams: [String: AnyObject]?
    private var reconnectTimer: NSTimer?
    
    let reconnectAttempts: Int!
    let logType = "SocketClient"
    var ackHandlers = SocketAckManager()
    var currentAck = -1
    var waitingData = [SocketPacket]()
    
    public let emitQueue = dispatch_queue_create("emitQueue", DISPATCH_QUEUE_SERIAL)
    public let handleQueue: dispatch_queue_t!
    public let socketURL: String
    
    public private(set) var engine: SocketEngine?
    public private(set) var secure = false
    public private(set) var status = SocketIOClientStatus.NotConnected
    
    public var nsp = "/"
    public var opts: [String: AnyObject]?
    public var reconnects = true
    public var reconnectWait = 10
    public var sid: String? {
        return engine?.sid
    }
    
    /**
    Create a new SocketIOClient. opts can be omitted
    */
    public init(var socketURL: String, opts: [String: AnyObject]? = nil) {
        if socketURL["https://"].matches().count != 0 {
            self.secure = true
        }
        
        socketURL = socketURL["http://"] ~= ""
        socketURL = socketURL["https://"] ~= ""
        
        self.socketURL = socketURL
        self.opts = opts
        
        if let connectParams = opts?["connectParams"] as? [String: AnyObject] {
            self.connectParams = connectParams
        }
        
        if let log = opts?["log"] as? Bool {
            SocketLogger.log = log
        }
        
        if let nsp = opts?["nsp"] as? String {
            self.nsp = nsp
        }
        
        if let reconnects = opts?["reconnects"] as? Bool {
            self.reconnects = reconnects
        }
        
        if let reconnectAttempts = opts?["reconnectAttempts"] as? Int {
            self.reconnectAttempts = reconnectAttempts
        } else {
            self.reconnectAttempts = -1
        }
        
        if let reconnectWait = opts?["reconnectWait"] as? Int {
            self.reconnectWait = abs(reconnectWait)
        }
        
        if let handleQueue = opts?["handleQueue"] as? dispatch_queue_t {
            self.handleQueue = handleQueue
        } else {
            self.handleQueue = dispatch_get_main_queue()
        }
        
        super.init()
    }
    
    deinit {
        SocketLogger.log("Client is being deinit", client: self)
        engine?.close(fast: true)
    }
    
    private func addEngine() {
        SocketLogger.log("Adding engine", client: self)
        
        engine = SocketEngine(client: self, opts: opts)
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
    public func close(fast fast: Bool) {
        SocketLogger.log("Closing socket", client: self)
        
        reconnects = false
        status = SocketIOClientStatus.Closed
        engine?.close(fast: fast)
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
    public func connect(timeoutAfter timeoutAfter:Int,
        withTimeoutHandler handler:(() -> Void)?) {
            guard status != SocketIOClientStatus.Connected else {
                return
            }
            if status == SocketIOClientStatus.Closed {
                SocketLogger.log("Warning! This socket was previously closed. This might be dangerous!", client: self)
            }
            
            status = SocketIOClientStatus.Connecting
            addEngine()
            engine?.open(connectParams)
            
            guard timeoutAfter != 0 else {
                return
            }
            
            let time = dispatch_time(DISPATCH_TIME_NOW, Int64(timeoutAfter) * Int64(NSEC_PER_SEC))
            
            dispatch_after(time, dispatch_get_main_queue()) {[weak self] in
                if let this = self where this.status != SocketIOClientStatus.Connected {
                    this.status = SocketIOClientStatus.Closed
                    this.engine?.close(fast: true)
                    
                    handler?()
                }
            }
    }
    
    private func createOnAck(items: [AnyObject]) -> OnAckCallback {
        return {[weak self, ack = ++currentAck] timeout, callback in
            if let this = self {
                this.ackHandlers.addAck(ack, callback: callback)
                
                dispatch_async(this.emitQueue) {[weak this] in
                    this?._emit(items, ack: ack)
                }
                
                if timeout != 0 {
                    let time = dispatch_time(DISPATCH_TIME_NOW, Int64(timeout * NSEC_PER_SEC))
                    
                    dispatch_after(time, dispatch_get_main_queue()) {[weak this] in
                        this?.ackHandlers.timeoutAck(ack)
                    }
                }
            }
        }
    }
    
    func didConnect() {
        SocketLogger.log("Socket connected", client: self)
        status = SocketIOClientStatus.Connected
        currentReconnectAttempt = 0
        clearReconnectTimer()
        
        // Don't handle as internal because something crazy could happen where
        // we disconnect before it's handled
        handleEvent("connect", data: nil, isInternalMessage: false)
    }
    
    func didDisconnect(reason:String) {
        guard status != SocketIOClientStatus.Closed else {
            return
        }
        
        SocketLogger.log("Disconnected: %@", client: self, args: reason)
        
        status = SocketIOClientStatus.Closed
        
        reconnects = false
        
        // Make sure the engine is actually dead.
        engine?.close(fast: true)
        handleEvent("disconnect", data: [reason], isInternalMessage: true)
    }
    
    /// error
    public func didError(reason: AnyObject) {
        SocketLogger.err("%@", client: self, args: reason)
        
        handleEvent("error", data: reason as? [AnyObject] ?? [reason],
            isInternalMessage: true)
    }
    
    /**
    Same as close
    */
    public func disconnect(fast fast: Bool) {
        close(fast: fast)
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
        guard status == SocketIOClientStatus.Connected else {
            return
        }
        
        dispatch_async(emitQueue) {[weak self] in
            self?._emit([event] + items)
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
        guard status == SocketIOClientStatus.Connected else {
            return
        }
        
        let packet = SocketPacket.packetFromEmit(data, id: ack ?? -1, nsp: nsp, ack: false)
        let str = packet.packetString
        
        SocketLogger.log("Emitting: %@", client: self, args: str)
        
        if packet.type == SocketPacket.PacketType.BinaryEvent {
            engine?.send(str, withData: packet.binary)
        } else {
            engine?.send(str, withData: nil)
        }
    }
    
    // If the server wants to know that the client received data
    func emitAck(ack: Int, withItems items: [AnyObject]) {
        dispatch_async(emitQueue) {[weak self] in
            if let this = self where this.status == SocketIOClientStatus.Connected {
                let packet = SocketPacket.packetFromEmit(items, id: ack ?? -1, nsp: this.nsp, ack: true)
                let str = packet.packetString
                
                SocketLogger.log("Emitting Ack: %@", client: this, args: str)
                
                if packet.type == SocketPacket.PacketType.BinaryAck {
                    this.engine?.send(str, withData: packet.binary)
                } else {
                    this.engine?.send(str, withData: nil)
                }
                
            }
        }
    }
    
    public func engineDidClose(reason:String) {
        waitingData.removeAll()
        
        if status == SocketIOClientStatus.Closed || !reconnects {
            didDisconnect(reason)
        } else if status != SocketIOClientStatus.Reconnecting {
            status = SocketIOClientStatus.Reconnecting
            handleEvent("reconnect", data: [reason], isInternalMessage: true)
            tryReconnect()
        }
    }
    
    // Called when the socket gets an ack for something it sent
    func handleAck(ack: Int, data: AnyObject?) {
        SocketLogger.log("Handling ack: %@ with data: %@", client: self,
            args: ack, data ?? "")
        
        ackHandlers.executeAck(ack,
            items: (data as? [AnyObject]?) ?? (data != nil ? [data!] : nil))
    }
    
    /**
    Causes an event to be handled. Only use if you know what you're doing.
    */
    public func handleEvent(event:String, data:[AnyObject]?, isInternalMessage: Bool,
        wantsAck ack:Int? = nil) {
            guard status == SocketIOClientStatus.Connected || isInternalMessage else {
                return
            }
            // println("Should do event: \(event) with data: \(data)")
            
            SocketLogger.log("Handling event: %@ with data: %@", client: self,
                args: event, data ?? "")
            
            if anyHandler != nil {
                dispatch_async(handleQueue) {[weak self] in
                    self?.anyHandler?(SocketAnyEvent(event: event, items: data))
                }
            }
            
            for handler in handlers where handler.event == event {
                if let ack = ack {
                    dispatch_async(handleQueue) {[weak self] in
                        handler.executeCallback(data, withAck: ack, withSocket: self)
                    }
                } else {
                    dispatch_async(handleQueue) {
                        handler.executeCallback(data)
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
        SocketLogger.log("Joining namespace", client: self)
        
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
        SocketLogger.log("Removing handler for event: %@", client: self, args: event)
        
        handlers = ContiguousArray(handlers.filter {!($0.event == event)})
    }
    
    /**
    Adds a handler for an event.
    */
    public func on(event: String, callback: NormalCallback) {
        SocketLogger.log("Adding handler for event: %@", client: self, args: event)
        
        let handler = SocketEventHandler(event: event, callback: callback)
        handlers.append(handler)
    }
    
    /**
    Adds a handler for an event.
    */
    public func onObjectiveC(event: String, callback: NormalCallbackObjectiveC) {
        SocketLogger.log("Adding handler for event: %@", client: self, args: event)
        
        let handler = SocketEventHandler(event: event, callback: callback)
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
        dispatch_async(handleQueue) {[weak self] in
            if let this = self {
                SocketParser.parseSocketMessage(msg, socket: this)
            }
        }
    }
    
    public func parseBinaryData(data: NSData) {
        dispatch_async(handleQueue) {[weak self] in
            if let this = self {
                SocketParser.parseBinaryData(data, socket: this)
            }
        }
    }
    
    /**
    Tries to reconnect to the server.
    */
    public func reconnect() {
        engine?.stopPolling()
        tryReconnect()
    }
    
    private func tryReconnect() {
        if reconnectTimer == nil {
            SocketLogger.log("Starting reconnect", client: self)
            
            status = SocketIOClientStatus.Reconnecting
            
            dispatch_async(dispatch_get_main_queue()) {[weak self] in
                if let this = self {
                    this.reconnectTimer = NSTimer.scheduledTimerWithTimeInterval(Double(this.reconnectWait),
                        target: this, selector: "_tryReconnect", userInfo: nil, repeats: true)
                }
            }
        }
    }
    
    @objc private func _tryReconnect() {
        if status == SocketIOClientStatus.Connected {
            clearReconnectTimer()
            
            return
        }
        
        
        if reconnectAttempts != -1 && currentReconnectAttempt + 1 > reconnectAttempts || !reconnects {
            clearReconnectTimer()
            didDisconnect("Reconnect Failed")
            
            return
        }
        
        SocketLogger.log("Trying to reconnect", client: self)
        handleEvent("reconnectAttempt", data: [reconnectAttempts - currentReconnectAttempt],
            isInternalMessage: true)
        
        currentReconnectAttempt++
        connect()
    }
}
