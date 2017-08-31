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
import StarscreamSocketIO

enum JSONError : Error {
    case notArray
    case notNSDictionary
}

extension Array {
    func toJSON() throws -> Data {
        return try JSONSerialization.data(withJSONObject: self, options: JSONSerialization.WritingOptions(rawValue: 0))
    }
}

extension CharacterSet {
    static var allowedURLCharacterSet: CharacterSet {
        return CharacterSet(charactersIn: "!*'();:@&=+$,/?%#[]\" {}").inverted
    }
}

extension NSDictionary {
    private static func keyValueToSocketIOClientOption(key: String, value: Any) -> SocketIOClientOption? {
        switch (key, value) {
        case let ("connectParams", params as [String: Any]):
            return .connectParams(params)
        case let ("cookies", cookies as [HTTPCookie]):
            return .cookies(cookies)
        case let ("extraHeaders", headers as [String: String]):
            return .extraHeaders(headers)
        case let ("forceNew", force as Bool):
            return .forceNew(force)
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
        case let ("nsp", nsp as String):
            return .nsp(nsp)
        case let ("path", path as String):
            return .path(path)
        case let ("reconnects", reconnects as Bool):
            return .reconnects(reconnects)
        case let ("reconnectAttempts", attempts as Int):
            return .reconnectAttempts(attempts)
        case let ("reconnectWait", wait as Int):
            return .reconnectWait(wait)
        case let ("secure", secure as Bool):
            return .secure(secure)
        case let ("security", security as SSLSecurity):
            return .security(security)
        case let ("selfSigned", selfSigned as Bool):
            return .selfSigned(selfSigned)
        case let ("sessionDelegate", delegate as URLSessionDelegate):
            return .sessionDelegate(delegate)
        case let ("compress", compress as Bool):
            return compress ? .compress : nil
        default:
            return nil
        }
    }

    func toSocketConfiguration() -> SocketIOClientConfiguration {
        var options = [] as SocketIOClientConfiguration

        for (rawKey, value) in self {
            if let key = rawKey as? String, let opt = NSDictionary.keyValueToSocketIOClientOption(key: key, value: value) {
                options.insert(opt)
            }
        }

        return options
    }
}

extension String {
    func toArray() throws -> [Any] {
        guard let stringData = data(using: .utf16, allowLossyConversion: false) else { return [] }
        guard let array = try JSONSerialization.jsonObject(with: stringData, options: .mutableContainers) as? [Any] else {
             throw JSONError.notArray
        }

        return array
    }

    func toNSDictionary() throws -> NSDictionary {
        guard let binData = data(using: .utf16, allowLossyConversion: false) else { return [:] }
        guard let json = try JSONSerialization.jsonObject(with: binData, options: .allowFragments) as? NSDictionary else {
            throw JSONError.notNSDictionary
        }

        return json
    }

    func urlEncode() -> String? {
        return addingPercentEncoding(withAllowedCharacters: .allowedURLCharacterSet)
    }
}
