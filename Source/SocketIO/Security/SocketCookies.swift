import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif

/// The canonical form of a host, used for same-host and same-origin decisions,
/// cookie domain matching and IP address detection. No DNS resolution occurs.
internal enum SocketHost {
    /// Lowercased, without a trailing root dot. An IPv6 literal loses its
    /// brackets and is written in its canonical form (`[0:0:0:0:0:0:0:1]` is
    /// `::1`); an IPv4 address is parsed like the WHATWG URL parser does and
    /// written as a dotted quad (`127.1`, `0x7f.0.0.1` and `2130706433` are all
    /// `127.0.0.1`). A host the IPv4 parser rejects, such as `foo.123` or
    /// `app.0x1`, is a domain name.
    static func canonical(_ host: String?) -> String? {
        guard var host = host?.lowercased(), !host.isEmpty else { return nil }
        if host.hasPrefix("[") && host.hasSuffix("]") { host = String(host.dropFirst().dropLast()) }
        if host.contains(":") { return canonicalIPv6(host) ?? host }
        if host.count > 1 && host.hasSuffix(".") { host.removeLast() }
        guard !host.isEmpty else { return nil }
        return canonicalIPv4(host) ?? host
    }

    /// RFC 6265 §5.1.3: an IP address only matches itself, never a domain suffix.
    static func isIPAddress(_ host: String) -> Bool {
        guard let host = canonical(host) else { return false }
        return host.contains(":") || canonicalIPv4(host) != nil
    }

    /// `localhost`, 127.0.0.0/8 and `::1`, which browsers treat as secure
    /// contexts over plain http. Not `*.localhost`.
    static func isLoopback(_ host: String?) -> Bool {
        guard let host = canonical(host) else { return false }
        return host == "localhost" || host == "::1" || (canonicalIPv4(host)?.hasPrefix("127.") ?? false)
    }

    /// The WHATWG URL IPv4 parser: up to four decimal, octal (`0` prefix) or
    /// hexadecimal (`0x` prefix) parts, the last one filling the remaining
    /// bytes. Nil when `host` is not an IPv4 address.
    static func canonicalIPv4(_ host: String) -> String? {
        guard !host.isEmpty, host.utf8.allSatisfy({ $0 > 0x20 && $0 < 0x7f }) else { return nil }
        var parts = host.split(separator: ".", omittingEmptySubsequences: false)
        if parts.count > 1, parts.last?.isEmpty == true { parts.removeLast() }
        guard (1...4).contains(parts.count) else { return nil }
        var numbers = [UInt64]()
        for part in parts {
            guard let number = ipv4Number(part) else { return nil }
            numbers.append(number)
        }
        let last = numbers.removeLast()
        guard numbers.allSatisfy({ $0 <= 255 }), last < UInt64(1) << UInt64(8 * (4 - numbers.count)) else {
            return nil
        }
        var address = last
        for (index, number) in numbers.enumerated() { address += number << UInt64(8 * (3 - index)) }
        return [24, 16, 8, 0].map { String((address >> UInt64($0)) & 0xff) }.joined(separator: ".")
    }

    private static func ipv4Number(_ part: Substring) -> UInt64? {
        guard !part.isEmpty else { return nil }
        var digits = part
        var radix = 10
        if digits.hasPrefix("0x") || digits.hasPrefix("0X") {
            digits = digits.dropFirst(2)
            radix = 16
        } else if digits.count > 1 && digits.hasPrefix("0") {
            digits = digits.dropFirst()
            radix = 8
        }
        if digits.isEmpty { return 0 }
        let valid = digits.utf8.allSatisfy { byte in
            switch radix {
            case 8: return (48...55).contains(byte)
            case 10: return (48...57).contains(byte)
            default: return (48...57).contains(byte) || (97...102).contains(byte) || (65...70).contains(byte)
            }
        }
        // A part too large for 64 bits is too large for an address as well.
        return valid ? UInt64(digits, radix: radix) : nil
    }

