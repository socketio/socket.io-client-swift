import Foundation
#if canImport(Security)
import Security

/// Applies additional restrictions, never a trust-all override. Existing
/// URLSession policies are retained and augmented with an explicit hostname.
internal enum SocketServerTrustEvaluator {
    static func evaluate(_ trust: SecTrust, host: String,
                         configuration: SocketTLSConfiguration) -> Bool {
        guard !host.isEmpty, configuration.validationError == nil else { return false }
        var existing: CFArray?
        guard SecTrustCopyPolicies(trust, &existing) == errSecSuccess else { return false }
        var policies = (existing as? [SecPolicy]) ?? []
        policies.append(SecPolicyCreateSSL(true, host as CFString))
        guard SecTrustSetPolicies(trust, policies as CFArray) == errSecSuccess else { return false }
        let pins: [Data]
        switch configuration {
        case .systemDefault: pins = []
        case .certificatePinning(let certificates): pins = certificates
        case .customTrust(let anchors, let certificates):
            let roots = anchors.compactMap { SecCertificateCreateWithData(nil, $0 as CFData) }
            guard roots.count == anchors.count,
                  SecTrustSetAnchorCertificates(trust, roots as CFArray) == errSecSuccess,
                  SecTrustSetAnchorCertificatesOnly(trust, true) == errSecSuccess else { return false }
            pins = certificates
        }
        guard SecTrustEvaluateWithError(trust, nil) else { return false }
        guard !pins.isEmpty else { return true }
        guard let leaf = Self.leafCertificate(of: trust) else { return false }
        return pins.contains(SecCertificateCopyData(leaf) as Data)
    }

    /// Deployment floor is iOS 15 / macOS 12, so the modern certificate
    /// chain API is always available.
    private static func leafCertificate(of trust: SecTrust) -> SecCertificate? {
        (SecTrustCopyCertificateChain(trust) as? [SecCertificate])?.first
    }
}
#endif
