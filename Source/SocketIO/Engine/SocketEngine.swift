//
//  SocketEngine.swift
//  Socket.IO-Client-Swift
//
//  Created by Erik Little on 3/3/15.
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
import Starscream

/// The class that handles the engine.io protocol and transports.
/// See `SocketEnginePollable` and `SocketEngineWebsocket` for transport specific methods.
public final class SocketEngine : NSObject, URLSessionDelegate, SocketEnginePollable, SocketEngineWebsocket {
    // MARK: Properties

    private static let logType = "SocketEngine"

    /// The queue that all engine actions take place on.
    public let engineQueue = DispatchQueue(label: "com.socketio.engineHandleQueue")

    /// The connect parameters sent during a connect.
    public var connectParams: [String: Any]? {
        didSet {
            (urlPolling, urlWebSocket) = createURLs()
        }
    }

    /// A queue of engine.io messages waiting for POSTing
    ///
    /// **You should not touch this directly**
    public var postWait = [String]()

    /// `true` if there is an outstanding poll. Trying to poll before the first is done will cause socket.io to
    /// disconnect us.
    ///
    /// **Do not touch this directly**
    public var waitingForPoll = false

    /// `true` if there is an outstanding post. Trying to post before the first is done will cause socket.io to
    /// disconnect us.
    ///
    /// **Do not touch this directly**
    public var waitingForPost = false

    /// `true` if this engine is closed.
    public private(set) var closed = false

    /// If `true` the engine will attempt to use WebSocket compression.
    public private(set) var compress = false

    /// `true` if this engine is connected. Connected means that the initial poll connect has succeeded.
    public private(set) var connected = false

    /// An array of HTTPCookies that are sent during the connection.
    public private(set) var cookies: [HTTPCookie]?

    /// A dictionary of extra http headers that will be set during connection.
    public private(set) var extraHeaders: [String: String]?

    /// When `true`, the engine is in the process of switching to WebSockets.
    ///
    /// **Do not touch this directly**
    public private(set) var fastUpgrade = false

    /// When `true`, the engine will only use HTTP long-polling as a transport.
    public private(set) var forcePolling = false

    /// When `true`, the engine will only use WebSockets as a transport.
    public private(set) var forceWebsockets = false

    /// `true` If engine's session has been invalidated.
    public private(set) var invalidated = false

    /// If `true`, the engine is currently in HTTP long-polling mode.
    public private(set) var polling = true

    /// If `true`, the engine is currently seeing whether it can upgrade to WebSockets.
    public private(set) var probing = false

    /// The URLSession that will be used for polling.
    public private(set) var session: URLSession?

    /// The session id for this engine.
    public private(set) var sid = ""

    /// The path to engine.io.
    public private(set) var socketPath = "/engine.io/"

    /// The url for polling.
    public private(set) var urlPolling = URL(string: "http://localhost/")!

    /// The url for WebSockets.
    public private(set) var urlWebSocket = URL(string: "http://localhost/")!

    /// If `true`, then the engine is currently in WebSockets mode.
    public private(set) var websocket = false

    /// The WebSocket for this engine.
    public private(set) var ws: WebSocket?

    /// The client for this engine.
    public weak var client: SocketEngineClient?

    private weak var sessionDelegate: URLSessionDelegate?

    private let url: URL

    private var pingInterval: Int?
    private var pingTimeout = 0 {
        didSet {
            pongsMissedMax = Int(pingTimeout / (pingInterval ?? 25000))
        }
    }

    private var pongsMissed = 0
    private var pongsMissedMax = 0
    private var probeWait = ProbeWaitQueue()
    private var secure = false
    private var security: SocketIO.SSLSecurity?
    private var selfSigned = false

    // MARK: Initializers

    /// Creates a new engine.
    ///
    /// - parameter client: The client for this engine.
    /// - parameter url: The url for this engine.
    /// - parameter config: An array of configuration options for this engine.
    public init(client: SocketEngineClient, url: URL, config: SocketIOClientConfiguration) {
        self.client = client
        self.url = url
        for option in config {
            switch option {
            case let .connectParams(params):
                connectParams = params
            case let .cookies(cookies):
                self.cookies = cookies
            case let .extraHeaders(headers):
                extraHeaders = headers
            case let .sessionDelegate(delegate):
                sessionDelegate = delegate
            case let .forcePolling(force):
                forcePolling = force
            case let .forceWebsockets(force):
                forceWebsockets = force
            case let .path(path):
                socketPath = path

                if !socketPath.hasSuffix("/") {
                    socketPath += "/"
                }
            case let .secure(secure):
                self.secure = secure
            case let .selfSigned(selfSigned):
                self.selfSigned = selfSigned
            case let .security(security):
                self.security = security
            case .compress:
                self.compress = true
            default:
                continue
            }
        }

        super.init()

        sessionDelegate = sessionDelegate ?? self

        (urlPolling, urlWebSocket) = createURLs()
    }

