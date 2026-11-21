import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
#if canImport(Security)
import Security
#endif

/// Intercepts trust and lifecycle callbacks without replacing the internal
/// delegate. Server-trust challenges are reserved for the configured policy;
/// an external delegate cannot bypass hostname verification or configured pins.
internal class SocketSessionDelegateProxy: NSObject, URLSessionDataDelegate {
    private let clientCertificate: URLCredential?
    private let credentialOrigin: URL?
    internal let tlsConfiguration: SocketTLSConfiguration
    internal weak var forwardingDelegate: URLSessionDelegate?
    internal var onInvalidation: ((URLSession, Error?) -> Void)?

    /// Bodies being accumulated under a byte cap, keyed by task identifier.
    /// Only populated when `.bufferLimits(maximumPollingResponseBytes:)` is
    /// configured; without it the engine keeps using the completion-handler
    /// task form, whose body the URL loading system delivers whole.
    private var boundedBodies = [Int: SocketBoundedBody]()
    private let boundedBodyLock = NSLock()

    /// What a redirected request may carry in its `Cookie` header. A polling
    /// session lives across configuration changes, so the engine updates it.
    internal var redirectCookies: SocketRedirectCookies {
        get { redirectCookiesLock.lock(); defer { redirectCookiesLock.unlock() }; return _redirectCookies }
        set { redirectCookiesLock.lock(); _redirectCookies = newValue; redirectCookiesLock.unlock() }
    }
    private var _redirectCookies: SocketRedirectCookies
    private let redirectCookiesLock = NSLock()

    internal init(tlsConfiguration: SocketTLSConfiguration,
                  forwardingDelegate: URLSessionDelegate?,
                  clientCertificate: URLCredential? = nil, credentialOrigin: URL? = nil,
                  redirectCookies: [HTTPCookie] = [], redirectCookieStorage: HTTPCookieStorage? = nil,
                  explicitCookieHeader: String? = nil) {
        self._redirectCookies = SocketRedirectCookies(configured: redirectCookies, jar: redirectCookieStorage,
                                                      explicitHeader: explicitCookieHeader)
        self.clientCertificate = clientCertificate
        self.credentialOrigin = credentialOrigin
        self.tlsConfiguration = tlsConfiguration
        self.forwardingDelegate = forwardingDelegate
    }

    private func handleAuthentication(_ challenge: URLAuthenticationChallenge,
                                      completion: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) -> Bool {
        #if canImport(Security)
        if challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodClientCertificate,
           let clientCertificate {
            let space = challenge.protectionSpace
            // A redirect must not disclose the configured identity to another origin.
            guard let origin = credentialOrigin,
                  SocketCookieScope.isSecureScheme(origin.scheme),
                  SocketCookieScope.isSecureScheme(space.protocol),
                  SocketCredentialHost.matches(origin.host, space.host),
                  (origin.port ?? 443) == space.port,
                  challenge.previousFailureCount == 0,
                  clientCertificate.identity != nil else {
                completion(.cancelAuthenticationChallenge, nil)
                return true
            }
            completion(.useCredential, clientCertificate)
            return true
        }
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust else { return false }
        if case .systemDefault = tlsConfiguration {
            completion(.performDefaultHandling, nil)
        } else if let trust = challenge.protectionSpace.serverTrust,
                  SocketServerTrustEvaluator.evaluate(trust, host: challenge.protectionSpace.host,
                                                      configuration: tlsConfiguration) {
            completion(.useCredential, URLCredential(trust: trust))
        } else {
            completion(.cancelAuthenticationChallenge, nil)
        }
        return true
        #else
        return false
        #endif
    }

