import Dispatch
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

extension URLSessionWebSocketTransport {
    /// Owns a session independent of the polling session. The supplied request
    /// carries headers/cookies prepared by the engine; this adapter never rewrites
    /// them. The TLS policy and external delegate match the polling session.
    internal convenience init(request: URLRequest,
                              queue: DispatchQueue,
                              configuration: URLSessionConfiguration = .default,
                              tlsConfiguration: SocketTLSConfiguration = .systemDefault,
                              sessionDelegate: URLSessionDelegate? = nil,
                              clientCertificate: URLCredential? = nil,
                              maximumMessageSize: Int = 16 * 1024 * 1024,
                              maximumPendingBytes: Int = URLSessionWebSocketTransport.defaultMaximumPendingBytes,
                              maximumPendingBatches: Int = URLSessionWebSocketTransport.defaultMaximumPendingBatches,
                              maximumPendingMessages: Int = URLSessionWebSocketTransport.defaultMaximumPendingMessages) {
        precondition(maximumMessageSize > 0)
        let snapshot = configuration.copy() as! URLSessionConfiguration
        self.init(queue: queue, maximumPendingBytes: maximumPendingBytes,
                  maximumPendingBatches: maximumPendingBatches,
                  maximumPendingMessages: maximumPendingMessages) {
            URLSessionWebSocketConnection(request: request, queue: queue,
                                          configuration: snapshot,
                                          maximumMessageSize: maximumMessageSize,
                                          tlsConfiguration: tlsConfiguration, sessionDelegate: sessionDelegate,
                                          clientCertificate: clientCertificate)
        }
    }
}

/// Owns one concrete session/task pair. All mutable state is engine-queue confined.
/// Foundation completion closures do not mutate it; delegate callbacks hop onto
/// that queue through a weak proxy before validating session AND task identity.
internal final class URLSessionWebSocketConnection: EngineWebSocketConnection {
    internal var onEvent: ((EngineWebSocketEvent) -> Void)?
    fileprivate let queue: DispatchQueue
    private let request: URLRequest
    private let configuration: URLSessionConfiguration
    private let maximumMessageSize: Int
    private var session: URLSession?
    private var task: URLSessionWebSocketTask?
    private var started = false
    private let clientCertificate: URLCredential?
    private let tlsConfiguration: SocketTLSConfiguration
    private weak var sessionDelegate: URLSessionDelegate?

    internal init(request: URLRequest, queue: DispatchQueue,
                  configuration: URLSessionConfiguration, maximumMessageSize: Int,
                  tlsConfiguration: SocketTLSConfiguration = .systemDefault, sessionDelegate: URLSessionDelegate? = nil,
                  clientCertificate: URLCredential? = nil) {
        self.request = request
        self.queue = queue
        self.configuration = configuration
        self.maximumMessageSize = maximumMessageSize
        self.clientCertificate = clientCertificate
        self.tlsConfiguration = tlsConfiguration
        self.sessionDelegate = sessionDelegate
    }

    internal var closeDetails: (code: Int?, reason: Data?) {
        let code = task?.closeCode
        return (code == .invalid ? nil : code?.rawValue, task?.closeReason)
    }

    internal func start() {
        guard !started else { return }
        started = true
        let proxy = WebSocketSessionDelegateProxy(owner: self, tlsConfiguration: tlsConfiguration,
                                                  forwardingDelegate: sessionDelegate,
                                                  clientCertificate: clientCertificate, credentialOrigin: request.url)
        let session = URLSession(configuration: configuration, delegate: proxy, delegateQueue: nil)
        let task = session.webSocketTask(with: request)
        task.maximumMessageSize = maximumMessageSize
        self.session = session
        self.task = task
        task.resume()
    }

    internal func send(_ message: EngineWebSocketMessage, completion: @escaping (Error?) -> Void) {
        guard let task = task else {
            completion(EngineWebSocketError.notOpen)
            return
        }
        let payload: URLSessionWebSocketTask.Message
        switch message {
        case .text(let text): payload = .string(text)
        case .binary(let data): payload = .data(data)
        }
        let callback = SocketUncheckedSendableBox(completion)
        #if canImport(FoundationNetworking)
        // swift-corelibs-foundation exposes the async API rather than Apple's
        // completion-handler overload. This branch supports isolated Linux tests.
        Task {
            do { try await task.send(payload); callback.value(nil) }
            catch { callback.value(error) }
        }
        #else
        task.send(payload) { callback.value($0) }
        #endif
    }

    internal func receive(completion: @escaping (Result<EngineWebSocketMessage, Error>) -> Void) {
        guard let task = task else {
            completion(.failure(EngineWebSocketError.notOpen))
            return
        }
        let callback = SocketUncheckedSendableBox(completion)
        let deliver: @Sendable (Result<URLSessionWebSocketTask.Message, Error>) -> Void = { result in
            callback.value(result.flatMap { message in
                switch message {
                case .string(let text): return .success(.text(text))
                case .data(let data): return .success(.binary(data))
                @unknown default: return .failure(EngineWebSocketError.unsupportedMessage)
                }
            })
        }
        #if canImport(FoundationNetworking)
        Task {
            do { deliver(.success(try await task.receive())) }
            catch { deliver(.failure(error)) }
        }
        #else
        task.receive(completionHandler: deliver)
        #endif
    }