    private static func canonicalIPv6(_ literal: String) -> String? {
        // A zone (`fe80::1%en0`) is kept as written.
        let parts = literal.split(separator: "%", maxSplits: 1, omittingEmptySubsequences: false)
        var address = in6_addr()
        guard inet_pton(AF_INET6, String(parts[0]), &address) == 1 else { return nil }
        var buffer = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
        let written = buffer.withUnsafeMutableBufferPointer { output -> String? in
            guard let base = output.baseAddress,
                  inet_ntop(AF_INET6, &address, base, socklen_t(output.count)) != nil else { return nil }
            return String(cString: base)
        }
        guard let text = written else { return nil }
        return parts.count == 2 ? text + "%" + parts[1] : text
    }
}

/// Which cookies a request may carry and which server cookies are stored, by
/// RFC 6265 and the cookie prefixes of RFC 6265bis, like a browser cookie jar.
internal enum SocketCookieScope {
    static func isSecureScheme(_ scheme: String?) -> Bool {
        let scheme = scheme?.lowercased()
        return scheme == "https" || scheme == "wss"
    }

    /// https/wss, and plain http/ws to a loopback host, as browsers treat them.
    static func isSecureContext(_ url: URL?) -> Bool {
        guard let url else { return false }
        if isSecureScheme(url.scheme) { return true }
        let scheme = url.scheme?.lowercased()
        return (scheme == "http" || scheme == "ws") && SocketHost.isLoopback(url.host)
    }