    /// Creates a new engine.
    ///
    /// - parameter client: The client for this engine.
    /// - parameter url: The url for this engine.
    /// - parameter options: The options for this engine.
    public convenience init(client: SocketEngineClient, url: URL, options: NSDictionary?) {
        self.init(client: client, url: url, config: options?.toSocketConfiguration() ?? [])
    }

    deinit {
        DefaultSocketLogger.Logger.log("Engine is being released", type: SocketEngine.logType)
        closed = true
        stopPolling()
    }

    // MARK: Methods

    private func checkAndHandleEngineError(_ msg: String) {
        do {
            let dict = try msg.toDictionary()
            guard let error = dict["message"] as? String else { return }

            /*
             0: Unknown transport
             1: Unknown sid
             2: Bad handshake request
             3: Bad request
             */
            didError(reason: error)
        } catch {
            client?.engineDidError(reason: "Got unknown error from server \(msg)")
        }
    }

    private func handleBase64(message: String) {
        // binary in base64 string
        let noPrefix = String(message[message.index(message.startIndex, offsetBy: 2)..<message.endIndex])

        if let data = Data(base64Encoded: noPrefix, options: .ignoreUnknownCharacters) {
            client?.parseEngineBinaryData(data)
        }
    }

    private func closeOutEngine(reason: String) {
        sid = ""
        closed = true
        invalidated = true
        connected = false

        ws?.disconnect()
        stopPolling()
        client?.engineDidClose(reason: reason)
    }

    /// Starts the connection to the server.
    public func connect() {
        engineQueue.async {
            self._connect()
        }
    }

    private func _connect() {
        if connected {
            DefaultSocketLogger.Logger.error("Engine tried opening while connected. Assuming this was a reconnect",
                                             type: SocketEngine.logType)
            disconnect(reason: "reconnect")
        }

        DefaultSocketLogger.Logger.log("Starting engine. Server: \(url)", type: SocketEngine.logType)
        DefaultSocketLogger.Logger.log("Handshaking", type: SocketEngine.logType)

        resetEngine()

        if forceWebsockets {
            polling = false
            websocket = true
            createWebSocketAndConnect()
            return
        }

        var reqPolling = URLRequest(url: urlPolling, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 60.0)

        addHeaders(to: &reqPolling)
        doLongPoll(for: reqPolling)
    }

    private func createURLs() -> (URL, URL) {
        if client == nil {
            return (URL(string: "http://localhost/")!, URL(string: "http://localhost/")!)
        }

        var urlPolling = URLComponents(string: url.absoluteString)!
        var urlWebSocket = URLComponents(string: url.absoluteString)!
        var queryString = ""

        urlWebSocket.path = socketPath
        urlPolling.path = socketPath

        if secure {
            urlPolling.scheme = "https"
            urlWebSocket.scheme = "wss"
        } else {
            urlPolling.scheme = "http"
            urlWebSocket.scheme = "ws"
        }

        if let connectParams = self.connectParams {
            for (key, value) in connectParams {
                let keyEsc = key.urlEncode()!
                let valueEsc = "\(value)".urlEncode()!

                queryString += "&\(keyEsc)=\(valueEsc)"
            }
        }

        urlWebSocket.percentEncodedQuery = "transport=websocket" + queryString
        urlPolling.percentEncodedQuery = "transport=polling&b64=1" + queryString

        return (urlPolling.url!, urlWebSocket.url!)
    }

    private func createWebSocketAndConnect() {
        ws?.delegate = nil // TODO this seems a bit defensive, is this really needed?
        ws = WebSocket(url: urlWebSocketWithSid)

        if cookies != nil {
            let headers = HTTPCookie.requestHeaderFields(with: cookies!)
            for (key, value) in headers {
                ws?.headers[key] = value
            }
        }

        if extraHeaders != nil {
            for (headerName, value) in extraHeaders! {
                ws?.headers[headerName] = value
            }
        }

        
        ws?.callbackQueue = engineQueue
        ws?.enableCompression = compress
        ws?.delegate = self
        ws?.disableSSLCertValidation = selfSigned
        ws?.security = security?.security

        ws?.connect()
    }

