//
//  SocketLogger.swift
//  Socket.IO-Client-Swift
//
//  Created by Erik Little on 4/11/15.
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

/// Represents a class will log client events.
public protocol SocketLogger : AnyObject {
    // MARK: Properties

    /// Whether to log or not
    var log: Bool { get set }

    // MARK: Methods

    /// Normal log messages
    ///
    /// - parameter message: The message being logged. Can include `%@` that will be replaced with `args`
    /// - parameter type: The type of entity that called for logging.
    /// - parameter args: Any args that should be inserted into the message. May be left out.
    func log(_ message: @autoclosure () -> String, type: String)

    /// Error Messages
    ///
    /// - parameter message: The message being logged. Can include `%@` that will be replaced with `args`
    /// - parameter type: The type of entity that called for logging.
    /// - parameter args: Any args that should be inserted into the message. May be left out.
    func error(_ message: @autoclosure () -> String, type: String)
}

public extension SocketLogger {
    /// Default implementation.
    func log(_ message: @autoclosure () -> String, type: String) {
        guard log else { return }

        abstractLog("LOG", message: message(), type: type)
    }

    /// Default implementation.
    func error(_ message: @autoclosure () -> String, type: String) {
        guard log else { return }

        abstractLog("ERROR", message: message(), type: type)
    }

    private func abstractLog(_ logType: String, message: @autoclosure () -> String, type: String) {
        // `type` can contain a namespace; it must never become part of the format string.
        NSLog("%@ %@: %@", logType, type, message())
    }
}

class DefaultSocketLogger : SocketLogger {
    private static let storage = SocketLoggerStorage(DefaultSocketLogger())
    static var Logger: SocketLogger {
        get { storage }
        set { storage.replace(with: newValue) }
    }

    var log = false
}

/// All access through the library is serialized, including configuration. A
/// custom logger retained by its owner must also synchronize external access.
private final class SocketLoggerStorage: SocketLogger, @unchecked Sendable {
    private let lock = NSRecursiveLock()
    private var logger: SocketLogger
    init(_ logger: SocketLogger) { self.logger = logger }

    func replace(with logger: SocketLogger) {
        // Assigning the facade back to itself must not create a recursive logger.
        guard logger !== self else { return }
        lock.lock(); defer { lock.unlock() }
        self.logger = logger
    }
    var log: Bool {
        get { lock.lock(); defer { lock.unlock() }; return logger.log }
        set { lock.lock(); defer { lock.unlock() }; logger.log = newValue }
    }
    func log(_ message: @autoclosure () -> String, type: String) {
        lock.lock(); defer { lock.unlock() }
        logger.log(message(), type: type)
    }
    func error(_ message: @autoclosure () -> String, type: String) {
        lock.lock(); defer { lock.unlock() }
        logger.error(message(), type: type)
    }
}

/// The default logger is process-wide, so enabling it for one manager also
/// logs the traffic of every other manager. Log lines therefore never carry
/// the application's credentials: CONNECT auth payloads and query values
/// (`connectParams` often hold tokens) are replaced before they are logged.
internal enum SocketLogRedaction {
    static let placeholder = "<redacted>"
    private static let engineQueryKeys: Set<String> = ["EIO", "transport", "sid", "b64"]

    /// A Socket.IO packet string (`0/nsp,{...}`); only CONNECT is changed.
    static func socketIOPacket(_ packet: String) -> String {
        guard packet.first == "0" else { return packet }
        var body = packet.dropFirst()
        var prefix = "0"
        if body.first == "/" {
            guard let comma = body.firstIndex(of: ",") else { return packet }
            prefix += body[...comma]
            body = body[body.index(after: comma)...]
        }
        return body.isEmpty ? packet : prefix + placeholder
    }

    /// An Engine.IO polling payload: records separated by U+001E, each starting
    /// with its Engine.IO packet type; `4` carries a Socket.IO packet.
    static func enginePayload(_ payload: String) -> String {
        payload.split(separator: "\u{1e}", omittingEmptySubsequences: false).map { record -> String in
            guard record.first == "4" else { return String(record) }
            return "4" + socketIOPacket(String(record.dropFirst()))
        }.joined(separator: "\u{1e}")
    }

    /// Keeps the endpoint and the Engine.IO-owned query values only.
    static func url(_ url: URL?) -> String {
        guard let url = url, var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return "nil"
        }
        components.user = nil
        components.password = nil
        components.fragment = nil
        components.percentEncodedQueryItems = components.percentEncodedQueryItems?.map { item in
            let name = item.name.removingPercentEncoding ?? item.name
            guard !engineQueryKeys.contains(name) else { return item }
            // A bare `?token` carries its secret in the name.
            guard item.value != nil else { return URLQueryItem(name: "REDACTED", value: nil) }
            // Percent-encoded items must stay valid percent-encoding.
            return URLQueryItem(name: item.name, value: "REDACTED")
        }
        return components.string ?? "nil"
    }
}
