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

    /// What a redirected request may carry in its `Cookie` header, and the jar
    /// that stores the cookies each followed hop sets. A polling session lives
    /// across configuration changes, so the engine updates it.
    internal var requestCookies: SocketRequestCookies {
        get { requestCookiesLock.lock(); defer { requestCookiesLock.unlock() }; return _requestCookies }
        set { requestCookiesLock.lock(); _requestCookies = newValue; requestCookiesLock.unlock() }
    }
    private var _requestCookies: SocketRequestCookies
    private let requestCookiesLock = NSLock()

    /// Tasks whose redirect chain has left the origin of their first request.
    private var leftFirstOrigin = Set<Int>()
    private let leftFirstOriginLock = NSLock()

    internal init(tlsConfiguration: SocketTLSConfiguration,
                  forwardingDelegate: URLSessionDelegate?,
                  clientCertificate: URLCredential? = nil, credentialOrigin: URL? = nil,
                  requestCookies: SocketRequestCookies = SocketRequestCookies()) {
        self._requestCookies = requestCookies
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

    /// The redirect statuses that are followed, as in Fetch and URLSession.
    /// 300 Multiple Choices is not a redirect to follow.
    static let followedStatuses: Set<Int> = [301, 302, 303, 307, 308]

    /// Whether a redirect would leave https/wss for plain http/ws. Checked
    /// against the current hop and the first request, because looking only at
    /// the first URL permits http -> https -> http downgrades.
    static func refusesDowngrade(firstURL: URL?, currentURL: URL?, candidate: URLRequest) -> Bool {
        let secure = SocketCookieScope.isSecureScheme(firstURL?.scheme) ||
            SocketCookieScope.isSecureScheme(currentURL?.scheme)
        return secure && !SocketCookieScope.isSecureScheme(candidate.url?.scheme)
    }

    /// Whether a redirect of a request with a body must not be followed.
    ///
    /// The polling POST carries Engine.IO packets and the CONNECT `auth`
    /// payload. URLSession turns it into a GET without body on 301, 302 and 303,
    /// so the packets would be lost while the write looks successful, and it
    /// resends the body to any host on 307 and 308. Such a request therefore
    /// follows only 307/308, keeps its method and stays on the host of the
    /// first request (any scheme or port). GET and HEAD follow every
    /// followed status.
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

    /// Whether `candidate` goes to another host or port than the first
    /// request, so a `Host` header written for that request no longer fits.
    static func changesHostOrPort(from first: URL?, to candidate: URL?) -> Bool {
        func port(_ url: URL?) -> Int? {
            url.map { $0.port ?? (SocketCookieScope.isSecureScheme($0.scheme) ? 443 : 80) }
        }
        return SocketCookieScope.normalizedHost(first?.host) != SocketCookieScope.normalizedHost(candidate?.host) ||
            port(first) != port(candidate)
    }

    /// Records the hops of a redirect and returns whether the chain of `task`
    /// has left the origin of its first request at any point.
    private func chainHasLeftFirstOrigin(_ task: Int, firstOrigin: String?, hops: [URL?]) -> Bool {
        let leaves = firstOrigin == nil || hops.contains { Self.origin(of: $0) != firstOrigin }
        leftFirstOriginLock.lock()
        defer { leftFirstOriginLock.unlock() }
        if leaves { leftFirstOrigin.insert(task) }
        return leftFirstOrigin.contains(task)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        let once = SocketOnce<URLRequest?>(completionHandler)
        // Without a followed redirect URLSession completes the task with the
        // 3xx response, which the polling transport reports as an error.
        let status = response.statusCode
        let firstRequest = task.originalRequest
        let firstURL = firstRequest?.url
        let firstOrigin = Self.origin(of: firstURL)
        let currentURL = response.url
        let presentsCertificate = clientCertificate != nil
        let refuses: @Sendable (URLRequest) -> Bool = { candidate in
            Self.refusesDowngrade(firstURL: firstURL, currentURL: currentURL, candidate: candidate) ||
                Self.refusesBodyRedirect(status: status, firstRequest: firstRequest, candidate: candidate) ||
                Self.refusesCertificateRedirect(presentsCertificate, firstOrigin: firstOrigin, candidate: candidate)
        }
        // A refused redirect is not offered to an external delegate.
        guard Self.followedStatuses.contains(status), !refuses(request) else { once.call(nil); return }
        let cookies = SocketUncheckedSendableBox(requestCookies)
        let taskIdentifier = task.taskIdentifier
        let finish: @Sendable (URLRequest?) -> Void = { [self] candidate in
            // Checked again: an external delegate may return another request.
            guard var candidate = candidate, !refuses(candidate) else { once.call(nil); return }
            // Credentials of the first origin go only to that origin, and end
            // with the first change of origin: a later hop back (A -> B -> A)
            // does not restore them. URLSession drops Authorization even on a
            // redirect to the same origin, so it is put back from the first request.
            let leftFirstOrigin = chainHasLeftFirstOrigin(taskIdentifier, firstOrigin: firstOrigin,
                                                          hops: [currentURL, candidate.url])
            for field in ["Authorization", "Proxy-Authorization"] {
                if leftFirstOrigin {
                    candidate.setValue(nil, forHTTPHeaderField: field)
                } else if let value = firstRequest?.value(forHTTPHeaderField: field) {
                    candidate.setValue(value, forHTTPHeaderField: field)
                }
            }
            // A `Host` from `.extraHeaders` named the first host and port.
            if Self.changesHostOrPort(from: firstURL, to: candidate.url) {
                candidate.setValue(nil, forHTTPHeaderField: "Host")
            }
            // URLSession copies an explicit Cookie header (`.cookies`) to any
            // destination, which hands the session to whatever origin the
            // server redirects to. The same flaw was fixed as CVE-2022-0155
            // (follow-redirects), CVE-2023-43804 (urllib3), CVE-2022-27776 (curl)
            // and in undici (GHSA-q768-x9m6-m9qp). The header is rebuilt for the
            // new URL instead, after storing the cookies this hop set.
            cookies.value.jar?.store(response)
            candidate.httpShouldHandleCookies = false
            candidate.setValue(cookies.value.header(for: candidate.url, configuredHost: firstURL?.host),
                               forHTTPHeaderField: "Cookie")
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
        leftFirstOriginLock.lock()
        leftFirstOrigin.remove(task.taskIdentifier)
        leftFirstOriginLock.unlock()
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