    /// Cookies are stored for http(s) URLs; a WebSocket URL is the http(s) URL
    /// of the same handshake.
    static func httpURL(for url: URL) -> URL {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return url }
        switch components.scheme?.lowercased() {
        case "ws": components.scheme = "http"
        case "wss": components.scheme = "https"
        default: return url
        }
        return components.url ?? url
    }

    /// The canonical host (see `SocketHost.canonical`).
    static func normalizedHost(_ host: String?) -> String? {
        SocketHost.canonical(host)
    }

    static func isIPAddress(_ host: String) -> Bool {
        SocketHost.isIPAddress(host)
    }

    /// RFC 6265 §5.4 request matching: domain (Foundation marks domain cookies
    /// with a leading dot, others are host-only), path, Secure (only to a secure
    /// context) and expiry. Cookies are not port-scoped.
    static func cookies(_ cookies: [HTTPCookie], allowedFor url: URL, now: Date = Date()) -> [HTTPCookie] {
        guard let host = normalizedHost(url.host), url.scheme != nil else { return [] }
        let secure = isSecureContext(url)
        // The request-uri path, still percent-encoded (RFC 6265 §5.1.4);
        // URLComponents also keeps a trailing slash that `URL.path` drops.
        let rawPath = URLComponents(url: url, resolvingAgainstBaseURL: false)?.percentEncodedPath ?? url.path
        let path = rawPath.isEmpty ? "/" : rawPath
        return cookies.filter { cookie in
            if let expires = cookie.expiresDate, expires < now { return false }
            if cookie.isSecure && !secure { return false }
            guard domainMatches(host: host, cookieDomain: cookie.domain) else { return false }
            let cookiePath = cookie.path.isEmpty ? "/" : cookie.path
            guard path == cookiePath || (path.hasPrefix(cookiePath) &&
                (cookiePath.hasSuffix("/") || path.dropFirst(cookiePath.count).hasPrefix("/"))) else { return false }
            return true
        }
    }

    /// RFC 6265 §5.4 step 2: longer paths first; cookies with paths of the same
    /// length keep the given order, which callers pass oldest first.
    static func ordered(_ cookies: [HTTPCookie]) -> [HTTPCookie] {
        cookies.enumerated().sorted { lhs, rhs in
            let left = pathLength(lhs.element), right = pathLength(rhs.element)
            return left != right ? left > right : lhs.offset < rhs.offset
        }.map(\.element)
    }

    private static func pathLength(_ cookie: HTTPCookie) -> Int {
        cookie.path.isEmpty ? 1 : cookie.path.utf8.count
    }

    /// Whether a cookie the server at `url` set may be stored (RFC 6265 §5.3,
    /// RFC 6265bis §5.7):
    /// - a Secure cookie only from a secure context;
    /// - its domain must domain-match the host that answered; an IP address only itself;
    /// - `__Secure-` requires Secure; `__Host-` requires Secure, no Domain
    ///   attribute and the path `/` (prefixes compared case-insensitively).
    /// Foundation's storage additionally rejects public-suffix domains.
    static func acceptsServerCookie(_ cookie: HTTPCookie, from url: URL) -> Bool {
        guard let host = normalizedHost(url.host) else { return false }
        if cookie.isSecure && !isSecureContext(url) { return false }
        guard domainMatches(host: host, cookieDomain: cookie.domain) else { return false }
        let name = cookie.name.lowercased()
        if name.hasPrefix("__secure-") && !cookie.isSecure { return false }
        if name.hasPrefix("__host-") && !(cookie.isSecure && !cookie.domain.hasPrefix(".") && cookie.path == "/") {
            return false
        }
        return true
    }

    /// RFC 6265bis §5.7: a cookie from a context that is not secure is ignored
    /// when an unexpired `Secure` cookie of the same name is stored whose domain
    /// domain-matches the new cookie's domain or the other way round, and whose
    /// path the new cookie's path path-matches. Plain http cannot replace or
    /// shadow a `Secure` cookie that way.
    static func shadowsSecureCookie(_ cookie: HTTPCookie, in stored: [HTTPCookie], now: Date = Date()) -> Bool {
        guard let domain = bareDomain(cookie.domain) else { return false }
        let path = cookie.path.isEmpty ? "/" : cookie.path
        return stored.contains { existing in
            guard existing.isSecure, existing.name == cookie.name,
                  let existingDomain = bareDomain(existing.domain) else { return false }
            if let expires = existing.expiresDate, expires < now { return false }
            guard domain == existingDomain || domain.hasSuffix("." + existingDomain) ||
                existingDomain.hasSuffix("." + domain) else { return false }
            let existingPath = existing.path.isEmpty ? "/" : existing.path
            return path == existingPath || (path.hasPrefix(existingPath) &&
                (existingPath.hasSuffix("/") || path.dropFirst(existingPath.count).hasPrefix("/")))
        }
    }

    private static func bareDomain(_ domain: String) -> String? {
        var domain = domain.lowercased()
        if domain.hasPrefix(".") { domain.removeFirst() }
        return normalizedHost(domain)
    }

    private static func domainMatches(host: String, cookieDomain: String) -> Bool {
        var domain = cookieDomain.lowercased()
        let domainCookie = domain.hasPrefix(".")
        if domainCookie { domain.removeFirst() }
        guard let domain = normalizedHost(domain) else { return false }
        if host == domain { return true }
        // Foundation may store a dotless host such as `localhost` as `localhost.local`.
        if !host.contains(".") && !isIPAddress(host) && domain == host + ".local" { return true }
        guard domainCookie, !isIPAddress(host), !isIPAddress(domain) else { return false }
        return host.hasSuffix("." + domain)
    }
}

/// The engine-owned store of server-set cookies (`.withCredentials`). The
/// engine and its redirect handler store every response through it, so the
/// RFC 6265 storage rules apply, and it records when each cookie was created:
/// Foundation neither orders by creation nor keeps the creation time when a
/// cookie is replaced, which RFC 6265 §5.3 asks for.
internal final class SocketCookieJar: @unchecked Sendable {
    let storage: HTTPCookieStorage
    private let lock = NSLock()
    private var creation = [String: UInt64]()
    private var nextCreation: UInt64 = 0

    init(storage: HTTPCookieStorage) {
        self.storage = storage
    }

    private static func identity(of cookie: HTTPCookie) -> String {
        cookie.name + "\u{0}" + cookie.domain.lowercased() + "\u{0}" + cookie.path
    }

