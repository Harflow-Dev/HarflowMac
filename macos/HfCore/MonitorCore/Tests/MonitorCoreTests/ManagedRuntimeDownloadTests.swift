import Foundation
@testable import MonitorCore
import Testing

@Suite("Managed runtime downloader", .serialized, .timeLimit(.minutes(1)))
struct ManagedRuntimeDownloadTests {
    private let url = URL(string: "https://files.pythonhosted.org/packages/fixture.whl")!

    @Test func givenUnsafeInitialURLOrZeroLimit_whenDownloading_thenItDoesNotCreateARequest() async {
        StubProtocol.reset(.success(Data("fixture".utf8)))
        let downloader = ManagedRuntimeDownloader(protocolClasses: { [StubProtocol.self] })

        await #expect(throws: ManagedRuntimeFailure.self) {
            try await downloader.download(url: URL(string: "http://files.pythonhosted.org/fixture.whl")!, maximumBytes: 10,
                                          requiredHost: "files.pythonhosted.org")
        }
        await #expect(throws: ManagedRuntimeFailure.self) {
            try await downloader.download(url: url, maximumBytes: 0, requiredHost: "files.pythonhosted.org")
        }
        #expect(StubProtocol.requestURLs.isEmpty)
    }

    @Test func givenNonSuccessOrOversizedResponse_whenDownloading_thenItFailsWithoutReturningData() async {
        let downloader = ManagedRuntimeDownloader(protocolClasses: { [StubProtocol.self] })

        StubProtocol.reset(.response(status: 404, contentLength: 7, data: Data("missing".utf8)))
        await #expect(throws: ManagedRuntimeFailure.self) {
            try await downloader.download(url: url, maximumBytes: 10, requiredHost: "files.pythonhosted.org")
        }

        StubProtocol.reset(.response(status: 200, contentLength: 11, data: Data(repeating: 0x61, count: 11)))
        await #expect(throws: ManagedRuntimeFailure.self) {
            try await downloader.download(url: url, maximumBytes: 10, requiredHost: "files.pythonhosted.org")
        }
    }

    @Test func givenChunkedResponseExceedingLimit_whenDownloading_thenItFails() async {
        StubProtocol.reset(.response(status: 200, contentLength: nil, data: Data(repeating: 0x61, count: 11)))
        let downloader = ManagedRuntimeDownloader(protocolClasses: { [StubProtocol.self] })

        await #expect(throws: ManagedRuntimeFailure.self) {
            try await downloader.download(url: url, maximumBytes: 10, requiredHost: "files.pythonhosted.org")
        }
    }

    @Test func givenAllowedHTTPSRedirectWithoutHostRestriction_whenDownloading_thenItReturnsFinalData() async throws {
        let target = URL(string: "https://example.com/fixture.whl")!
        StubProtocol.reset(.redirect(to: target))
        StubProtocol.finalData = Data("redirected".utf8)
        let downloader = ManagedRuntimeDownloader(protocolClasses: { [StubProtocol.self] })

        let data = try await downloader.download(url: url, maximumBytes: 64, requiredHost: nil)

        #expect(data == StubProtocol.finalData)
        #expect(StubProtocol.requestURLs == [url, target])
    }

    @Test(arguments: [
        "https://example.com/fixture.whl",
        "http://files.pythonhosted.org/fixture.whl",
        "https://user:password@files.pythonhosted.org/fixture.whl"
    ])
    func givenRedirectCallback_whenEvaluatingUnsafeAndAllowedRequests_thenItCompletesExactlyOnce(
        rejectedURL: String
    ) {
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        let task = session.dataTask(with: url)
        let response = HTTPURLResponse(url: url, statusCode: 302, httpVersion: nil, headerFields: nil)!
        let transfer = ManagedRuntimeTransfer(maximumBytes: 64, requiredHost: "files.pythonhosted.org", protocolClasses: [])

        var rejectedCalls = 0
        var rejectedRequest: URLRequest?
        transfer.urlSession(session, task: task, willPerformHTTPRedirection: response,
                            newRequest: URLRequest(url: URL(string: rejectedURL)!)) {
            rejectedCalls += 1
            rejectedRequest = $0
        }
        #expect(rejectedCalls == 1)
        #expect(rejectedRequest == nil)

        var allowedCalls = 0
        var allowedRequest = URLRequest(url: url)
        allowedRequest.httpMethod = "POST"
        allowedRequest.setValue("fixture", forHTTPHeaderField: "X-Harflow-Fixture")
        var receivedAllowedRequest: URLRequest?
        transfer.urlSession(session, task: task, willPerformHTTPRedirection: response,
                            newRequest: allowedRequest) {
            allowedCalls += 1
            receivedAllowedRequest = $0
        }
        #expect(allowedCalls == 1)
        #expect(receivedAllowedRequest == allowedRequest)
    }

    @Test func givenCancellationWhileTransportIsHeld_whenDownloading_thenItStopsLoadingWithoutData() async {
        StubProtocol.reset(.hold)
        let downloader = ManagedRuntimeDownloader(protocolClasses: { [StubProtocol.self] })
        let task = Task {
            try await downloader.download(url: url, maximumBytes: 64, requiredHost: "files.pythonhosted.org")
        }
        #expect(await waitUntil { StubProtocol.started })

        task.cancel()
        _ = await task.result

        #expect(await waitUntil { StubProtocol.stopped })
        #expect(StubProtocol.completedData == nil)
    }
}

private final class StubProtocol: URLProtocol {
    enum Mode {
        case hold
        case redirect(to: URL)
        case response(status: Int, contentLength: Int?, data: Data)
        case success(Data)
    }

    private static let lock = NSLock()
    private static var mode: Mode = .success(Data())
    private(set) static var requestURLs: [URL] = []
    private(set) static var started = false
    private(set) static var stopped = false
    private(set) static var completedData: Data?
    static var finalData = Data("fixture".utf8)

    static func reset(_ newMode: Mode) {
        lock.withLock {
            mode = newMode
            requestURLs = []
            started = false
            stopped = false
            completedData = nil
            finalData = Data("fixture".utf8)
        }
    }

    override static func canInit(with request: URLRequest) -> Bool { request.url?.scheme == "https" }
    override static func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let mode = Self.lock.withLock {
            Self.started = true
            if let url = request.url { Self.requestURLs.append(url) }
            return Self.mode
        }
        switch mode {
        case .hold:
            return
        case .redirect(let target):
            if request.url == target {
                send(status: 200, contentLength: Self.finalData.count, data: Self.finalData)
                return
            }
            guard let url = request.url,
                  let response = HTTPURLResponse(url: url, statusCode: 302, httpVersion: nil,
                                                 headerFields: ["Location": target.absoluteString]) else { return }
            client?.urlProtocol(self, wasRedirectedTo: URLRequest(url: target), redirectResponse: response)
        case .response(let status, let contentLength, let data):
            send(status: status, contentLength: contentLength, data: data)
        case .success:
            send(status: 200, contentLength: Self.finalData.count, data: Self.finalData)
        }
    }

    override func stopLoading() {
        Self.lock.withLock { Self.stopped = true }
    }

    private func send(status: Int, contentLength: Int?, data: Data) {
        guard let url = request.url,
              let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: nil,
                                             headerFields: contentLength.map { ["Content-Length": "\($0)"] }) else { return }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        Self.lock.withLock { Self.completedData = data }
        client?.urlProtocolDidFinishLoading(self)
    }
}
