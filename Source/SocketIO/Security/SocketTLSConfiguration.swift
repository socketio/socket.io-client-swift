import Foundation
#if canImport(Security)
import Security
#endif

/// TLS policy applied equally to HTTP polling and native WebSocket connections.
/// Certificate values are DER-encoded. Hostname, validity and chain validation
/// are mandatory, including when a private trust anchor is explicitly supplied.
public enum SocketTLSConfiguration {
    /// Use the operating system trust store and normal URLSession validation.
    case systemDefault
    /// Require system trust AND a matching leaf certificate. An empty list fails.
    case certificatePinning([Data])
    /// Trust only these private CA/leaf anchors. Optional pins constrain the leaf
    /// further. This replaces blanket self-signed/trust-all development settings.
    case customTrust(anchors: [Data], pins: [Data])

    internal var requiresTLS: Bool {
        if case .systemDefault = self { return false }
        return true
    }

    internal var validationError: String? {
        let certificates: [Data]
        switch self {
        case .systemDefault: return nil
        case .certificatePinning(let pins):
            guard !pins.isEmpty else { return "security requires at least one DER leaf certificate" }
            certificates = pins
        case .customTrust(let anchors, let pins):
            guard !anchors.isEmpty else { return "security requires at least one DER trust anchor" }
            certificates = anchors + pins
        }
        #if canImport(Security)
        guard certificates.allSatisfy({ SecCertificateCreateWithData(nil, $0 as CFData) != nil }) else {
            return "security contains an invalid DER certificate"
        }
        return nil
        #else
        return "custom TLS policies require Apple's Security framework"
        #endif
    }
}
