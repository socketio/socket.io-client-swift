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

protocol ClientOption : CustomStringConvertible, Equatable {
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