    func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        let once = SocketOnce(completionHandler)
        guard !handleAuthentication(challenge, completion: { once.call(($0, $1)) }) else { return }
        #if canImport(ObjectiveC)
        if forwardingDelegate?.urlSession?(session, didReceive: challenge,
                                           completionHandler: { once.call(($0, $1)) }) == nil {
            once.call((.performDefaultHandling, nil))
        }
        #else
        if let delegate = forwardingDelegate {
            delegate.urlSession(session, didReceive: challenge, completionHandler: { once.call(($0, $1)) })
        } else { once.call((.performDefaultHandling, nil)) }
        #endif
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        let once = SocketOnce(completionHandler)
        guard !handleAuthentication(challenge, completion: { once.call(($0, $1)) }) else { return }
        #if canImport(ObjectiveC)
        if (forwardingDelegate as? URLSessionTaskDelegate)?.urlSession?(session, task: task, didReceive: challenge,
                                                                       completionHandler: { once.call(($0, $1)) }) == nil {
            once.call((.performDefaultHandling, nil))
        }
        #else
        if let delegate = forwardingDelegate as? URLSessionTaskDelegate {
            delegate.urlSession(session, task: task, didReceive: challenge, completionHandler: { once.call(($0, $1)) })
        } else { once.call((.performDefaultHandling, nil)) }
        #endif
    }

    /// Scheme, host and effective port; nil for a URL without a host.
    static func origin(of url: URL?) -> String? {
        guard let url = url, let scheme = url.scheme?.lowercased(),
              let host = SocketCookieScope.normalizedHost(url.host) else {
            return nil
        }
        let secure = SocketCookieScope.isSecureScheme(scheme)
        let port = url.port ?? (secure ? 443 : 80)
        return "\(secure ? "https" : "http")://\(host):\(port)"
    }

    /// Whether a redirect of a request with a body must not be followed.
    ///
    /// The polling POST carries Engine.IO packets and the CONNECT `auth`
    /// payload. URLSession turns it into a GET without body on 301, 302 and 303,
    /// so the packets would be lost while the write looks successful, and it
    /// resends the body to any host on 307 and 308. Such a request therefore
    /// follows only 307/308, keeps its method and stays on the host of the
    /// first request (any scheme or port). GET and HEAD follow every redirect.
    static func refusesBodyRedirect(status: Int, firstRequest: URLRequest?, candidate: URLRequest) -> Bool {
        let method = (firstRequest?.httpMethod ?? "GET").uppercased()
        guard method != "GET" && method != "HEAD" else { return false }
        guard status == 307 || status == 308,
              (candidate.httpMethod ?? "GET").uppercased() == method,
              let host = SocketCookieScope.normalizedHost(candidate.url?.host),
              host == SocketCookieScope.normalizedHost(firstRequest?.url?.host) else { return true }
        return false
    }

    /// Whether a redirect must not be followed because a client certificate is
    /// configured. The certificate is only presented to the configured origin,
    /// so a redirect to another scheme, host or port is refused instead of
    /// connecting there without it.
    static func refusesCertificateRedirect(_ presentsCertificate: Bool, firstOrigin: String?,
                                           candidate: URLRequest) -> Bool {
        guard presentsCertificate else { return false }
        let destination = origin(of: candidate.url)
        return destination == nil || destination != firstOrigin
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        let once = SocketOnce<URLRequest?>(completionHandler)
        // Without a followed redirect URLSession completes the task with the
        // 3xx response, which the polling transport reports as a write error.
        let status = response.statusCode
        let firstRequest = task.originalRequest
        let firstURL = firstRequest?.url
        let firstOrigin = SocketSessionDelegateProxy.origin(of: firstURL)
        let presentsCertificate = clientCertificate != nil
        if Self.refusesBodyRedirect(status: status, firstRequest: firstRequest, candidate: request) ||
            Self.refusesCertificateRedirect(presentsCertificate, firstOrigin: firstOrigin, candidate: request) {
            once.call(nil); return
        }
        // The redirect response is the current hop. Looking only at the
        // original URL permits http -> https -> http downgrades.
        let secureOrigin = SocketCookieScope.isSecureScheme(response.url?.scheme) ||
            SocketCookieScope.isSecureScheme(task.originalRequest?.url?.scheme)
        let currentOrigin = SocketSessionDelegateProxy.origin(of: response.url)
        let cookies = SocketUncheckedSendableBox(redirectCookies)
        let finish: @Sendable (URLRequest?) -> Void = { candidate in
            guard var candidate = candidate else { once.call(nil); return }
            guard !(secureOrigin && !SocketCookieScope.isSecureScheme(candidate.url?.scheme)) else {
                once.call(nil); return
            }
            // Checked again: an external delegate may return another request.
            guard !Self.refusesBodyRedirect(status: status, firstRequest: firstRequest, candidate: candidate),
                  !Self.refusesCertificateRedirect(presentsCertificate, firstOrigin: firstOrigin,
                                                   candidate: candidate) else {
                once.call(nil); return
            }
            // URLSession drops Authorization on redirects but copies an explicit
            // Cookie header (`.cookies`) to any destination, which hands the
            // session to whatever origin the server redirects to. The same flaw
            // was fixed as CVE-2022-0155 (follow-redirects), CVE-2023-43804
            // (urllib3), CVE-2022-27776 (curl) and in undici (GHSA-q768-x9m6-m9qp).
            let destination = SocketSessionDelegateProxy.origin(of: candidate.url)
            let sameOrigin = destination != nil && destination == currentOrigin && destination == firstOrigin
            // Credentials of the first origin end with the first change of
            // origin and do not come back on a later hop to it (A -> B -> A).
            if !sameOrigin {
                candidate.setValue(nil, forHTTPHeaderField: "Authorization")
                candidate.setValue(nil, forHTTPHeaderField: "Proxy-Authorization")
            }
            if let header = cookies.value.header(for: candidate.url, firstURL: firstURL, sameOrigin: sameOrigin) {
                candidate.setValue(header, forHTTPHeaderField: "Cookie")
            }
            once.call(candidate)
        }
        #if canImport(ObjectiveC)
        if (forwardingDelegate as? URLSessionTaskDelegate)?.urlSession?(session, task: task,
            willPerformHTTPRedirection: response, newRequest: request, completionHandler: finish) == nil {
            finish(request)
        }
        #else
        if let delegate = forwardingDelegate as? URLSessionTaskDelegate {
            delegate.urlSession(session, task: task, willPerformHTTPRedirection: response,
                                newRequest: request, completionHandler: finish)
        } else { finish(request) }
        #endif
    }

    func urlSession(_ session: URLSession, didBecomeInvalidWithError error: Error?) {
        onInvalidation?(session, error)
        #if canImport(ObjectiveC)
        forwardingDelegate?.urlSession?(session, didBecomeInvalidWithError: error)
        #else
        forwardingDelegate?.urlSession(session, didBecomeInvalidWithError: error)
        #endif
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        finishBoundedBody(for: task.taskIdentifier, error: error)
        #if canImport(ObjectiveC)
        (forwardingDelegate as? URLSessionTaskDelegate)?.urlSession?(session, task: task, didCompleteWithError: error)
        #else
        (forwardingDelegate as? URLSessionTaskDelegate)?.urlSession(session, task: task, didCompleteWithError: error)
        #endif
    }

    // MARK: Gate R1 — bounded incoming polling body

    /// Registers a bounded accumulator for `task`. Must be called before the
    /// task is resumed.
    internal func boundBody(of task: URLSessionTask, to limit: Int,
                            completion: @escaping (Data?, URLResponse?, Error?) -> Void) {
        boundedBodyLock.lock()
        boundedBodies[task.taskIdentifier] = SocketBoundedBody(limit: limit, completion: completion)
        boundedBodyLock.unlock()
    }

    /// Refuses an announced `Content-Length` above the cap before any body
    /// byte is transferred.
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        boundedBodyLock.lock()
        guard var body = boundedBodies[dataTask.taskIdentifier] else {
            boundedBodyLock.unlock()
            completionHandler(.allow)

            return
        }

        body.response = response
        let announced = response.expectedContentLength
        if announced > 0 && announced > Int64(body.limit) {
            body.overflow = SocketBufferLimitError(buffer: .pollingResponse, limit: body.limit,
                                                   attempted: Int(clamping: announced), measuringBytes: true)
        }
        boundedBodies[dataTask.taskIdentifier] = body
        let refused = body.overflow != nil
        boundedBodyLock.unlock()

        completionHandler(refused ? .cancel : .allow)
    }

    /// Cancels a chunked response as soon as the accumulated bytes cross the
    /// cap, so an unannounced oversized body is never fully retained.
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        boundedBodyLock.lock()
        guard var body = boundedBodies[dataTask.taskIdentifier], body.overflow == nil else {
            boundedBodyLock.unlock()

            return
        }

        if body.data.count + data.count > body.limit {
            body.overflow = SocketBufferLimitError(buffer: .pollingResponse, limit: body.limit,
                                                   attempted: body.data.count + data.count, measuringBytes: true)
            body.data = Data()
            boundedBodies[dataTask.taskIdentifier] = body
            boundedBodyLock.unlock()
            dataTask.cancel()

            return
        }

        body.data.append(data)
        boundedBodies[dataTask.taskIdentifier] = body
        boundedBodyLock.unlock()
    }

    private func finishBoundedBody(for identifier: Int, error: Error?) {
        boundedBodyLock.lock()
        guard let body = boundedBodies.removeValue(forKey: identifier) else {
            boundedBodyLock.unlock()

            return
        }
        boundedBodyLock.unlock()

        if let overflow = body.overflow {
            // The cancellation this proxy issued is reported as the overflow,
            // not as a generic URL error.
            body.completion(nil, body.response, overflow)
        } else {
            body.completion(error == nil ? body.data : nil, body.response, error)
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didFinishCollecting metrics: URLSessionTaskMetrics) {
        #if canImport(ObjectiveC)
        (forwardingDelegate as? URLSessionTaskDelegate)?.urlSession?(session, task: task, didFinishCollecting: metrics)
        #else
        (forwardingDelegate as? URLSessionTaskDelegate)?.urlSession(session, task: task, didFinishCollecting: metrics)
        #endif
    }
}

