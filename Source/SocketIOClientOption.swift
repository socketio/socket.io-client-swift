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
    case cookies([HTTPCookie])
    case doubleEncodeUTF8(Bool)
    case extraHeaders([String: String])
    case forceNew(Bool)
    case forcePolling(Bool)
    case forceWebsockets(Bool)
    case handleQueue(DispatchQueue)
    case log(Bool)
    case logger(SocketLogger)
    case nsp(String)
    case path(String)
    case reconnects(Bool)
    case reconnectAttempts(Int)
    case reconnectWait(Int)
    case secure(Bool)
    case security(SSLSecurity)
    case selfSigned(Bool)
    case sessionDelegate(URLSessionDelegate)
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
        case .security:
            description = "security"
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
            value = params as AnyObject
        case let .cookies(cookies):
            value = cookies as AnyObject
        case let .doubleEncodeUTF8(encode):
            value = encode as AnyObject
        case let .extraHeaders(headers):
            value = headers as AnyObject
        case let .forceNew(force):
            value = force as AnyObject
        case let .forcePolling(force):
            value = force as AnyObject
        case let .forceWebsockets(force):
            value = force as AnyObject
        case let .handleQueue(queue):
            value = queue as AnyObject
        case let .log(log):
            value = log as AnyObject
        case let .logger(logger):
            value = logger as AnyObject
        case let .nsp(nsp):
            value = nsp as AnyObject
        case let .path(path):
            value = path as AnyObject
        case let .reconnects(reconnects):
            value = reconnects as AnyObject
        case let .reconnectAttempts(attempts):
            value = attempts as AnyObject
        case let .reconnectWait(wait):
            value = wait as AnyObject
        case let .secure(secure):
            value = secure as AnyObject
        case let .security(security):
            value = security
        case let .selfSigned(signed):
            value = signed as AnyObject
        case let .sessionDelegate(delegate):
            value = delegate as AnyObject
        case let .voipEnabled(enabled):
            value = enabled as AnyObject
        }
        
        return value
    }
}

public func ==(lhs: SocketIOClientOption, rhs: SocketIOClientOption) -> Bool {
    return lhs.description == rhs.description
}
