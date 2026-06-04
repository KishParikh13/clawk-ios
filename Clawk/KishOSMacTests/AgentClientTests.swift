import XCTest
@testable import KishOS

@MainActor
final class AgentClientTests: XCTestCase {
    override func tearDown() {
        super.tearDown()
        MockURLProtocol.handler = nil
    }

    func testToolInventoryResponseDecodes() throws {
        let json = """
        {
          "ok": true,
          "commands": [
            { "name": "/status", "status": "Available" }
          ],
          "engines": [
            { "name": "claude", "status": "Available", "detail": "opus" }
          ],
          "recentTools": [
            { "name": "Read", "count": 3, "lastSeen": "2026-06-04T05:16:48.243Z" }
          ],
          "updatedAt": "2026-06-04T05:20:00.000Z"
        }
        """.data(using: .utf8)!

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        let response = try decoder.decode(ToolInventoryResponse.self, from: json)

        XCTAssertTrue(response.ok)
        XCTAssertEqual(response.commands?.first?.name, "/status")
        XCTAssertEqual(response.engines?.first?.detail, "opus")
        XCTAssertEqual(response.recentTools?.first?.name, "Read")
        XCTAssertEqual(response.recentTools?.first?.count, 3)
        XCTAssertNotNil(response.updatedAt)
    }

    func testRefreshHealthSuccessSetsReadyAndFetchesTools() async throws {
        let client = makeClient { request in
            switch request.url?.path {
            case "/health":
                return jsonResponse(#"{ "ok": true }"#)
            case "/tools":
                return jsonResponse(#"{ "ok": true, "commands": [], "engines": [], "recentTools": [] }"#)
            default:
                return jsonResponse(#"{ "ok": false, "error": "unexpected path" }"#, statusCode: 404)
            }
        }

        await client.refreshHealth()

        XCTAssertEqual(client.miniStatus, "Online")
        XCTAssertEqual(client.httpStatus, "Online")
        XCTAssertEqual(client.agentStatus, "Online")
        XCTAssertEqual(client.chatStatus, "Ready")
        XCTAssertEqual(client.status, "Ready")
        XCTAssertEqual(client.toolInventoryStatus, "Ready")
    }

    func testRefreshHealthNetworkFailureMarksAllConnectionsOffline() async {
        let client = makeClient { _ in
            throw URLError(.cannotConnectToHost)
        }

        await client.refreshHealth()

        XCTAssertEqual(client.miniStatus, "Offline")
        XCTAssertEqual(client.httpStatus, "Offline")
        XCTAssertEqual(client.agentStatus, "Offline")
        XCTAssertEqual(client.chatStatus, "Offline")
        XCTAssertEqual(client.status, "Offline")
        XCTAssertEqual(client.detail, "Cannot reach kish-agent")
    }

    func testRefreshHealthMalformedPayloadMarksBridgeError() async {
        let client = makeClient { _ in
            jsonResponse(#"{ "notOk": true }"#)
        }

        await client.refreshHealth()

        XCTAssertEqual(client.miniStatus, "Online")
        XCTAssertEqual(client.httpStatus, "Error")
        XCTAssertEqual(client.agentStatus, "Offline")
        XCTAssertEqual(client.chatStatus, "Offline")
        XCTAssertEqual(client.status, "Error")
        XCTAssertEqual(client.detail, "Unexpected health response")
    }

    func testSendPostsThreadIdAndDecodesChatResult() async throws {
        var capturedBody: Data?
        let client = makeClient { request in
            XCTAssertEqual(request.url?.path, "/chat")
            XCTAssertEqual(request.httpMethod, "POST")
            capturedBody = requestBodyData(from: request)
            return jsonResponse(
                """
                {
                  "ok": true,
                  "threadId": "thread-1",
                  "engine": "claude",
                  "text": "hello back",
                  "elapsedMs": 42,
                  "events": ["done"]
                }
                """
            )
        }

        let result = try await client.send("hello", threadId: "thread-1")
        let body = try XCTUnwrap(capturedBody)
        let request = try JSONDecoder().decode(TestChatRequest.self, from: body)

        XCTAssertEqual(request.threadId, "thread-1")
        XCTAssertEqual(request.message, "hello")
        XCTAssertEqual(result.text, "hello back")
        XCTAssertEqual(result.engine, "claude")
        XCTAssertEqual(result.elapsedMs, 42)
        XCTAssertEqual(result.events, ["done"])
        XCTAssertEqual(client.chatStatus, "Ready")
    }

    func testSendAgentErrorKeepsBridgeOnlineAndMarksChatError() async {
        let client = makeClient { _ in
            jsonResponse(#"{ "ok": false, "error": "agent crashed" }"#, statusCode: 500)
        }

        do {
            _ = try await client.send("hello", threadId: "thread-1")
            XCTFail("Expected send to throw")
        } catch {
            XCTAssertEqual(error.localizedDescription, "agent crashed")
        }

        XCTAssertEqual(client.miniStatus, "Online")
        XCTAssertEqual(client.httpStatus, "Online")
        XCTAssertEqual(client.agentStatus, "Online")
        XCTAssertEqual(client.chatStatus, "Error")
        XCTAssertEqual(client.status, "Error")
        XCTAssertEqual(client.detail, "agent crashed")
    }

    private func makeClient(handler: @escaping (URLRequest) throws -> (HTTPURLResponse, Data)) -> KishAgentClient {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        let session = URLSession(configuration: configuration)
        MockURLProtocol.handler = handler
        return KishAgentClient(baseURL: URL(string: "http://kish-agent.test")!, session: session)
    }
}

private struct TestChatRequest: Decodable {
    let threadId: String
    let message: String
}

private func jsonResponse(_ json: String, statusCode: Int = 200) -> (HTTPURLResponse, Data) {
    (
        HTTPURLResponse(
            url: URL(string: "http://kish-agent.test")!,
            statusCode: statusCode,
            httpVersion: nil,
            headerFields: ["Content-Type": "application/json"]
        )!,
        Data(json.utf8)
    )
}

private func requestBodyData(from request: URLRequest) -> Data? {
    if let httpBody = request.httpBody {
        return httpBody
    }

    guard let stream = request.httpBodyStream else {
        return nil
    }

    stream.open()
    defer { stream.close() }

    var data = Data()
    let bufferSize = 1024
    let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: bufferSize)
    defer { buffer.deallocate() }

    while stream.hasBytesAvailable {
        let count = stream.read(buffer, maxLength: bufferSize)
        if count > 0 {
            data.append(buffer, count: count)
        } else {
            break
        }
    }

    return data
}

private final class MockURLProtocol: URLProtocol {
    static var handler: ((URLRequest) throws -> (HTTPURLResponse, Data))?

    override class func canInit(with request: URLRequest) -> Bool {
        true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        guard let handler = Self.handler else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }

        do {
            let (response, data) = try handler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}
