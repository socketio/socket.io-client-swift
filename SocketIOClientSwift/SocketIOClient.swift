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
    private var params:[String: AnyObject]?
    private var _secure = false
    private var _sid:String?
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
    public let handleQueue = dispatch_queue_create("handleQueue", DISPATCH_QUEUE_SERIAL)
    public let emitQueue = dispatch_queue_create("emitQueue", DISPATCH_QUEUE_SERIAL)
    public var closed:Bool {
        return self._closed
    }
    public var connected:Bool {
        return self._connected
    }
    public var connecting:Bool {
        return self._connecting
    }
    public var engine:SocketEngine?
    public var nsp = "/"
    public var opts:[String: AnyObject]?
    public var reconnects = true
    public var reconnecting:Bool {
        return self._reconnecting
    }
    public var reconnectWait = 10
    public var secure:Bool {
        return self._secure
    }
    public var sid:String? {
        return self._sid
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
            self.params = connectParams
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
        
        super.init()
    }
    
    public convenience init(socketURL:String, options:[String: AnyObject]?) {
        self.init(socketURL: socketURL, opts: options)
    }
    
    deinit {
        SocketLogger.log("Client is being deinit", client: self)
    }
    
    private func addEngine() {
        SocketLogger.log("Adding engine", client: self)
        
        self.engine = SocketEngine(client: self, opts: self.opts)
    }
    
    /**
    Closes the socket. Only reopen the same socket if you know what you're doing.
    Will turn off automatic reconnects.
    Pass true to fast if you're closing from a background task
    */
    public func close(#fast:Bool) {
        SocketLogger.log("Closing socket", client: self)
        
        self.reconnects = false
        self._connecting = false
        self._connected = false
        self._reconnecting = false
        self.engine?.close(fast: fast)
        self.engine = nil
    }
    
    /**
    Connect to the server.
    */
    public func connect() {
        self.connect(timeoutAfter: 0, withTimeoutHandler: nil)
    }
    
    /**
    Connect to the server. If we aren't connected after timeoutAfter, call handler
    */
    public func connect(#timeoutAfter:Int, withTimeoutHandler handler:(() -> Void)?) {
        if self.closed {
            SocketLogger.log("Warning! This socket was previously closed. This might be dangerous!", client: self)
            self._closed = false
        } else if self.connected {
            return
        }
        
        self.addEngine()
        self.engine?.open(opts: self.params)
        
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
        return {[weak self, ack = ++self.currentAck] timeout, callback in
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
        
        self._closed = false
        self._connected = true
        self._connecting = false
        self._reconnecting = false
        self.currentReconnectAttempt = 0
        self.reconnectTimer?.invalidate()
        self.reconnectTimer = nil
        self._sid = self.engine?.sid
        
        // Don't handle as internal because something crazy could happen where
        // we disconnect before it's handled
        self.handleEvent("connect", data: nil, isInternalMessage: false)
    }
    
    func didDisconnect(reason:String) {
        if self.closed {
            return
        }
        
        SocketLogger.log("Disconnected: \(reason)", client: self)
        
        self._closed = true
        self._connected = false
        self.reconnects = false
        self._connecting = false
        self._reconnecting = false
        
        // Make sure the engine is actually dead.
        self.engine?.close(fast: true)
        self.handleEvent("disconnect", data: [reason], isInternalMessage: true)
    }
    
    /// error
    public func didError(reason:AnyObject) {
        SocketLogger.err("Error: \(reason)", client: self)
        
        self.handleEvent("error", data: reason as? [AnyObject] ?? [reason],
            isInternalMessage: true)
    }
    
    /**
    Same as close
    */
    public func disconnect(#fast:Bool) {
        self.close(fast: fast)
    }
    
    /**
    Send a message to the server
    */
    public func emit(event:String, _ items:AnyObject...) {
        if !self.connected {
            return
        }
        
        dispatch_async(self.emitQueue) {[weak self] in
            self?._emit(event, items)
        }
    }
    
    /**
    Same as emit, but meant for Objective-C
    */
    public func emit(event:String, withItems items:[AnyObject]) {
        if !self.connected {
            return
        }
        
        dispatch_async(self.emitQueue) {[weak self] in
            self?._emit(event, items)
        }
    }
    
    /**
    Sends a message to the server, requesting an ack. Use the onAck method of SocketAckHandler to add
    an ack.
    */
    public func emitWithAck(event:String, _ items:AnyObject...) -> OnAckCallback {
        if !self.connected {
            return createOnAck(event, items: items)
        }
        
        return self.createOnAck(event, items: items)
    }
    
    /**
    Same as emitWithAck, but for Objective-C
    */
    public func emitWithAck(event:String, withItems items:[AnyObject]) -> OnAckCallback {
        if !self.connected {
            return self.createOnAck(event, items: items)
        }
        
        return self.createOnAck(event, items: items)
    }
    
    private func _emit(event:String, _ args:[AnyObject], ack:Int? = nil) {
        if !self.connected {
            return
        }
        
        let packet = SocketPacket(type: nil, data: args, nsp: self.nsp, id: ack)
        let str:String
        
        SocketParser.parseForEmit(packet)
        str = packet.createMessageForEvent(event)
        
        SocketLogger.log("Emitting: \(str)", client: self)
        
        if packet.type == SocketPacket.PacketType.BINARY_EVENT {
            self.engine?.send(str, withData: packet.binary)
        } else {
            self.engine?.send(str, withData: nil)
        }
    }
    
    // If the server wants to know that the client received data
    func emitAck(ack:Int, withData args:[AnyObject]) {
        dispatch_async(self.emitQueue) {[weak self] in
            if let this = self where this.connected {
                let packet = SocketPacket(type: nil, data: args, nsp: this.nsp, id: ack)
                let str:String
                
                SocketParser.parseForEmit(packet)
                str = packet.createAck()
                
                SocketLogger.log("Emitting Ack: \(str)", client: this)
                
                if packet.type == SocketPacket.PacketType.BINARY_ACK {
                    this.engine?.send(str, withData: packet.binary)
                } else {
                    this.engine?.send(str, withData: nil)
                }
                
            }
        }
    }
    
    public func engineDidClose(reason:String) {
        self._connected = false
        self._connecting = false
        
        if self.closed || !self.reconnects {
            self.didDisconnect("Engine closed")
        } else if !self.reconnecting {
            self.handleEvent("reconnect", data: [reason], isInternalMessage: true)
            self.tryReconnect()
        }
    }
    
    // Called when the socket gets an ack for something it sent
    func handleAck(ack:Int, data:AnyObject?) {
        SocketLogger.log("Handling ack: \(ack) with data: \(data)", client: self)
        
        self.ackHandlers.executeAck(ack,
            items: (data as? [AnyObject]?) ?? (data != nil ? [data!] : nil))
    }
    
    /**
    Causes an event to be handled. Only use if you know what you're doing.
    */
    public func handleEvent(event:String, data:[AnyObject]?, isInternalMessage:Bool = false,
        wantsAck ack:Int? = nil) {
            // println("Should do event: \(event) with data: \(data)")
            if !self.connected && !isInternalMessage {
                return
            }
            
            SocketLogger.log("Handling event: \(event) with data: \(data)", client: self)
            
            if self.anyHandler != nil {
                dispatch_async(dispatch_get_main_queue()) {[weak self] in
                    self?.anyHandler?(SocketAnyEvent(event: event, items: data))
                }
            }
            
            for handler in self.handlers {
                if handler.event == event {
                    if ack != nil {
                        handler.executeCallback(data, withAck: ack!, withSocket: self)
                    } else {
                        handler.executeCallback(data)
                    }
                }
            }
    }
    
    /**
    Leaves nsp and goes back to /
    */
    public func leaveNamespace() {
        if self.nsp != "/" {
            self.engine?.send("1/\(self.nsp)", withData: nil)
            self.nsp = "/"
        }
    }
    
    /**
    Joins nsp if it is not /
    */
    public func joinNamespace() {
        SocketLogger.log("Joining namespace", client: self)
        
        if self.nsp != "/" {
            self.engine?.send("0/\(self.nsp)", withData: nil)
        }
    }
    
    /**
    Removes handler(s)
    */
    public func off(event:String) {
        SocketLogger.log("Removing handler for event: \(event)", client: self)
        
        self.handlers = self.handlers.filter {$0.event == event ? false : true}
    }
    
    /**
    Adds a handler for an event.
    */
    public func on(name:String, callback:NormalCallback) {
        SocketLogger.log("Adding handler for event: \(name)", client: self)
        
        let handler = SocketEventHandler(event: name, callback: callback)
        self.handlers.append(handler)
    }
    
    /**
    Adds a handler that will be called on every event.
    */
    public func onAny(handler:(SocketAnyEvent) -> Void) {
        self.anyHandler = handler
    }
    
    /**
    Same as connect
    */
    public func open() {
        self.connect()
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
        self._connected = false
        self._connecting = false
        self._reconnecting = false
        
        self.engine?.stopPolling()
        self.tryReconnect()
    }
    
    // We lost connection and should attempt to reestablish
    @objc private func tryReconnect() {
        if self.reconnectAttempts != -1 && self.currentReconnectAttempt + 1 > self.reconnectAttempts {
            self.didDisconnect("Reconnect Failed")
            return
        } else if self.connected {
            self._connecting = false
            self._reconnecting = false
            return
        }
        
        if self.reconnectTimer == nil {
            SocketLogger.log("Starting reconnect", client: self)
            
            self._reconnecting = true
            
            dispatch_async(dispatch_get_main_queue()) {[weak self] in
                if let this = self {
                    this.reconnectTimer = NSTimer.scheduledTimerWithTimeInterval(Double(this.reconnectWait),
                        target: this, selector: "tryReconnect", userInfo: nil, repeats: true)
                }
            }
        }
        
        SocketLogger.log("Trying to reconnect", client: self)
        self.handleEvent("reconnectAttempt", data: [self.reconnectAttempts - self.currentReconnectAttempt],
            isInternalMessage: true)
        
        self.currentReconnectAttempt++
        self.connect()
    }
}
