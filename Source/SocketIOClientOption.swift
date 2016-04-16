//
//  SocketIOClientOption .swift
//  Socket.IO-Client-Swift
//
//  Created by Erik Little on 10/17/15.
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

protocol ClientOption : CustomStringConvertible, Hashable {
    func getSocketIOOptionValue() -> AnyObject
}

public enum SocketIOClientOption : ClientOption {
    case connectParams([String: AnyObject])
    case cookies([NSHTTPCookie])
    case doubleEncodeUTF8(Bool)
    case extraHeaders([String: String])
    case forceNew(Bool)
    case forcePolling(Bool)
    case forceWebsockets(Bool)
    case handleQueue(dispatch_queue_t)
    case log(Bool)
    case logger(SocketLogger)
    case nsp(String)
    case path(String)
    case reconnects(Bool)
    case reconnectAttempts(Int)
    case reconnectWait(Int)
    case secure(Bool)
    case selfSigned(Bool)
    case sessionDelegate(NSURLSessionDelegate)
    case voipEnabled(Bool)
    
    public var description: String {
        let description: String
        
        switch self {
        case .connectParams:
            description = "connectParams"
        case .cookies:
            description = "cookies"
        case .doubleEncodeUTF8:
            description = "doubleEncodeUTF8"
        case .extraHeaders:
            description = "extraHeaders"
        case .forceNew:
            description = "forceNew"
        case .forcePolling:
            description = "forcePolling"
        case .forceWebsockets:
            description = "forceWebsockets"
        case .handleQueue:
            description = "handleQueue"
        case .log:
            description = "log"
        case .logger:
            description = "logger"
        case .nsp:
            description = "nsp"
        case .path:
            description = "path"
        case .reconnects:
            description = "reconnects"
        case .reconnectAttempts:
            description = "reconnectAttempts"
        case .reconnectWait:
            description = "reconnectWait"
        case .secure:
            description = "secure"
        case .selfSigned:
            description = "selfSigned"
        case .sessionDelegate:
            description = "sessionDelegate"
        case .voipEnabled:
            description = "voipEnabled"
        }
        
        return description
    }
    
    public var hashValue: Int {
        return description.hashValue
    }
    
    func getSocketIOOptionValue() -> AnyObject {
        let value: AnyObject
        
        switch self {
        case let .connectParams(params):
            value = params
        case let .cookies(cookies):
            value = cookies
        case let .doubleEncodeUTF8(encode):
            value = encode
        case let .extraHeaders(headers):
            value = headers
        case let .forceNew(force):
            value = force
        case let .forcePolling(force):
            value = force
        case let .forceWebsockets(force):
            value = force
        case let .handleQueue(queue):
            value = queue
        case let .log(log):
            value = log
        case let .logger(logger):
            value = logger
        case let .nsp(nsp):
            value = nsp
        case let .path(path):
            value = path
        case let .reconnects(reconnects):
            value = reconnects
        case let .reconnectAttempts(attempts):
            value = attempts
        case let .reconnectWait(wait):
            value = wait
        case let .secure(secure):
            value = secure
        case let .selfSigned(signed):
            value = signed
        case let .sessionDelegate(delegate):
            value = delegate
        case let .voipEnabled(enabled):
            value = enabled
        }
        
        return value
    }
}

public func ==(lhs: SocketIOClientOption, rhs: SocketIOClientOption) -> Bool {
    return lhs.description == rhs.description
}

extension Set where Element : ClientOption {
    mutating func insertIgnore(element: Element) {
        if !contains(element) {
            insert(element)
        }
    }
}

extension NSDictionary {
    private static func keyValueToSocketIOClientOption(key: String, value: AnyObject) -> SocketIOClientOption? {
        switch (key, value) {
        case let ("connectParams", params as [String: AnyObject]):
            return .connectParams(params)
        case let ("cookies", cookies as [NSHTTPCookie]):
            return .cookies(cookies)
        case let ("doubleEncodeUTF8", encode as Bool):
            return .doubleEncodeUTF8(encode)
        case let ("extraHeaders", headers as [String: String]):
            return .extraHeaders(headers)
        case let ("forceNew", force as Bool):
            return .forceNew(force)
        case let ("forcePolling", force as Bool):
            return .forcePolling(force)
        case let ("forceWebsockets", force as Bool):
            return .forceWebsockets(force)
        case let ("handleQueue", queue as dispatch_queue_t):
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
        case let ("selfSigned", selfSigned as Bool):
            return .selfSigned(selfSigned)
        case let ("sessionDelegate", delegate as NSURLSessionDelegate):
            return .sessionDelegate(delegate)
        case let ("voipEnabled", enable as Bool):
            return .voipEnabled(enable)
        default:
            return nil
        }
    }
    
    func toSocketOptionsSet() -> Set<SocketIOClientOption> {
        var options = Set<SocketIOClientOption>()
        
        for (rawKey, value) in self {
            if let key = rawKey as? String, opt = NSDictionary.keyValueToSocketIOClientOption(key: key, value: value) {
                options.insertIgnore(element: opt)
            }
        }
        
        return options
    }
}
