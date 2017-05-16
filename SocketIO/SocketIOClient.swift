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

public class SocketIOClient: NSObject, SocketEngineClient {
    private lazy var params = [String: AnyObject]()
    private var anyHandler: ((SocketAnyEvent) -> Void)?
    private var _closed = false
    private var _connected = false
    private var _connecting = false
    private var currentReconnectAttempt = 0
    private var forcePolling = false
    private var forceWebsockets = false
    private var handlers = ContiguousArray<SocketEventHandler>()
    private var paramConnect = false
    private var _secure = false
    private var _sid: String?
    private var _reconnecting = false
    private var reconnectTimer: NSTimer?
    
    let reconnectAttempts: Int!
    var ackHandlers = SocketAckMap()
    var currentAck = -1
    var waitingData = ContiguousArray<SocketPacket>()
    
    public let socketURL: String
    
    public let handleAckQueue = dispatch_queue_create("handleAckQueue", DISPATCH_QUEUE_SERIAL)
    public let handleQueue = dispatch_queue_create("handleQueue", DISPATCH_QUEUE_SERIAL)
    public let emitQueue = dispatch_queue_create("emitQueue", DISPATCH_QUEUE_SERIAL)
    
    public var closed: Bool {
        return self._closed
    }
    
    public var connected: Bool {
        return self._connected
    }
    
    public var connecting: Bool {
        return self._connecting
    }
    
    public var cookies: [NSHTTPCookie]?
    public var engine: SocketEngine?
    public var nsp = "/"
    public var reconnects = true
    public var reconnecting: Bool {
        return self._reconnecting
    }
    
    public var reconnectWait = 10
    public var secure: Bool {
        return self._secure
    }
    
    public var sid: String? {
        return self._sid
    }
    
    /**
        Create a new SocketIOClient.
    
        :params: socketURL The URL of the socket
        :params: options Options to configure the SocketIOClient
    */
    public init(var socketURL: String, options: NSDictionary? = nil) {
        if socketURL["https://"].matches().count != 0 {
            self._secure = true
        }
        
        socketURL = socketURL["http://"] ~= ""
        socketURL = socketURL["https://"] ~= ""
        
        self.socketURL = socketURL
        
        // Set options
        if options != nil {
            if let cookies = options!["cookies"] as? [NSHTTPCookie] {
                self.cookies = cookies
            }
            
            if let polling = options!["forcePolling"] as? Bool {
                self.forcePolling = polling
            }
            
            if let ws = options!["forceWebsockets"] as? Bool {
                self.forceWebsockets = ws
            }
            
            if var nsp = options!["nsp"] as? String {
                if nsp != "/" && nsp.hasPrefix("/") {
                    nsp.removeAtIndex(nsp.startIndex)
                }
                
                self.nsp = nsp
            }
            
            if let reconnects = options!["reconnects"] as? Bool {
                self.reconnects = reconnects
            }
            
            if let reconnectAttempts = options!["reconnectAttempts"] as? Int {
                self.reconnectAttempts = reconnectAttempts
            } else {
                self.reconnectAttempts = -1
            }
            
            if let reconnectWait = options!["reconnectWait"] as? Int {
                self.reconnectWait = abs(reconnectWait)
            }
        } else {
            self.reconnectAttempts = -1
        }
        
        super.init()
    }
    
    /**
        Addes the SocketEngine.
     */
    private func addEngine() {
        self.engine = SocketEngine(client: self,
            forcePolling: self.forcePolling,
            forceWebsockets: self.forceWebsockets,
            withCookies: self.cookies)
    }
    
    /**
        Closes the socket. Only reopen the same socket if you know what you're doing.
        Will disable automatic reconnects.
    
        :params: fast Indicates if the socket should be closed fast. Set to true if invoking from a background thread.
    */
    public func close(#fast: Bool) {
        self.reconnects = false
        self._connecting = false
        self._connected = false
        self._reconnecting = false
        self.engine?.close(fast: fast)
    }
    
    /**
        Connect to the server.
    */
    public func connect() {
        if self.closed {
            println("Warning! This socket was previously closed. This might be dangerous!")
            self._closed = false
        }
        
        if self.connected {
            return
        }
        
        self.addEngine()
        self.engine?.open()
    }
    
    /**
        Connect to the server with params that will be passed on connection.
    
        :params: params The parameters to pass to the socket server.
    */
    public func connectWithParams(params: [String: AnyObject]) {
        if self.closed {
            println("Warning! This socket was previously closed. This might be dangerous!")
            self._closed = false
        }
        
        if self.connected {
            return
        }
        
        self.params = params
        self.paramConnect = true
        
        self.addEngine()
        self.engine?.open(opts: params)
    }
    
