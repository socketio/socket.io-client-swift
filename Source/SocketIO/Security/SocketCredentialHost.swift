import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// Host equivalence for the configured client identity. Scheme and port are
/// checked separately by the authentication delegate; no DNS resolution occurs.
internal enum SocketCredentialHost {
    static func matches(_ origin: String?, _ challenge: String) -> Bool {
        guard let origin, let expected = canonicalize(origin),
              let actual = canonicalize(challenge) else { return false }
        return expected == actual
    }

    private static func canonicalize(_ host: String) -> String? {
        // Protection-space hosts are host strings, not escaped URL authorities.
        // In particular, do not decode percent escapes into host delimiters.
        guard !host.isEmpty,
              !host.unicodeScalars.contains(where: { CharacterSet.whitespacesAndNewlines.contains($0) ||
                  CharacterSet.controlCharacters.contains($0) }) else { return nil }
        if host.contains(":") { return canonicalIPv6(host) }
        guard !host.contains("%"), !host.contains("["), !host.contains("]") else { return nil }

        var components = URLComponents()
        components.scheme = "https"
        components.host = host
        guard var result = components.url?.host,
              result.unicodeScalars.allSatisfy({ $0.isASCII }) else { return nil }
        result = result.lowercased()
        // Foundation supplies the IDNA ASCII form. Only one DNS root dot is
        // optional; empty interior labels or multiple terminal dots are invalid.
        if result.hasSuffix(".") { result.removeLast() }
        let labels = result.split(separator: ".", omittingEmptySubsequences: false)
        guard !result.isEmpty, result.utf8.count <= 253,
              labels.allSatisfy({ label in
                  !label.isEmpty && label.utf8.count <= 63 &&
                  label.first != "-" && label.last != "-" &&
                  label.utf8.allSatisfy { (97...122).contains($0) || (48...57).contains($0) || $0 == 45 }
              }) else { return nil }
        return result
    }

    private static func canonicalIPv6(_ host: String) -> String? {
        var literal = host
        // Foundation versions differ in whether URL.host retains IPv6 brackets.
        if literal.hasPrefix("["), literal.hasSuffix("]") {
            literal.removeFirst()
            literal.removeLast()
        }
        let parts = literal.split(separator: "%", maxSplits: 1, omittingEmptySubsequences: false)
        var address = in6_addr()
        guard inet_pton(AF_INET6, String(parts[0]), &address) == 1 else { return nil }
        var result = "ipv6:" + withUnsafeBytes(of: address) { bytes in
            bytes.map { String(format: "%02x", $0) }.joined()
        }
        if parts.count == 2 {
            let scope = parts[1]
            guard !scope.isEmpty, scope.utf8.allSatisfy({
                (65...90).contains($0) || (97...122).contains($0) || (48...57).contains($0) ||
                [45, 46, 95, 126].contains($0)
            }) else { return nil }
            // Interface names are not DNS names: preserve their case and scope.
            result += "%" + scope
        }
        return result
    }
}