    /// Called when an error happens during execution. Causes a disconnection.
    public func didError(reason: String) {
        DefaultSocketLogger.Logger.error("\(reason)", type: SocketEngine.logType)
        client?.engineDidError(reason: reason)
        disconnect(reason: reason)
    }

    /// Disconnects from the server.
    ///
    /// - parameter reason: The reason for the disconnection. This is communicated up to the client.
    public func disconnect(reason: String) {
        engineQueue.async {
            self._disconnect(reason: reason)
        }
    }

    private func _disconnect(reason: String) {
        guard connected else { return closeOutEngine(reason: reason) }

        DefaultSocketLogger.Logger.log("Engine is being closed.", type: SocketEngine.logType)

        if closed {
            return closeOutEngine(reason: reason)
        }

        if websocket {
            sendWebSocketMessage("", withType: .close, withData: [])
            closeOutEngine(reason: reason)
        } else {
            disconnectPolling(reason: reason)
        }
    }

    // We need to take special care when we're polling that we send it ASAP
    // Also make sure we're on the emitQueue since we're touching postWait
    private func disconnectPolling(reason: String) {
        postWait.append(String(SocketEnginePacketType.close.rawValue))

        doRequest(for: createRequestForPostWithPostWait()) {_, _, _ in }
        closeOutEngine(reason: reason)
    }

    /// Called to switch from HTTP long-polling to WebSockets. After calling this method the engine will be in
    /// WebSocket mode.
    ///
    /// **You shouldn't call this directly**
    public func doFastUpgrade() {
        if waitingForPoll {
            DefaultSocketLogger.Logger.error("Outstanding poll when switched to WebSockets," +
                "we'll probably disconnect soon. You should report this.", type: SocketEngine.logType)
        }

        sendWebSocketMessage("", withType: .upgrade, withData: [])
        websocket = true
        polling = false
        fastUpgrade = false
        probing = false
        flushProbeWait()
    }

    private func flushProbeWait() {
        DefaultSocketLogger.Logger.log("Flushing probe wait", type: SocketEngine.logType)

        for waiter in probeWait {
            write(waiter.msg, withType: waiter.type, withData: waiter.data)
        }

        probeWait.removeAll(keepingCapacity: false)

        if postWait.count != 0 {
            flushWaitingForPostToWebSocket()
        }
    }

    /// Causes any packets that were waiting for POSTing to be sent through the WebSocket. This happens because when
    /// the engine is attempting to upgrade to WebSocket it does not do any POSTing.
    ///
    /// **You shouldn't call this directly**
    public func flushWaitingForPostToWebSocket() {
        guard let ws = self.ws else { return }

        for msg in postWait {
            ws.write(string: msg)
        }

        postWait.removeAll(keepingCapacity: false)
    }

    private func handleClose(_ reason: String) {
        client?.engineDidClose(reason: reason)
    }

    private func handleMessage(_ message: String) {
        client?.parseEngineMessage(message)
    }

    private func handleNOOP() {
        doPoll()
    }

    private func handleOpen(openData: String) {
        guard let json = try? openData.toDictionary() else {
            didError(reason: "Error parsing open packet")

            return
        }

        guard let sid = json["sid"] as? String else {
            didError(reason: "Open packet contained no sid")

            return
        }

        let upgradeWs: Bool

        self.sid = sid
        connected = true
        pongsMissed = 0

        if let upgrades = json["upgrades"] as? [String] {
            upgradeWs = upgrades.contains("websocket")
        } else {
            upgradeWs = false
        }

        if let pingInterval = json["pingInterval"] as? Int, let pingTimeout = json["pingTimeout"] as? Int {
            self.pingInterval = pingInterval
            self.pingTimeout = pingTimeout
        }

        if !forcePolling && !forceWebsockets && upgradeWs {
            createWebSocketAndConnect()
        }

        sendPing()

        if !forceWebsockets {
            doPoll()
        }

        client?.engineDidOpen(reason: "Connect")
    }

    private func handlePong(with message: String) {
        pongsMissed = 0

        // We should upgrade
        if message == "3probe" {
            upgradeTransport()
        }
    }

    /// Parses raw binary received from engine.io.
    ///
    /// - parameter data: The data to parse.
    public func parseEngineData(_ data: Data) {
        DefaultSocketLogger.Logger.log("Got binary data: \(data)", type: SocketEngine.logType)

        client?.parseEngineBinaryData(data.subdata(in: 1..<data.endIndex))
    }

