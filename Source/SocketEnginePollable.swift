//
//  SocketEnginePollable.swift
//  Socket.IO-Client-Swift
//
//  Created by Erik Little on 1/15/16.
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

/// Protocol that is used to implement socket.io polling support
public protocol SocketEnginePollable : SocketEngineSpec {
    /// MARK: Properties

    /// `true` If engine's session has been invalidated.
    var invalidated: Bool { get }

    /// A queue of engine.io messages waiting for POSTing
    ///
    /// **You should not touch this directly**
    var postWait: [String] { get set }

    /// The URLSession that will be used for polling.
    var session: URLSession? { get }

    /// `true` if there is an outstanding poll. Trying to poll before the first is done will cause socket.io to
    /// disconnect us.
    ///
    /// **Do not touch this directly**
    var waitingForPoll: Bool { get set }

    /// `true` if there is an outstanding post. Trying to post before the first is done will cause socket.io to
    /// disconnect us.
    ///
    /// **Do not touch this directly**
    var waitingForPost: Bool { get set }

    /// Call to send a long-polling request.
    ///
    /// You shouldn't need to call this directly, the engine should automatically maintain a long-poll request.
    func doPoll()

    /// Sends an engine.io message through the polling transport.
    ///
    /// You shouldn't call this directly, instead call the `write` method on `SocketEngine`.
    ///
    /// - parameter message: The message to send.
    /// - parameter withType: The type of message to send.
    /// - parameter withData: The data associated with this message.
    func sendPollMessage(_ message: String, withType type: SocketEnginePacketType, withData datas: [Data])

    /// Call to stop polling and invalidate the URLSession.
    func stopPolling()
}

// Default polling methods
extension SocketEnginePollable {
    private func addHeaders(for req: URLRequest) -> URLRequest {
        var req = req

        if cookies != nil {
            let headers = HTTPCookie.requestHeaderFields(with: cookies!)
            req.allHTTPHeaderFields = headers
        }

        if extraHeaders != nil {
            for (headerName, value) in extraHeaders! {
                req.setValue(value, forHTTPHeaderField: headerName)
            }
        }

        return req
    }

    func createRequestForPostWithPostWait() -> URLRequest {
        defer { postWait.removeAll(keepingCapacity: true) }

        var postStr = ""

        for packet in postWait {
            let len = packet.characters.count

            postStr += "\(len):\(packet)"
        }

        DefaultSocketLogger.Logger.log("Created POST string: %@", type: "SocketEnginePolling", args: postStr)

        var req = URLRequest(url: urlPollingWithSid)
        let postData = postStr.data(using: .utf8, allowLossyConversion: false)!

        req = addHeaders(for: req)

        req.httpMethod = "POST"
        req.setValue("text/plain; charset=UTF-8", forHTTPHeaderField: "Content-Type")

        req.httpBody = postData
        req.setValue(String(postData.count), forHTTPHeaderField: "Content-Length")

        return req
    }

    /// Call to send a long-polling request.
    ///
    /// You shouldn't need to call this directly, the engine should automatically maintain a long-poll request.
    public func doPoll() {
        if websocket || waitingForPoll || !connected || closed {
            return
        }

        var req = URLRequest(url: urlPollingWithSid)
        req = addHeaders(for: req)

        doLongPoll(for: req )
    }

    func doRequest(for req: URLRequest, callbackWith callback: @escaping (Data?, URLResponse?, Error?) -> Void) {
        if !polling || closed || invalidated || fastUpgrade {
            return
        }

        DefaultSocketLogger.Logger.log("Doing polling %@ %@", type: "SocketEnginePolling",
                                       args: req.httpMethod ?? "", req)

        session?.dataTask(with: req, completionHandler: callback).resume()
    }

    func doLongPoll(for req: URLRequest) {
        waitingForPoll = true

        doRequest(for: req) {[weak self] data, res, err in
            guard let this = self, this.polling else { return }

            if err != nil || data == nil {
                DefaultSocketLogger.Logger.error(err?.localizedDescription ?? "Error", type: "SocketEnginePolling")

                if this.polling {
                    this.didError(reason: err?.localizedDescription ?? "Error")
                }

                return
            }

            DefaultSocketLogger.Logger.log("Got polling response", type: "SocketEnginePolling")

            if let str = String(data: data!, encoding: String.Encoding.utf8) {
                this.parsePollingMessage(str)
            }

            this.waitingForPoll = false

            if this.fastUpgrade {
                this.doFastUpgrade()
            } else if !this.closed && this.polling {
                this.doPoll()
            }
        }
    }

    private func flushWaitingForPost() {
        if postWait.count == 0 || !connected {
            return
        } else if websocket {
            flushWaitingForPostToWebSocket()
            return
        }

        let req = createRequestForPostWithPostWait()

        waitingForPost = true

        DefaultSocketLogger.Logger.log("POSTing", type: "SocketEnginePolling")

        doRequest(for: req) {[weak self] data, res, err in
            guard let this = self else { return }

            if err != nil {
                DefaultSocketLogger.Logger.error(err?.localizedDescription ?? "Error", type: "SocketEnginePolling")

                if this.polling {
                    this.didError(reason: err?.localizedDescription ?? "Error")
                }

                return
            }

            this.waitingForPost = false

            if !this.fastUpgrade {
                this.flushWaitingForPost()
                this.doPoll()
            }
        }
    }

    func parsePollingMessage(_ str: String) {
        guard str.characters.count != 1 else { return }

        var reader = SocketStringReader(message: str)

        while reader.hasNext {
            if let n = Int(reader.readUntilOccurence(of: ":")) {
                parseEngineMessage(reader.read(count: n), fromPolling: true)
            } else {
                parseEngineMessage(str, fromPolling: true)
                break
            }
        }
    }

    /// Sends an engine.io message through the polling transport.
    ///
    /// You shouldn't call this directly, instead call the `write` method on `SocketEngine`.
    ///
    /// - parameter message: The message to send.
    /// - parameter withType: The type of message to send.
    /// - parameter withData: The data associated with this message.
    public func sendPollMessage(_ message: String, withType type: SocketEnginePacketType, withData datas: [Data]) {
        DefaultSocketLogger.Logger.log("Sending poll: %@ as type: %@", type: "SocketEnginePolling", args: message, type.rawValue)
        let fixedMessage: String

        if doubleEncodeUTF8 {
            fixedMessage = doubleEncodeUTF8(message)
        } else {
            fixedMessage = message
        }

        postWait.append(String(type.rawValue) + fixedMessage)

        for data in datas {
            if case let .right(bin) = createBinaryDataForSend(using: data) {
                postWait.append(bin)
            }
        }

        if !waitingForPost {
            flushWaitingForPost()
        }
    }

    /// Call to stop polling and invalidate the URLSession.
    public func stopPolling() {
        waitingForPoll = false
        waitingForPost = false
        session?.finishTasksAndInvalidate()
    }
}
