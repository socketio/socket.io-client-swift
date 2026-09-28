//
//  SocketExtensions.swift
//  Socket.IO-Client-Swift
//
//  Created by Erik Little on 7/1/2016.
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

enum JSONError : Error {
    case notNSDictionary
}

extension CharacterSet {
    // JavaScript encodeURIComponent: use an ASCII allowlist, never an inverted denylist.
    static var allowedURLCharacterSet: CharacterSet {
        return CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_.!~*'()")
    }
}

extension Dictionary where Key == String, Value == Any {
    private static func keyValueToSocketIOClientOption(key: String, value: Any) -> SocketIOClientOption? {
        switch (key, value) {
        case let ("parserOptions", options as SocketParserOptions):
            return .parserOptions(options)
        case let ("webSocketOptions", options as SocketWebSocketOptions):
            return .webSocketOptions(options)
        case let ("bufferLimits", limits as SocketBufferLimits):
            return .bufferLimits(limits)
        case let ("ackTimeout", timeout as Double):
            return .ackTimeout(timeout)
        case let ("retries", count as Int):
            return .retries(count)
        case ("ackTimeout", _), ("retries", _):
            return .invalidConfiguration("Invalid acknowledgement option: " + key)
        case let ("requestTimeout", timeout as Double):
            return .requestTimeout(timeout)
        case ("requestTimeout", _):
            return .invalidConfiguration("invalid value for requestTimeout; expected a positive finite number of seconds")
        case let ("connectTimeout", timeout as Double):
            return .connectTimeout(timeout)
        case let ("autoConnect", autoConnect as Bool):
            return .autoConnect(autoConnect)
        case let ("connectParams", params as [String: Any]):
            return .connectParams(params)
        case let ("withCredentials", enabled as Bool):
            return .withCredentials(enabled)
        case let ("forceBase64", enabled as Bool):
            return .forceBase64(enabled)
        case let ("addTrailingSlash", enabled as Bool):
            return .addTrailingSlash(enabled)
        case let ("cookies", cookies as [HTTPCookie]):
            return .cookies(cookies)
        case let ("extraHeaders", headers as [String: String]):
            return .extraHeaders(headers)
        case let ("forceNew", force as Bool):
            return .forceNew(force)
        case let ("transports", values as [String]):
            let transports = values.compactMap(SocketTransport.init(rawValue:))
            guard transports.count == values.count else {
                return .invalidConfiguration("Only polling and websocket transports are supported")
            }
            return .transports(transports)
        case let ("tryAllTransports", enabled as Bool):
            return .tryAllTransports(enabled)
        case let ("rememberUpgrade", enabled as Bool):
            return .rememberUpgrade(enabled)
        case ("transports", _), ("tryAllTransports", _), ("rememberUpgrade", _):
            return .invalidConfiguration("Invalid transport selection option: " + key)
        case let ("forcePolling", force as Bool):
            return .forcePolling(force)
        case let ("forceWebsockets", force as Bool):
            return .forceWebsockets(force)
        case let ("handleQueue", queue as DispatchQueue):
            return .handleQueue(queue)
        case let ("log", log as Bool):
            return .log(log)
        case let ("logger", logger as SocketLogger):
            return .logger(logger)
        case let ("path", path as String):
            return .path(path)
        case let ("reconnects", reconnects as Bool):
            return .reconnects(reconnects)
        case let ("reconnectAttempts", attempts as Int):
            return .reconnectAttempts(attempts)
        case let ("reconnectWait", wait as Int):
            return .reconnectWait(wait)
        case let ("reconnectWaitMax", wait as Int):
            return .reconnectWaitMax(wait)
        case let ("randomizationFactor", factor as Double):
            return .randomizationFactor(factor)
        case let ("secure", secure as Bool):
            return .secure(secure)
        case let ("timestampRequests", timestampRequests as Bool):
            return .timestampRequests(timestampRequests)
        case let ("timestampParam", timestampParam as String):
            return .timestampParam(timestampParam)
        case let ("clientCertificate", credential as URLCredential):
            return .clientCertificate(credential)
        case let ("security", security as SocketTLSConfiguration):
            return .security(security)
        case let ("sessionDelegate", delegate as URLSessionDelegate):
            return .sessionDelegate(delegate)
        case ("compress", _), ("selfSigned", _), ("enableSOCKSProxy", _),
             ("useCustomEngine", _), ("customEngine", _):
            return .invalidConfiguration("The " + key + " option was removed. Use native URLSession transport and explicit SocketTLSConfiguration trust policies.")
        case ("version", _):
            return .invalidConfiguration("The version option was removed. Only Socket.IO 4.x (Engine.IO 4) is supported; remove version from configuration.")
        case ("withCredentials", _), ("forceBase64", _), ("addTrailingSlash", _):
            return .invalidConfiguration("invalid value for " + key + "; expected Bool")
        case ("parserOptions", _):
            return .invalidConfiguration("invalid value for parserOptions; expected SocketParserOptions")
        case ("bufferLimits", _):
            return .invalidConfiguration("invalid value for bufferLimits; expected SocketBufferLimits")
        case ("clientCertificate", _):
            return .invalidConfiguration("invalid value for clientCertificate; expected URLCredential with a client identity")
        case ("security", _), ("secure", _), ("sessionDelegate", _), ("webSocketOptions", _):
            return .invalidConfiguration("invalid value for " + key + "; legacy security objects must migrate to SocketTLSConfiguration")
        case _:
            return nil
        }
    }

    func toSocketConfiguration() -> SocketIOClientConfiguration {
        var options = [] as SocketIOClientConfiguration

        for (rawKey, value) in self {
            if let opt = Dictionary.keyValueToSocketIOClientOption(key: rawKey, value: value) {
                options.insert(opt)
            }
        }

        return options
    }
}

extension String {
    func toDictionary() throws -> [String: Any] {
        guard let binData = data(using: .utf16, allowLossyConversion: false) else { return [:] }
        guard let json = try JSONSerialization.jsonObject(with: binData, options: .allowFragments) as? [String: Any] else {
            throw JSONError.notNSDictionary
        }

        return json
    }

    func urlEncode() -> String? {
        return addingPercentEncoding(withAllowedCharacters: .allowedURLCharacterSet)
    }
}