/// One polling response body accumulated under a byte cap.
private struct SocketBoundedBody {
    let limit: Int
    let completion: (Data?, URLResponse?, Error?) -> Void
    var data = Data()
    var response: URLResponse?
    var overflow: SocketBufferLimitError?

    init(limit: Int, completion: @escaping (Data?, URLResponse?, Error?) -> Void) {
        self.limit = limit
        self.completion = completion
    }
}

/// Completion gates must tolerate external delegates invoking them more than once.
// The callback is taken exactly once under the lock, then invoked outside it.
// Callers are responsible for hopping any captured queue-owned state.
internal final class SocketOnce<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var callback: ((Value) -> Void)?
    internal init(_ callback: @escaping (Value) -> Void) { self.callback = callback }
    internal func call(_ value: Value) {
        lock.lock()
        let action = callback
        callback = nil
        lock.unlock()
        action?(value)
    }
}

#if compiler(>=5.5)
extension SocketSessionDelegateProxy: @unchecked Sendable {}
#endif

/// The `Cookie` header of a redirected request is rebuilt the way the first
/// request was built for that URL, so a redirect never widens what is sent:
/// - configured `.cookies` by RFC 6265 cookie rules (domain, path, Secure, expiry),
///   plus the engine jar when the request carried it explicitly (WebSocket);
/// - an explicit `Cookie` from `.extraHeaders` replaced those on the first
///   request. It is sent as written to the configured host on any scheme or
///   port, and never to another host.
internal struct SocketRedirectCookies {
    var configured: [HTTPCookie] = []
    /// The engine-owned jar when the request carried its cookies explicitly
    /// (the WebSocket handshake); Foundation scopes its `cookies(for:)`.
    var jar: HTTPCookieStorage?
    var explicitHeader: String?

