//
//  SocketEngineClient.swift
//  Socket.IO-Client-Swift
//
//  Created by Erik Little on 3/19/15.
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
//

import Foundation

/// Declares that a type will be a delegate to an engine.
@objc public protocol SocketEngineClient {
    // MARK: Methods

    /// Called when the engine errors.
    ///
    /// - parameter reason: The reason the engine errored.
    func engineDidError(reason: String)

    /// Native transport details. Existing delegates may keep the reason-only method.
    @objc optional func engineDidError(reason: String, error: SocketTransportError)

    /// Called when the engine closes.
    ///
    /// - parameter reason: The reason that the engine closed.
    func engineDidClose(reason: String)

    /// Carries HTTP status/body or WebSocket close metadata without losing the close reason.
    @objc optional func engineDidClose(reason: String, error: SocketTransportError)

    /// Called when the engine opens.
    ///
    /// - parameter reason: The reason the engine opened.
    func engineDidOpen(reason: String)

    /// Called when the engine receives a server heartbeat ping.
    func engineDidReceivePing()

    /// Called when the engine receives a pong, including a WebSocket upgrade probe.
    func engineDidReceivePong()

    /// Called when the engine answers a server heartbeat ping with a pong.
    func engineDidSendPong()

    /// Called when the engine has a message that must be parsed.
    ///
    /// - parameter msg: The message that needs parsing.
    func parseEngineMessage(_ msg: String)

    /// Called when the engine receives binary data.
    ///
    /// - parameter data: The data the engine received.
    func parseEngineBinaryData(_ data: Data)

    /// Called when when upgrading the http connection to a websocket connection.
    ///
    /// - parameter headers: The http headers.
    func engineDidWebsocketUpgrade(headers: [String: String])

    /// Engine.IO upgrade completed, after the probe and polling pause have settled.
    /// Unlike the HTTP handshake callback above, this confirms the active transport changed.
    @objc optional func engineDidCompleteUpgrade()

    /// An optional upgrade failed. A healthy polling transport may continue.
    @objc optional func engineDidFailUpgrade(error: SocketTransportError)
}

/// Structured native counterpart of Engine.IO's TransportError/CloseEvent.
/// Error and disconnect event data retain the reason at index 0 and append this
/// object at index 1. It intentionally has no request URL, cookies or headers.
/// Response text is untrusted, capped at 4 KiB, and never included in description.
public final class SocketTransportError: NSObject, LocalizedError {
    public let transport: String
    public let operation: String
    public let httpStatusCode: Int?
    public let closeCode: Int?
    public let closeReason: String?
    public let responseText: String?
    public let responseTruncated: Bool
    public let underlyingError: Error?

    internal init(transport: String, operation: String, response: HTTPURLResponse? = nil,
                  body: Data? = nil, closeCode: Int? = nil, closeReason: String? = nil,
                  underlyingError: Error? = nil) {
        self.transport = transport
        self.operation = operation
        self.httpStatusCode = response?.statusCode
        self.closeCode = closeCode
        self.closeReason = closeReason ?? (closeCode == nil ? nil : "")
        if let body = body {
            let decoded = String(decoding: body.prefix(4096), as: UTF8.self)
            var text = ""
            var bytes = 0
            // A replacement character can expand invalid input. Bound the
            // retained UTF-8 result, not just the bytes passed to the decoder.
            for scalar in decoded.unicodeScalars {
                let size = String(scalar).utf8.count
                guard bytes + size <= 4096 else { break }
                text.unicodeScalars.append(scalar)
                bytes += size
            }
            self.responseText = text
            self.responseTruncated = body.count > 4096 || bytes < decoded.utf8.count
        } else {
            self.responseText = nil
            self.responseTruncated = false
        }
        self.underlyingError = underlyingError
    }

    public var errorDescription: String? {
        var value = "\(transport) \(operation)"
        if let status = httpStatusCode { value += " (HTTP \(status))" }
        if let code = closeCode { value += " (WebSocket \(code))" }
        return value
    }
    public override var description: String { errorDescription ?? "Transport error" }
}