    private func createOnAck(event: String, items: [AnyObject]) -> OnAckCallback {
        return { [weak self, ack = ++self.currentAck] timeout, callback in
            if self == nil {
                return
            }
            
            self!.ackHandlers.addAck(ack, callback: callback)
            
            dispatch_async(self!.emitQueue) {
                self?._emit(event, items, ack: ack)
            }
            
            if timeout != 0 {
                let time = dispatch_time(DISPATCH_TIME_NOW, Int64(timeout * NSEC_PER_SEC))
                
                dispatch_after(time, dispatch_get_main_queue()) {
                    self?.ackHandlers.timeoutAck(ack)
                }
            }
        }
    }
    
    /**
        Called when the socket did connect to the server.
     */
    func didConnect() {
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
    
    /**
        Called when the socket encounters an error while connecting.
    
        :params: reason The reason for the error
     */
    public func didError(reason: AnyObject) {
        self.handleEvent("error", data: reason as? [AnyObject] ?? [reason],
            isInternalMessage: true)
    }
    
    /**
        Same as close.
    
        ???: Should we favor connect/disconnect or open/close?
    
        :params: fast Indicates if the socket should be closed fast. Set to true if invoking from a background thread.
    */
    public func disconnect(#fast:Bool) {
        self.close(fast: fast)
    }
    
    /**
        Send a message to the server.
    
        :params: event The name of the event to emit
        :params: items The items to emit with the event
    */
    public func emit(event: String, _ items: AnyObject...) {
        if !self.connected {
            return
        }
        
        dispatch_async(self.emitQueue) {[weak self] in
            self?._emit(event, items)
        }
    }
    
    /**
        Send a message to the server.
    
        Meant to be used in Objective-C.
    
        :params: event The name of the event to emit
        :params: items The items to emit with the event
    */
    public func emitObjc(event: String, withItems items: [AnyObject]) {
        if !self.connected {
            return
        }
        
        dispatch_async(self.emitQueue) {[weak self] in
            self?._emit(event, items)
        }
    }
    
    /**
        Sends a message to the server, requesting an ack. 
    
        Use the `onAck` method of `SocketAckHandler` to add an ack.
    
        :params: event The name of the event to emit
        :params: items The items to emit with the event
    
        :return: OnAckCallback
    */
    public func emitWithAck(event: String, _ items: AnyObject...) -> OnAckCallback {
        if !self.connected {
            return createOnAck(event, items: items)
        }
        
        return self.createOnAck(event, items: items)
    }
    
    /**
        Sends a message to the server, requesting an ack.
    
        Use the `onAck` method of `SocketAckHandler` to add an ack.
    
        Meant to be used in Objective-C.
    
        :params: event The name of the event to emit
        :params: items The items to emit with the event
    
        :return: OnAckCallback
    
    */
    public func emitWithAckObjc(event: String, withItems items: [AnyObject]) -> OnAckCallback {
        if !self.connected {
            return self.createOnAck(event, items: items)
        }
        
        return self.createOnAck(event, items: items)
    }
    
    /**
        Sends a message to the server.
    
        :params: event The name of the event to emit.
        :params: args The items to emit with the event.
        :params: ack If provided, the ack event to emit with the event.
     */
    private func _emit(event: String, _ args: [AnyObject], ack: Int? = nil) {
        if !self.connected {
            return
        }
        
        let packet = SocketPacket(type: nil, data: args, nsp: self.nsp, id: ack)
        let str: String
        
        SocketParser.parseForEmit(packet)
        str = packet.createMessageForEvent(event)
        
        if packet.type == SocketPacket.PacketType.BINARY_EVENT {
            self.engine?.send(str, withData: packet.binary)
        } else {
            self.engine?.send(str, withData: nil)
        }
    }
    
    // If the server wants to know that the client received data
    /**
        Emits an ack event to the server.
    
        :params: ack The event to emit
        :params: args The data to emit
     */
    func emitAck(ack: Int, withData args: [AnyObject]) {
        dispatch_async(self.emitQueue) {[weak self] in
            if self == nil || !self!.connected {
                return
            }
            
            let packet = SocketPacket(type: nil, data: args, nsp: self!.nsp, id: ack)
            let str:String
            
            SocketParser.parseForEmit(packet)
            str = packet.createAck()
            
            if packet.type == SocketPacket.PacketType.BINARY_ACK {
                self?.engine?.send(str, withData: packet.binary)
            } else {
                self?.engine?.send(str, withData: nil)
            }
        }
    }
    
    /**
        Invoked when the server disconnects the socket.
     */
    public func engineDidForceClose(reason:String) {
        if self.closed {
            return
        }
        
        self._closed = true
        self._connected = false
        self.reconnects = false
        self._connecting = false
        self._reconnecting = false
        self.handleEvent("disconnect", data: [reason], isInternalMessage: true)
    }
    
    // Called when the socket gets an ack for something it sent
    func handleAck(ack: Int, data: AnyObject?) {
        let items = (data as? [AnyObject]? ?? ((data != nil) ? [data!] : nil))
        
        self.ackHandlers.executeAck(ack, items: items)
    }
    
    /**
        Causes an event to be handled. Only use if you know what you're doing.
    */
    public func handleEvent(event: String, data: [AnyObject]?, isInternalMessage: Bool = false,
        wantsAck ack:Int? = nil) {
            // println("Should do event: \(event) with data: \(data)")
            if !self.connected && !isInternalMessage {
                return
            }
            
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
    
    func joinNamespace() {
        if self.nsp != "/" {
            self.engine?.send("0/\(self.nsp)", withData: nil)
        }
    }
    
    /**
        Removes handler(s)
     */
    public func off(event: String) {
        self.handlers = self.handlers.filter { $0.event == event ? false : true }
    }
    
    /**
        Adds a handler for an event.
     */
    public func on(name: String, callback: SocketCallback) {
        let handler = SocketEventHandler(event: name, callback: callback)
        self.handlers.append(handler)
    }
    
    /**
        Adds a handler that will be called on every event.
     */
    public func onAny(handler: (SocketAnyEvent) -> Void) {
        self.anyHandler = handler
    }
    
    /**
        Same as connect
     */
    public func open() {
        self.connect()
    }
    
    /**
        Parses socket message
    
        :params: message The message to parse
     */
    public func parseSocketMessage(message: String) {
        SocketParser.parseSocketMessage(message, socket: self)
    }
    
    /**
        Parses binary data from the socket.
    
        :params: data The NSData to parse
     */
    public func parseBinaryData(data: NSData) {
        SocketParser.parseBinaryData(data, socket: self)
    }
    
    /**
        Called when polling did fail.
     */
    public func pollingDidFail(error: String) {
        if !self.reconnecting {
            self._connected = false
            self.handleEvent("reconnect", data: [error], isInternalMessage: true)
            self.tryReconnect()
        }
    }
    
    /**
        Attempts to reconnect to the server.
     */
    func tryReconnect() {
        if self.reconnectAttempts != -1 && self.currentReconnectAttempt + 1 > self.reconnectAttempts {
            self.engineDidForceClose("Reconnect Failed")
            return
        } else if self.connected {
            self._connecting = false
            self._reconnecting = false
            return
        }
        
        if self.reconnectTimer == nil {
            self._reconnecting = true
            
            dispatch_async(dispatch_get_main_queue()) {[weak self] in
                if self == nil {
                    return
                }
                
                self?.reconnectTimer = NSTimer.scheduledTimerWithTimeInterval(Double(self!.reconnectWait),
                    target: self!, selector: "tryReconnect", userInfo: nil, repeats: true)
                return
            }
        }
        
        self.handleEvent("reconnectAttempt", data: [self.reconnectAttempts - self.currentReconnectAttempt],
            isInternalMessage: true)
        
        self.currentReconnectAttempt++
        if self.paramConnect {
            self.connectWithParams(self.params)
        } else {
            self.connect()
        }
    }
    
    /**
        Called when the socket did close.
    
        :params: code The code sent with the close event
        :params: reason The reason sent with the close event
     */
    public func webSocketDidCloseWithCode(code: Int, reason: String) {
        self._connected = false
        self._connecting = false
        
        if self.closed || !self.reconnects {
            self.engineDidForceClose("WebSocket closed")
        } else if !self.reconnecting {
            self.handleEvent("reconnect", data: [reason], isInternalMessage: true)
            self.tryReconnect()
        }
    }
    
    /**
        Called when an error occurs.
    
        :params: error The error
     */
    public func webSocketDidFailWithError(error: NSError) {
        self._connected = false
        self._connecting = false
        
        self.handleEvent("error", data: [error.localizedDescription], isInternalMessage: true)
        
        if self.closed || !self.reconnects {
            self.engineDidForceClose("WebSocket closed with an error \(error)")
        } else if !self.reconnecting {
            self.handleEvent("reconnect", data: [error.localizedDescription], isInternalMessage: true)
            self.tryReconnect()
        }
    }
}