    /// Parses a raw engine.io packet.
    ///
    /// - parameter message: The message to parse.
    /// - parameter fromPolling: Whether this message is from long-polling.
    ///                          If `true` we might have to fix utf8 encoding.
    public func parseEngineMessage(_ message: String) {
        DefaultSocketLogger.Logger.log("Got message: \(message)", type: SocketEngine.logType)

        let reader = SocketStringReader(message: message)

        if message.hasPrefix("b4") {
            return handleBase64(message: message)
        }

        guard let type = SocketEnginePacketType(rawValue: Int(reader.currentCharacter) ?? -1) else {
            checkAndHandleEngineError(message)

            return
        }

        switch type {
        case .message:
            handleMessage(String(message.dropFirst()))
        case .noop:
            handleNOOP()
        case .pong:
            handlePong(with: message)
        case .open:
            handleOpen(openData: String(message.dropFirst()))
        case .close:
            handleClose(message)
        default:
            DefaultSocketLogger.Logger.log("Got unknown packet type", type: SocketEngine.logType)
        }
    }

    // Puts the engine back in its default state
    private func resetEngine() {
        let queue = OperationQueue()
        queue.underlyingQueue = engineQueue

        closed = false
        connected = false
        fastUpgrade = false
        polling = true
        probing = false
        invalidated = false
        session = Foundation.URLSession(configuration: .default, delegate: sessionDelegate, delegateQueue: queue)
        sid = ""
        waitingForPoll = false
        waitingForPost = false
        websocket = false
    }

    private func sendPing() {
        guard connected, let pingInterval = pingInterval else { return }

        // Server is not responding
        if pongsMissed > pongsMissedMax {
            client?.engineDidClose(reason: "Ping timeout")

            return
        }

        pongsMissed += 1
        write("", withType: .ping, withData: [])

        engineQueue.asyncAfter(deadline: DispatchTime.now() + .milliseconds(pingInterval)) {[weak self, id = self.sid] in
            // Make sure not to ping old connections
            guard let this = self, this.sid == id else { return }

            this.sendPing()
        }
    }

    // Moves from long-polling to websockets
    private func upgradeTransport() {
        if ws?.isConnected ?? false {
            DefaultSocketLogger.Logger.log("Upgrading transport to WebSockets", type: SocketEngine.logType)

            fastUpgrade = true
            sendPollMessage("", withType: .noop, withData: [])
            // After this point, we should not send anymore polling messages
        }
    }

    /// Writes a message to engine.io, independent of transport.
    ///
    /// - parameter msg: The message to send.
    /// - parameter withType: The type of this message.
    /// - parameter withData: Any data that this message has.
    public func write(_ msg: String, withType type: SocketEnginePacketType, withData data: [Data]) {
        engineQueue.async {
            guard self.connected else { return }

            if self.websocket {
                DefaultSocketLogger.Logger.log("Writing ws: \(msg) has data: \(data.count != 0)",
                                               type: SocketEngine.logType)
                self.sendWebSocketMessage(msg, withType: type, withData: data)
            } else if !self.probing {
                DefaultSocketLogger.Logger.log("Writing poll: \(msg) has data: \(data.count != 0)",
                                               type: SocketEngine.logType)
                self.sendPollMessage(msg, withType: type, withData: data)
            } else {
                self.probeWait.append((msg, type, data))
            }
        }
    }

    // MARK: Starscream delegate conformance

    /// Delegate method for connection.
    public func websocketDidConnect(socket: WebSocket) {
        if !forceWebsockets {
            probing = true
            probeWebSocket()
        } else {
            connected = true
            probing = false
            polling = false
        }
    }

    /// Delegate method for disconnection.
    public func websocketDidDisconnect(socket: WebSocket, error: NSError?) {
        probing = false

        if closed {
            client?.engineDidClose(reason: "Disconnect")

            return
        }

        guard websocket else {
            flushProbeWait()

            return
        }

        connected = false
        websocket = false

        if let reason = error?.localizedDescription {
            didError(reason: reason)
        } else {
            client?.engineDidClose(reason: "Socket Disconnected")
        }
    }
}

extension SocketEngine {
    // MARK: URLSessionDelegate methods

    /// Delegate called when the session becomes invalid.
    public func URLSession(session: URLSession, didBecomeInvalidWithError error: NSError?) {
        DefaultSocketLogger.Logger.error("Engine URLSession became invalid", type: "SocketEngine")

        didError(reason: "Engine URLSession became invalid")
    }
}