    /// Stores the `Set-Cookie` fields of a response for `url`, the URL that answered.
    func store(_ response: HTTPURLResponse) {
        guard let url = response.url else { return }
        var headers = [String: String]()
        for (name, value) in response.allHeaderFields {
            headers[String(describing: name)] = String(describing: value)
        }
        store(responseHeaders: headers, from: url)
    }

    func store(responseHeaders headers: [String: String], from url: URL) {
        let url = SocketCookieScope.httpURL(for: url)
        // Apple's storage takes prefixed cookies only for an https URL, but a
        // loopback host over plain http is a secure context too. The rules
        // were checked here already, so such a URL is stored as https.
        let storageURL = SocketCookieScope.isSecureContext(url) ? Self.httpsURL(for: url) : url
        let accepted = HTTPCookie.cookies(withResponseHeaderFields: headers, for: storageURL)
            .filter { SocketCookieScope.acceptsServerCookie($0, from: url) }
        guard !accepted.isEmpty else { return }
        lock.lock()
        defer { lock.unlock() }
        let kept: [HTTPCookie]
        if SocketCookieScope.isSecureContext(url) {
            kept = accepted
        } else {
            let stored = storage.cookies ?? []
            kept = accepted.filter { !SocketCookieScope.shadowsSecureCookie($0, in: stored) }
        }
        guard !kept.isEmpty else { return }
        storage.setCookies(kept, for: storageURL, mainDocumentURL: nil)
        let present = Set((storage.cookies ?? []).map(Self.identity(of:)))
        creation = creation.filter { present.contains($0.key) }
        for cookie in kept {
            let key = Self.identity(of: cookie)
            // A replaced cookie keeps its creation time.
            guard present.contains(key), creation[key] == nil else { continue }
            creation[key] = nextCreation
            nextCreation += 1
        }
    }

    private static func httpsURL(for url: URL) -> URL {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              components.scheme?.lowercased() == "http" else { return url }
        components.scheme = "https"
        return components.url ?? url
    }

    /// The stored cookies RFC 6265 allows for `url`, oldest first. Cookies put
    /// into `storage` directly come last, in the storage's order.
    func cookies(for url: URL) -> [HTTPCookie] {
        lock.lock()
        defer { lock.unlock() }
        let matching = SocketCookieScope.cookies(storage.cookies ?? [], allowedFor: url)
        return matching.enumerated().sorted { lhs, rhs in
            let left = creation[Self.identity(of: lhs.element)] ?? .max
            let right = creation[Self.identity(of: rhs.element)] ?? .max
            return left != right ? left < right : lhs.offset < rhs.offset
        }.map(\.element)
    }

    func removeAll() {
        lock.lock()
        defer { lock.unlock() }
        for cookie in storage.cookies ?? [] { storage.deleteCookie(cookie) }
        creation.removeAll()
    }
}

/// What a request may carry in its single `Cookie` header, decided the same way
/// for the first request and for every redirect hop, so a redirect never
/// widens what is sent:
/// - an explicit `Cookie` from `.extraHeaders` is the whole header on the
///   configured host, on any scheme or port, and is never sent to another host;
/// - otherwise, and on every other host, the configured `.cookies` and the
///   cookies the server set (`.withCredentials`) that RFC 6265 allows for the
///   URL, longer paths first, then oldest first (configured ones in their
///   configured order, before the server's).
internal struct SocketRequestCookies {
    var configured: [HTTPCookie] = []
    var jar: SocketCookieJar?
    var explicitHeader: String?

    /// The header value, or nil for no `Cookie` header.
    func header(for url: URL?, configuredHost: String?) -> String? {
        guard let url else { return nil }
        if let explicitHeader, let host = SocketCookieScope.normalizedHost(url.host),
           host == SocketCookieScope.normalizedHost(configuredHost) {
            return explicitHeader
        }
        let managed = SocketCookieScope.cookies(configured, allowedFor: url) + (jar?.cookies(for: url) ?? [])
        return HTTPCookie.requestHeaderFields(with: SocketCookieScope.ordered(managed))["Cookie"]
    }
}
