//
//  SSLSecurity.swift
//  SocketIO-iOS
//
//  Created by Lukas Schmidt on 24.09.17.
//

import Foundation
import Starscream

public class SSLSecurity: NSObject {
    public let security: Starscream.SSLSecurity

    init(security: Starscream.SSLSecurity) {
        self.security = security
    }

    @objc
    public convenience init(usePublicKeys: Bool = true) {
        let security = Starscream.SSLSecurity(usePublicKeys: usePublicKeys)
        self.init(security: security)
    }

    public convenience init(certs: [SSLCert], usePublicKeys: Bool) {
        let security = Starscream.SSLSecurity(certs: certs, usePublicKeys: usePublicKeys)
        self.init(security: security)
    }

    public func isValid(_ trust: SecTrust, domain: String?) -> Bool {
        return security.isValid(trust, domain: domain)
    }
}
