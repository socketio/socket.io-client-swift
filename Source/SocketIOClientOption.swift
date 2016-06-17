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
    case ConnectParams([String: AnyObject])
    case Cookies([NSHTTPCookie])
    case DoubleEncodeUTF8(Bool)
    case ExtraHeaders([String: String])
    case ForceNew(Bool)
    case ForcePolling(Bool)
    case ForceWebsockets(Bool)
    case HandleQueue(dispatch_queue_t)
    case Log(Bool)
    case Logger(SocketLogger)
    case Nsp(String)
    case Path(String)
    case Reconnects(Bool)
    case ReconnectAttempts(Int)
    case ReconnectWait(Int)
    case Secure(Bool)
    case Security(SSLSecurity)
    case SelfSigned(Bool)
    case SessionDelegate(NSURLSessionDelegate)
    case VoipEnabled(Bool)
    
    public var description: String {
        let description: String
        
        switch self {
        case .ConnectParams:
            description = "connectParams"
        case .Cookies:
            description = "cookies"
        case .DoubleEncodeUTF8:
            description = "doubleEncodeUTF8"
        case .ExtraHeaders:
            description = "extraHeaders"
        case .ForceNew:
            description = "forceNew"
        case .ForcePolling:
            description = "forcePolling"
        case .ForceWebsockets:
            description = "forceWebsockets"
        case .HandleQueue:
            description = "handleQueue"
        case .Log:
            description = "log"
        case .Logger:
            description = "logger"
        case .Nsp:
            description = "nsp"
        case .Path:
            description = "path"
        case .Reconnects:
            description = "reconnects"
        case .ReconnectAttempts:
            description = "reconnectAttempts"
        case .ReconnectWait:
            description = "reconnectWait"
        case .Secure:
            description = "secure"
        case .Security:
            description = "security"
        case .SelfSigned:
            description = "selfSigned"
        case .SessionDelegate:
            description = "sessionDelegate"
        case .VoipEnabled:
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
        case let .ConnectParams(params):
            value = params
        case let .Cookies(cookies):
            value = cookies
        case let .DoubleEncodeUTF8(encode):
            value = encode
        case let .ExtraHeaders(headers):
            value = headers
        case let .ForceNew(force):
            value = force
        case let .ForcePolling(force):
            value = force
        case let .ForceWebsockets(force):
            value = force
        case let .HandleQueue(queue):
            value = queue
        case let .Log(log):
            value = log
        case let .Logger(logger):
            value = logger
        case let .Nsp(nsp):
            value = nsp
        case let .Path(path):
            value = path
        case let .Reconnects(reconnects):
            value = reconnects
        case let .ReconnectAttempts(attempts):
            value = attempts
        case let .ReconnectWait(wait):
            value = wait
        case let .Secure(secure):
            value = secure
        case let .Security(security):
            value = security
        case let .SelfSigned(signed):
            value = signed
        case let .SessionDelegate(delegate):
            value = delegate
        case let .VoipEnabled(enabled):
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
            return .ConnectParams(params)
        case let ("cookies", cookies as [NSHTTPCookie]):
            return .Cookies(cookies)
        case let ("doubleEncodeUTF8", encode as Bool):
            return .DoubleEncodeUTF8(encode)
        case let ("extraHeaders", headers as [String: String]):
            return .ExtraHeaders(headers)
        case let ("forceNew", force as Bool):
            return .ForceNew(force)
        case let ("forcePolling", force as Bool):
            return .ForcePolling(force)
        case let ("forceWebsockets", force as Bool):
            return .ForceWebsockets(force)
        case let ("handleQueue", queue as dispatch_queue_t):
            return .HandleQueue(queue)
        case let ("log", log as Bool):
            return .Log(log)
        case let ("logger", logger as SocketLogger):
            return .Logger(logger)
        case let ("nsp", nsp as String):
            return .Nsp(nsp)
        case let ("path", path as String):
            return .Path(path)
        case let ("reconnects", reconnects as Bool):
            return .Reconnects(reconnects)
        case let ("reconnectAttempts", attempts as Int):
            return .ReconnectAttempts(attempts)
        case let ("reconnectWait", wait as Int):
            return .ReconnectWait(wait)
        case let ("secure", secure as Bool):
            return .Secure(secure)
        case let ("security", security as SSLSecurity):
            return .Security(security)
        case let ("selfSigned", selfSigned as Bool):
            return .SelfSigned(selfSigned)
        case let ("sessionDelegate", delegate as NSURLSessionDelegate):
            return .SessionDelegate(delegate)
        case let ("voipEnabled", enable as Bool):
            return .VoipEnabled(enable)
        default:
            return nil
        }
    }
    
    func toSocketOptionsSet() -> Set<SocketIOClientOption> {
        var options = Set<SocketIOClientOption>()
        
        for (rawKey, value) in self {
            if let key = rawKey as? String, opt = NSDictionary.keyValueToSocketIOClientOption(key, value: value) {
                options.insertIgnore(opt)
            }
        }
        
        return options
    }
}
