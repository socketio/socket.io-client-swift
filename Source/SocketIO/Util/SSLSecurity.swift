//
//  SSLSecurity.swift
//  SocketIO-iOS
//
//  Created by Lukas Schmidt on 24.09.17.
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
import Starscream

/// A wrapper around Starscream's SSLSecurity that provides a minimal Objective-C interface.
open class SSLSecurity : NSObject {
    /// The internal Starscream SSLSecurity.
    public let security: Starscream.SSLSecurity

    init(security: Starscream.SSLSecurity) {
        self.security = security
    }

    /// Creates a new SSLSecurity that specifies whether to use publicKeys or certificates should be used for SSL
    /// pinning validation
    ///
    /// - parameter usePublicKeys: is to specific if the publicKeys or certificates should be used for SSL pinning
    /// validation
    @objc
    public convenience init(usePublicKeys: Bool = true) {
        let security = Starscream.SSLSecurity(usePublicKeys: usePublicKeys)
        self.init(security: security)
    }


    /// Designated init
    ///
    /// - parameter certs: is the certificates or public keys to use
    /// - parameter usePublicKeys: is to specific if the publicKeys or certificates should be used for SSL pinning
    /// validation
    /// - returns: a representation security object to be used with
    public convenience init(certs: [SSLCert], usePublicKeys: Bool) {
        let security = Starscream.SSLSecurity(certs: certs, usePublicKeys: usePublicKeys)
        self.init(security: security)
    }

    /// Returns whether or not the given trust is valid.
    ///
    /// - parameter trust: The trust to validate.
    /// - parameter domain: The CN domain to validate.
    /// - returns: Whether or not this is valid.
    public func isValid(_ trust: SecTrust, domain: String?) -> Bool {
        return security.isValid(trust, domain: domain)
    }
}
