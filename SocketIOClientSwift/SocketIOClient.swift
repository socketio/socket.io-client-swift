//
//  SocketIOClient.swift
//  Socket.IO-Swift
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
    private var anyHandler:((SocketAnyEvent) -> Void)?
    private var _closed = false
    private var _connected = false
    private var _connecting = false
    private var currentReconnectAttempt = 0
    private var handlers = ContiguousArray<SocketEventHandler>()
    private var connectParams:[String: AnyObject]?
    private var _secure = false
    private var _reconnecting = false
    private var reconnectTimer:NSTimer?
    
    let reconnectAttempts:Int!
    let logType = "SocketClient"
    var ackHandlers = SocketAckManager()
    var currentAck = -1
    var log = false
    var waitingData = ContiguousArray<SocketPacket>()
    var sessionDelegate:NSURLSessionDelegate?
    
    public let socketURL:String
    public let handleAckQueue = dispatch_queue_create("handleAckQueue", DISPATCH_QUEUE_SERIAL)
    public let handleQueue: dispatch_queue_attr_t!
    public let emitQueue = dispatch_queue_create("emitQueue", DISPATCH_QUEUE_SERIAL)
    public var closed:Bool {
        return _closed
    }
    public var connected:Bool {
        return _connected
    }
    public var connecting:Bool {
        return _connecting
    }
    public var engine:SocketEngine?
    public var nsp = "/"
    public var opts:[String: AnyObject]?
    public var reconnects = true
    public var reconnecting:Bool {
        return _reconnecting
    }
    public var reconnectWait = 10
    public var secure:Bool {
        return _secure
    }
    public var sid:String? {
        return engine?.sid
    }
    
    /**
    Create a new SocketIOClient. opts can be omitted
    */
    public init(var socketURL:String, opts:[String: AnyObject]? = nil) {
        if socketURL["https://"].matches().count != 0 {
            self._secure = true
        }
        
        socketURL = socketURL["http://"] ~= ""
        socketURL = socketURL["https://"] ~= ""
        
        self.socketURL = socketURL
        self.opts = opts
        
        // Set options
        if let sessionDelegate = opts?["sessionDelegate"] as? NSURLSessionDelegate {
            self.sessionDelegate = sessionDelegate
        }
        
        if let connectParams = opts?["connectParams"] as? [String: AnyObject] {
            self.connectParams = connectParams
        }
        
        if let log = opts?["log"] as? Bool {
            self.log = log
        }
        
        if var nsp = opts?["nsp"] as? String {
            if nsp != "/" && nsp.hasPrefix("/") {
                nsp.removeAtIndex(nsp.startIndex)
            }
            
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
    
    public convenience init(socketURL:String, options:[String: AnyObject]?) {
        self.init(socketURL: socketURL, opts: options)
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
    public func close(#fast:Bool) {
        SocketLogger.log("Closing socket", client: self)
        
        reconnects = false
        _connecting = false
        _connected = false
        _reconnecting = false
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
    public func connect(#timeoutAfter:Int, withTimeoutHandler handler:(() -> Void)?) {
        if closed {
            SocketLogger.log("Warning! This socket was previously closed. This might be dangerous!", client: self)
            _closed = false
        } else if connected {
            return
        }
        
        _connecting = true
        addEngine()
        engine?.open(opts: connectParams)
        
        if timeoutAfter == 0 {
            return
        }
        
        let time = dispatch_time(DISPATCH_TIME_NOW, Int64(timeoutAfter) * Int64(NSEC_PER_SEC))
        
        dispatch_after(time, dispatch_get_main_queue()) {[weak self] in
            if let this = self where !this.connected {
                this._closed = true
                this._connecting = false
                this.engine?.close(fast: true)
                
                handler?()
            }
        }
    }
    
    private func createOnAck(event:String, items:[AnyObject]) -> OnAckCallback {
        return {[weak self, ack = ++currentAck] timeout, callback in
            if let this = self {
                this.ackHandlers.addAck(ack, callback: callback)
                
                dispatch_async(this.emitQueue) {[weak this] in
                    this?._emit(event, items, ack: ack)
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
        
        _closed = false
        _connected = true
        _connecting = false
        _reconnecting = false
        currentReconnectAttempt = 0
        clearReconnectTimer()
        
        // Don't handle as internal because something crazy could happen where
        // we disconnect before it's handled
        handleEvent("connect", data: nil, isInternalMessage: false)
    }
    
    func didDisconnect(reason:String) {
        if closed {
            return
        }
        
        SocketLogger.log("Disconnected: %@", client: self, args: reason)
        
        _closed = true
        _connected = false
        reconnects = false
        _connecting = false
        _reconnecting = false
        
        // Make sure the engine is actually dead.
        engine?.close(fast: true)
        handleEvent("disconnect", data: [reason], isInternalMessage: true)
    }
    
    /// error
    public func didError(reason:AnyObject) {
        SocketLogger.err("%@", client: self, args: reason)
        
        handleEvent("error", data: reason as? [AnyObject] ?? [reason],
            isInternalMessage: true)
    }
    
    /**
    Same as close
    */
    public func disconnect(#fast:Bool) {
        close(fast: fast)
    }
    
    /**
    Send a message to the server
    */
    public func emit(event:String, _ items:AnyObject...) {
        if !connected {
            return
        }
        
        dispatch_async(emitQueue) {[weak self] in
            self?._emit(event, items)
        }
    }
    
    /**
    Same as emit, but meant for Objective-C
    */
    public func emit(event:String, withItems items:[AnyObject]) {
        if !connected {
            return
        }
        
        dispatch_async(emitQueue) {[weak self] in
            self?._emit(event, items)
        }
    }
    
    /**
    Sends a message to the server, requesting an ack. Use the onAck method of SocketAckHandler to add
    an ack.
    */
    public func emitWithAck(event:String, _ items:AnyObject...) -> OnAckCallback {
        if !connected {
            return createOnAck(event, items: items)
        }
        
        return createOnAck(event, items: items)
    }
    
    /**
    Same as emitWithAck, but for Objective-C
    */
    public func emitWithAck(event:String, withItems items:[AnyObject]) -> OnAckCallback {
        if !connected {
            return createOnAck(event, items: items)
        }
        
        return createOnAck(event, items: items)
    }
    
    private func _emit(event:String, _ args:[AnyObject], ack:Int? = nil) {
        if !connected {
            return
        }
        
        let packet = SocketPacket(type: nil, data: args, nsp: nsp, id: ack)
        let str:String
        
        SocketParser.parseForEmit(packet)
        str = packet.createMessageForEvent(event)
        
        SocketLogger.log("Emitting: %@", client: self, args: str)
        
        if packet.type == SocketPacket.PacketType.BINARY_EVENT {
            engine?.send(str, withData: packet.binary)
        } else {
            engine?.send(str, withData: nil)
        }
    }
    
    // If the server wants to know that the client received data
    func emitAck(ack:Int, withData args:[AnyObject]) {
        dispatch_async(emitQueue) {[weak self] in
            if let this = self where this.connected {
                let packet = SocketPacket(type: nil, data: args, nsp: this.nsp, id: ack)
                let str:String
                
                SocketParser.parseForEmit(packet)
                str = packet.createAck()
                
                SocketLogger.log("Emitting Ack: %@", client: this, args: str)
                
                if packet.type == SocketPacket.PacketType.BINARY_ACK {
                    this.engine?.send(str, withData: packet.binary)
                } else {
                    this.engine?.send(str, withData: nil)
                }
                
            }
        }
    }
    
    public func engineDidClose(reason:String) {
        _connected = false
        _connecting = false
        
        if closed || !reconnects {
            didDisconnect(reason)
        } else if !reconnecting {
            handleEvent("reconnect", data: [reason], isInternalMessage: true)
            tryReconnect()
        }
    }
    
    // Called when the socket gets an ack for something it sent
    func handleAck(ack:Int, data:AnyObject?) {
        SocketLogger.log("Handling ack: %@ with data: %@", client: self,
            args: ack, data ?? "")
        
        ackHandlers.executeAck(ack,
            items: (data as? [AnyObject]?) ?? (data != nil ? [data!] : nil))
    }
    
    /**
    Causes an event to be handled. Only use if you know what you're doing.
    */
    public func handleEvent(event:String, data:[AnyObject]?, isInternalMessage:Bool = false,
        wantsAck ack:Int? = nil) {
            // println("Should do event: \(event) with data: \(data)")
            if !connected && !isInternalMessage {
                return
            }
            
            SocketLogger.log("Handling event: %@ with data: %@", client: self,
                args: event, data ?? "")
            
            if anyHandler != nil {
                dispatch_async(handleQueue) {[weak self] in
                    self?.anyHandler?(SocketAnyEvent(event: event, items: data))
                }
            }
            
            for handler in handlers {
                if handler.event == event {
                    if ack != nil {
                        dispatch_async(handleQueue) {[weak self] in
                            handler.executeCallback(data, withAck: ack!, withSocket: self)
                        }
                    } else {
                        dispatch_async(handleQueue) {[weak self] in
                            handler.executeCallback(data)
                        }
                    }
                }
            }
    }
    
    /**
    Leaves nsp and goes back to /
    */
    public func leaveNamespace() {
        if nsp != "/" {
            engine?.send("1/\(nsp)", withData: nil)
            nsp = "/"
        }
    }
    
    /**
    Joins nsp if it is not /
    */
    public func joinNamespace() {
        SocketLogger.log("Joining namespace", client: self)
        
        if nsp != "/" {
            engine?.send("0/\(nsp)", withData: nil)
        }
    }
    
    /**
    Removes handler(s)
    */
    public func off(event:String) {
        SocketLogger.log("Removing handler for event: %@", client: self, args: event)
        
        handlers = handlers.filter {$0.event == event ? false : true}
    }
    
    /**
    Adds a handler for an event.
    */
    public func on(event:String, callback:NormalCallback) {
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
    public func onAny(handler:(SocketAnyEvent) -> Void) {
        anyHandler = handler
    }
    
    /**
    Same as connect
    */
    public func open() {
        connect()
    }
    
    public func parseSocketMessage(msg:String) {
        SocketParser.parseSocketMessage(msg, socket: self)
    }
    
    public func parseBinaryData(data:NSData) {
        SocketParser.parseBinaryData(data, socket: self)
    }
    
    /**
    Trieds to reconnect to the server.
    */
    public func reconnect() {
        _connected = false
        _connecting = false
        _reconnecting = false
        
        engine?.stopPolling()
        tryReconnect()
    }
    
    // We lost connection and should attempt to reestablish
    @objc private func tryReconnect() {
        if reconnectAttempts != -1 && currentReconnectAttempt + 1 > reconnectAttempts || !reconnects {
            clearReconnectTimer()
            didDisconnect("Reconnect Failed")
            
            return
        } else if connected {
            _connecting = false
            _reconnecting = false
            return
        }
        
        if reconnectTimer == nil {
            SocketLogger.log("Starting reconnect", client: self)
            
            _reconnecting = true
            
            dispatch_async(dispatch_get_main_queue()) {[weak self] in
                if let this = self {
                    this.reconnectTimer = NSTimer.scheduledTimerWithTimeInterval(Double(this.reconnectWait),
                        target: this, selector: "tryReconnect", userInfo: nil, repeats: true)
                }
            }
        }
        
        SocketLogger.log("Trying to reconnect", client: self)
        handleEvent("reconnectAttempt", data: [reconnectAttempts - currentReconnectAttempt],
            isInternalMessage: true)
        
        currentReconnectAttempt++
        connect()
    }
}