    /// The header value to set (`nil` inside removes the header), or `nil`
    /// to keep URLSession's copy, which only happens when the request carries
    /// nothing this client manages and the origin did not change.
    func header(for url: URL?, firstURL: URL?, sameOrigin: Bool) -> String?? {
        if let explicitHeader {
            guard let host = SocketCookieScope.normalizedHost(url?.host),
                  host == SocketCookieScope.normalizedHost(firstURL?.host) else { return .some(nil) }
            return .some(explicitHeader)
        }
        guard !sameOrigin || !configured.isEmpty || jar != nil else { return nil }
        guard let url = url else { return .some(nil) }
        let allowed = SocketCookieScope.cookies(configured, allowedFor: url)
            + (jar?.cookies(for: SocketCookieScope.httpURL(for: url)) ?? [])
        return .some(HTTPCookie.requestHeaderFields(with: allowed)["Cookie"])
    }
}

/// Which configured cookies a request may carry. Used for the first request
/// and again for every redirect, so `.cookies` behave like a browser cookie jar.
internal enum SocketCookieScope {
    static func isSecureScheme(_ scheme: String?) -> Bool {
        let scheme = scheme?.lowercased()
        return scheme == "https" || scheme == "wss"
    }

    /// `HTTPCookieStorage` matches cookies against http(s) URLs; a WebSocket
    /// URL is looked up as the http(s) URL of the same handshake.
    static func httpURL(for url: URL) -> URL {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return url }
        switch components.scheme?.lowercased() {
        case "ws": components.scheme = "http"
        case "wss": components.scheme = "https"
        default: return url
        }
        return components.url ?? url
    }

    /// Lowercased, without IPv6 brackets or a trailing root dot.
    static func normalizedHost(_ host: String?) -> String? {
        guard var host = host?.lowercased(), !host.isEmpty else { return nil }
        if host.hasPrefix("[") && host.hasSuffix("]") { host = String(host.dropFirst().dropLast()) }
        if host.count > 1 && host.hasSuffix(".") { host = String(host.dropLast()) }
        return host.isEmpty ? nil : host
    }

    /// RFC 6265 §5.1.3: an IP address only matches itself, never a domain suffix.
    static func isIPAddress(_ host: String) -> Bool {
        if host.contains(":") { return true }
        let parts = host.split(separator: ".", omittingEmptySubsequences: false)
        return parts.count == 4 && parts.allSatisfy { !$0.isEmpty && $0.allSatisfy(\.isNumber) }
    }

    /// RFC 6265 request matching: domain (Foundation marks domain cookies with
    /// a leading dot, others are host-only), path, Secure and expiry. Cookies
    /// are not port-scoped.
    static func cookies(_ cookies: [HTTPCookie], allowedFor url: URL, now: Date = Date()) -> [HTTPCookie] {
        guard let host = normalizedHost(url.host), url.scheme != nil else { return [] }
        let secure = isSecureScheme(url.scheme)
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

    private static func domainMatches(host: String, cookieDomain: String) -> Bool {
        var domain = cookieDomain.lowercased()
        let domainCookie = domain.hasPrefix(".")
        if domainCookie { domain.removeFirst() }
        guard let domain = normalizedHost(domain) else { return false }
        if host == domain { return true }
        // Foundation may store a dotless host such as `localhost` as `localhost.local`.
        if !host.contains(".") && !isIPAddress(host) && domain == host + ".local" { return true }
        guard domainCookie, !isIPAddress(host) else { return false }
        return host.hasSuffix("." + domain)
    }
}