    internal func close(code: Int, reason: Data?) {
        guard let closeCode = URLSessionWebSocketTask.CloseCode(rawValue: code) else {
            cancel()
            return
        }
        task?.cancel(with: closeCode, reason: reason)
        let closingSession = session
        closingSession?.finishTasksAndInvalidate()
        // Do not leave a closing session retained indefinitely by Foundation.
        queue.socketAsyncAfter(deadline: .now() + 1) { closingSession?.invalidateAndCancel() }
        task = nil
        session = nil
    }

    internal func cancel() {
        task?.cancel()
        session?.invalidateAndCancel()
        task = nil
        session = nil
    }

    deinit { session?.invalidateAndCancel() }

    fileprivate func matches(_ session: URLSession, _ task: URLSessionTask? = nil) -> Bool {
        guard self.session === session else { return false }
        return task == nil || self.task === task
    }

    fileprivate func opened(_ session: URLSession, _ task: URLSessionWebSocketTask, _ protocolName: String?) {
        guard matches(session, task) else { return }
        let response = task.response as? HTTPURLResponse
        var headers = [String: String]()
        response?.allHeaderFields.forEach { headers[String(describing: $0.key)] = String(describing: $0.value) }
        onEvent?(.opened(protocol: protocolName, headers: headers))
    }

    fileprivate func closed(_ session: URLSession, _ task: URLSessionWebSocketTask,
                            _ code: URLSessionWebSocketTask.CloseCode, _ reason: Data?) {
        guard matches(session, task) else { return }
        onEvent?(.closed(code: code.rawValue, reason: reason, error: nil))
    }

    fileprivate func completed(_ session: URLSession, _ task: URLSessionTask, _ error: Error?) {
        guard matches(session, task) else { return }
        let code = self.task?.closeCode
        onEvent?(.closed(code: code == .invalid ? nil : code?.rawValue,
                         reason: self.task?.closeReason, error: error))
    }

    fileprivate func invalidated(_ session: URLSession, _ error: Error?) {
        guard matches(session) else { return }
        onEvent?(.closed(code: nil, reason: nil, error: error))
    }
}

/// URLSession retains its delegate; the proxy must not retain the connection.
/// The shared superclass enforces the same trust policy as HTTP polling.
internal final class WebSocketSessionDelegateProxy: SocketSessionDelegateProxy, URLSessionWebSocketDelegate {
    private weak var owner: URLSessionWebSocketConnection?
    private let queue: DispatchQueue

    internal init(owner: URLSessionWebSocketConnection, tlsConfiguration: SocketTLSConfiguration,
                  forwardingDelegate: URLSessionDelegate?,
                  clientCertificate: URLCredential? = nil, credentialOrigin: URL? = nil) {
        self.owner = owner
        self.queue = owner.queue
        super.init(tlsConfiguration: tlsConfiguration, forwardingDelegate: forwardingDelegate,
                   clientCertificate: clientCertificate, credentialOrigin: credentialOrigin)
    }

    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask,
                    didOpenWithProtocol protocolName: String?) {
        queue.socketAsync { [weak owner] in owner?.opened(session, webSocketTask, protocolName) }
        #if canImport(ObjectiveC)
        (forwardingDelegate as? URLSessionWebSocketDelegate)?.urlSession?(session, webSocketTask: webSocketTask,
                                                                        didOpenWithProtocol: protocolName)
        #else
        (forwardingDelegate as? URLSessionWebSocketDelegate)?.urlSession(session, webSocketTask: webSocketTask,
                                                                       didOpenWithProtocol: protocolName)
        #endif
    }

    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask,
                    didCloseWith closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?) {
        queue.socketAsync { [weak owner] in owner?.closed(session, webSocketTask, closeCode, reason) }
        #if canImport(ObjectiveC)
        (forwardingDelegate as? URLSessionWebSocketDelegate)?.urlSession?(session, webSocketTask: webSocketTask,
                                                                        didCloseWith: closeCode, reason: reason)
        #else
        (forwardingDelegate as? URLSessionWebSocketDelegate)?.urlSession(session, webSocketTask: webSocketTask,
                                                                       didCloseWith: closeCode, reason: reason)
        #endif
    }

    override func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        super.urlSession(session, task: task, didCompleteWithError: error)
        queue.socketAsync { [weak owner] in owner?.completed(session, task, error) }
    }

    override func urlSession(_ session: URLSession, didBecomeInvalidWithError error: Error?) {
        super.urlSession(session, didBecomeInvalidWithError: error)
        queue.socketAsync { [weak owner] in owner?.invalidated(session, error) }
    }
}

#if compiler(>=5.5)
// owner is assigned only during initialization and held weakly. Delegate methods
// only enqueue work; connection state is accessed exclusively on its serial queue.
extension WebSocketSessionDelegateProxy: @unchecked Sendable {}
#endif
