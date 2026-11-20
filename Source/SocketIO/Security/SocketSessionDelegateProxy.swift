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

    /// The explicitly configured `.cookies`; a redirect to another origin
    /// carries only those that cookie rules allow for the new URL.
    private let redirectCookies: [HTTPCookie]

    internal init(tlsConfiguration: SocketTLSConfiguration,
                  forwardingDelegate: URLSessionDelegate?,
                  clientCertificate: URLCredential? = nil, credentialOrigin: URL? = nil,
                  redirectCookies: [HTTPCookie] = []) {
        self.redirectCookies = redirectCookies
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
                  ["https", "wss"].contains(origin.scheme?.lowercased() ?? ""),
                  ["https", "wss"].contains(space.protocol?.lowercased() ?? ""),
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

    /// RFC 6265 request matching: domain (Foundation marks domain cookies with
    /// a leading dot, others are host-only), path, Secure and expiry. Cookies
    /// are not port-scoped.
    static func cookies(_ cookies: [HTTPCookie], allowedFor url: URL, now: Date = Date()) -> [HTTPCookie] {
        guard let host = url.host?.lowercased(), let scheme = url.scheme?.lowercased() else { return [] }
        let secure = scheme == "https" || scheme == "wss"
        let path = url.path.isEmpty ? "/" : url.path
        return cookies.filter { cookie in
            if let expires = cookie.expiresDate, expires < now { return false }
            if cookie.isSecure && !secure { return false }
            let domain = cookie.domain.lowercased()
            if domain.hasPrefix(".") {
                let parent = String(domain.dropFirst())
                guard host == parent || host.hasSuffix("." + parent) else { return false }
            } else {
                guard host == domain else { return false }
            }
            let cookiePath = cookie.path.isEmpty ? "/" : cookie.path
            guard path == cookiePath || (path.hasPrefix(cookiePath) &&
                (cookiePath.hasSuffix("/") || path.dropFirst(cookiePath.count).hasPrefix("/"))) else { return false }
            return true
        }
    }

    /// Scheme, host and effective port; nil for a URL without a host.
    static func origin(of url: URL?) -> String? {
        guard let url = url, let scheme = url.scheme?.lowercased(), let host = url.host?.lowercased() else {
            return nil
        }
        let port = url.port ?? (["https", "wss"].contains(scheme) ? 443 : 80)
        let secure = ["https", "wss"].contains(scheme)
        return "\(secure ? "https" : "http")://\(host):\(port)"
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        let once = SocketOnce<URLRequest?>(completionHandler)
        // The redirect response is the current hop. Looking only at the
        // original URL permits http -> https -> http downgrades.
        let secureSchemes = ["https", "wss"]
        let secureOrigin = secureSchemes.contains(response.url?.scheme?.lowercased() ?? "") ||
            secureSchemes.contains(task.originalRequest?.url?.scheme?.lowercased() ?? "")
        let currentOrigin = SocketSessionDelegateProxy.origin(of: response.url)
        let firstOrigin = SocketSessionDelegateProxy.origin(of: task.originalRequest?.url)
        let configuredCookies = SocketUncheckedSendableBox(redirectCookies)
        let finish: @Sendable (URLRequest?) -> Void = { candidate in
            guard var candidate = candidate else { once.call(nil); return }
            let secureDestination = ["https", "wss"].contains(candidate.url?.scheme?.lowercased() ?? "")
            guard !(secureOrigin && !secureDestination) else { once.call(nil); return }
            // URLSession drops Authorization on redirects but copies an explicit
            // Cookie header (`.cookies`) to any destination, which hands the
            // session to whatever origin the server redirects to. The same flaw
            // was fixed as CVE-2022-0155 (follow-redirects), CVE-2023-43804
            // (urllib3), CVE-2022-27776 (curl) and in undici (GHSA-q768-x9m6-m9qp).
            // On another origin the header is rebuilt like a browser would: only
            // cookies whose domain, path, Secure flag and expiry allow the new
            // URL (http -> https on the same host, a parent-domain cookie on a
            // sibling host, another port of the same host) are kept.
            let destination = SocketSessionDelegateProxy.origin(of: candidate.url)
            if destination != currentOrigin || destination != firstOrigin {
                candidate.setValue(nil, forHTTPHeaderField: "Cookie")
                if let url = candidate.url {
                    let allowed = SocketSessionDelegateProxy.cookies(configuredCookies.value, allowedFor: url)
                    if let header = HTTPCookie.requestHeaderFields(with: allowed)["Cookie"] {
                        candidate.setValue(header, forHTTPHeaderField: "Cookie")
                    }
                }
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
