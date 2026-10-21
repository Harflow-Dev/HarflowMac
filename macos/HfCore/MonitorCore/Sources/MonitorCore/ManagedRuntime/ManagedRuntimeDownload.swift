import Foundation

// MARK: - ManagedRuntimeDownloading

/// Bounded TLS-only downloads. Host restrictions apply to every redirect and the final response.
public protocol ManagedRuntimeDownloading: Sendable {
    func download(url: URL, maximumBytes: Int, requiredHost: String?) async throws -> Data
}

// MARK: - ManagedRuntimeDownloader

/// Ephemeral system-TLS transport with no disk cache, cookies, or ambient endpoint configuration.
public struct ManagedRuntimeDownloader: ManagedRuntimeDownloading {
    private let protocolClasses: @Sendable () -> [AnyClass]

    /// Constructs the production transport using system TLS and the hardened ephemeral configuration.
    public init() { self.protocolClasses = { [] } }

    /// Adds constructor-only request handlers for deterministic tests without changing transport policy.
    init(protocolClasses: @escaping @Sendable () -> [AnyClass]) {
        self.protocolClasses = protocolClasses
    }

    public func download(url: URL, maximumBytes: Int, requiredHost: String?) async throws -> Data {
        let transfer = ManagedRuntimeTransfer(maximumBytes: maximumBytes, requiredHost: requiredHost, protocolClasses: protocolClasses())
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                transfer.start(url: url, continuation: continuation)
            }
        } onCancel: {
            transfer.cancel()
        }
    }
}

// MARK: - ManagedRuntimeTransfer

final class ManagedRuntimeTransfer: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private let maximumBytes: Int
    private let requiredHost: String?
    private let protocolClasses: [AnyClass]
    private var continuation: CheckedContinuation<Data, Error>?
    private var session: URLSession?
    private var task: URLSessionDataTask?
    private var bytes = Data()
    private var cancelled = false
    private var failure: Error?

    init(maximumBytes: Int, requiredHost: String?, protocolClasses: [AnyClass]) {
        self.maximumBytes = maximumBytes
        self.requiredHost = requiredHost
        self.protocolClasses = protocolClasses
    }

    private func allowed(_ url: URL?) -> Bool {
        guard let url, url.scheme == "https", url.user == nil, url.password == nil else { return false }
        return requiredHost == nil || url.host == requiredHost
    }

    func start(url: URL, continuation: CheckedContinuation<Data, Error>) {
        lock.lock()
        defer { lock.unlock() }
        guard !cancelled, allowed(url), maximumBytes > 0 else {
            continuation.resume(throwing: ManagedRuntimeFailure("Managed runtime download was cancelled or has an unsafe URL."))
            return
        }
        self.continuation = continuation
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 60
        config.timeoutIntervalForResource = 180
        config.urlCache = nil
        config.httpCookieStorage = nil
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.protocolClasses = protocolClasses + (config.protocolClasses ?? [])
        let session = URLSession(configuration: config, delegate: self, delegateQueue: nil)
        self.session = session
        task = session.dataTask(with: url)
        task?.resume()
    }

    func cancel() {
        lock.lock()
        cancelled = true
        let task = task
        lock.unlock()
        task?.cancel()
    }

    func urlSession(_: URLSession, task _: URLSessionTask, willPerformHTTPRedirection _: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        guard allowed(request.url) else {
            failure = ManagedRuntimeFailure("Managed runtime download refused an unsafe redirect.")
            completionHandler(nil)
            return
        }
        completionHandler(request)
    }

    func urlSession(_: URLSession, dataTask _: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        guard allowed(response.url), let http = response as? HTTPURLResponse, http.statusCode == 200,
              response.expectedContentLength <= Int64(maximumBytes) else {
            if failure == nil {
                failure = ManagedRuntimeFailure("Managed runtime download returned an invalid response or exceeded its size limit.")
            }
            completionHandler(.cancel)
            return
        }
        completionHandler(.allow)
    }

    func urlSession(_: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard data.count <= maximumBytes - bytes.count else {
            failure = ManagedRuntimeFailure("Managed runtime download exceeded its size limit.")
            dataTask.cancel()
            return
        }
        bytes.append(data)
    }

    func urlSession(_ session: URLSession, task _: URLSessionTask, didCompleteWithError error: Error?) {
        lock.lock()
        let continuation = continuation
        self.continuation = nil
        task = nil
        self.session = nil
        lock.unlock()
        session.finishTasksAndInvalidate()
        if let error = failure ?? error {
            continuation?.resume(throwing: error)
        } else {
            continuation?.resume(returning: bytes)
        }
    }
}
