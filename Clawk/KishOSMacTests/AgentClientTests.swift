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

    func testToolInventoryCompactSummaryUsesRealCapabilityState() {
        let inventory = ToolInventory(
            commands: [
                ToolCapability(name: "/status", status: "Available", detail: nil),
                ToolCapability(name: "/deploy", status: "Needs setup", detail: "Missing token")
            ],
            engines: [
                ToolCapability(name: "claude", status: "Ready", detail: "opus")
            ],
            recentTools: [
                RecentToolCapability(name: "Read", count: 3, lastSeen: nil)
            ],
            updatedAt: nil
        )

        XCTAssertEqual(inventory.availableCommands.map(\.name), ["/status"])
        XCTAssertEqual(inventory.availableEngines.map(\.name), ["claude"])
        XCTAssertEqual(inventory.unavailableCapabilities.map(\.name), ["/deploy"])
        XCTAssertEqual(inventory.compactSummary, "1 tools · 1 engines · 1 recent · 1 unavailable")
        XCTAssertEqual(ToolInventory.empty.compactSummary, "Unavailable")
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
        XCTAssertNil(request.projectPath)
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

    func testStreamingHappyPathDecodesStatusToolApprovalAndFinal() async throws {
        var capturedBody: Data?
        var receivedEvents: [AgentStreamEvent] = []
        let conversationId = UUID(uuidString: "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee")!
        let client = makeClient { request in
            XCTAssertEqual(request.url?.path, "/chat-stream")
            XCTAssertEqual(request.httpMethod, "POST")
            capturedBody = requestBodyData(from: request)
            return ndjsonResponse(
                #"{"type":"status","status":"queued","threadId":"thread-1","engine":"claude"}"#,
                #"{"type":"activity","text":"reading files"}"#,
                #"{"type":"tool","tool":{"name":"Bash","input":{"cmd":"pwd"}}}"#,
                #"{"type":"approval","approval":{"id":"approval-1","threadId":"thread-1","questions":[{"header":"Direction","question":"Which path?","multiSelect":false,"options":[{"label":"Fast","description":"Prototype now"}]}],"createdAt":1760000000,"expiresAt":1760000300,"summary":"Choose direction"}}"#,
                #"{"type":"status","status":"waiting_approval","threadId":"thread-1","engine":"claude"}"#,
                #"{"type":"approval_result","approvalId":"approval-1","answer":"Fast","timedOut":false}"#,
                #"{"type":"text","text":"hello "}"#,
                #"{"type":"final","ok":true,"threadId":"thread-1","engine":"claude","text":"hello world","elapsedMs":42,"events":["reading files"],"approvals":[]}"#
            )
        }

        let result = try await client.sendStreaming("hello", threadId: "thread-1", conversationId: conversationId) { event in
            receivedEvents.append(event)
        }
        let body = try XCTUnwrap(capturedBody)
        let request = try JSONDecoder().decode(TestChatRequest.self, from: body)

        XCTAssertEqual(request.threadId, "thread-1")
        XCTAssertEqual(request.message, "hello")
        XCTAssertEqual(request.conversationId, conversationId)
        XCTAssertEqual(receivedEvents.map(\.type), ["status", "activity", "tool", "approval", "status", "approval_result", "text", "final"])
        XCTAssertEqual(receivedEvents.first(where: { $0.type == "tool" })?.tool?.name, "Bash")
        XCTAssertEqual(receivedEvents.first(where: { $0.type == "approval" })?.approval?.questions.first?.question, "Which path?")
        XCTAssertEqual(result.text, "hello world")
        XCTAssertEqual(result.engine, "claude")
        XCTAssertEqual(result.elapsedMs, 42)
        XCTAssertEqual(result.events, ["reading files"])
        XCTAssertEqual(client.status, "Ready")
        XCTAssertEqual(client.chatStatus, "Ready")
        XCTAssertFalse(client.isSending)
    }

    func testStreamingIncludesAttachmentIdsWhenPresent() async throws {
        var capturedBody: Data?
        let client = makeClient { request in
            XCTAssertEqual(request.url?.path, "/chat-stream")
            capturedBody = requestBodyData(from: request)
            return ndjsonResponse(
                #"{"type":"final","ok":true,"threadId":"thread-1","engine":"claude","text":"done","elapsedMs":4,"events":[]}"#
            )
        }

        _ = try await client.sendStreaming(
            "what is this?",
            threadId: "thread-1",
            attachments: [
                ChatRequestAttachment(id: "att_123", filename: "receipt.jpg", mimeType: "image/jpeg", kind: "image")
            ]
        ) { _ in }

        let body = try XCTUnwrap(capturedBody)
        let request = try JSONDecoder().decode(TestChatRequest.self, from: body)

        XCTAssertEqual(request.attachments?.count, 1)
        XCTAssertEqual(request.attachments?.first?.id, "att_123")
        XCTAssertEqual(request.attachments?.first?.filename, "receipt.jpg")
        XCTAssertEqual(request.attachments?.first?.mimeType, "image/jpeg")
        XCTAssertEqual(request.attachments?.first?.kind, "image")
    }

    func testStreamingIncludesProjectPathWhenPresent() async throws {
        var capturedBody: Data?
        let client = makeClient { request in
            XCTAssertEqual(request.url?.path, "/chat-stream")
            capturedBody = requestBodyData(from: request)
            return ndjsonResponse(
                #"{"type":"final","ok":true,"threadId":"thread-1","engine":"claude","text":"done","elapsedMs":4,"events":[]}"#
            )
        }

        _ = try await client.sendStreaming(
            "pwd",
            threadId: "thread-1",
            projectPath: "/Users/kishparikh/Code/clawk-ios"
        ) { _ in }

        let body = try XCTUnwrap(capturedBody)
        let request = try JSONDecoder().decode(TestChatRequest.self, from: body)

        XCTAssertEqual(request.projectPath, "/Users/kishparikh/Code/clawk-ios")
    }

    func testStreamingIncludesReferencesWhenPresent() async throws {
        var capturedBody: Data?
        let client = makeClient { request in
            XCTAssertEqual(request.url?.path, "/chat-stream")
            capturedBody = requestBodyData(from: request)
            return ndjsonResponse(
                #"{"type":"final","ok":true,"threadId":"thread-1","engine":"claude","text":"done","elapsedMs":4,"events":[]}"#
            )
        }

        _ = try await client.sendStreaming(
            "use this",
            threadId: "thread-1",
            references: [
                ChatRequestReference(path: "/Users/kishparikh/Code/kish-agent", title: "kish-agent", kind: "folder")
            ]
        ) { _ in }

        let body = try XCTUnwrap(capturedBody)
        let request = try JSONDecoder().decode(TestChatRequest.self, from: body)

        XCTAssertEqual(request.references?.count, 1)
        XCTAssertEqual(request.references?.first?.path, "/Users/kishparikh/Code/kish-agent")
        XCTAssertEqual(request.references?.first?.title, "kish-agent")
        XCTAssertEqual(request.references?.first?.kind, "folder")
    }

    func testFetchProjectsUsesProjectsEndpoint() async throws {
        let client = makeClient { request in
            XCTAssertEqual(request.url?.path, "/projects")
            XCTAssertEqual(request.url?.query, "all=1")
            return jsonResponse(
                """
                {
                  "ok": true,
                  "projects": [
                    {
                      "name": "clawk-ios",
                      "path": "/Users/kishparikh/Code/clawk-ios",
                      "relPath": "~/Code/clawk-ios",
                      "branch": "main",
                      "lastModified": "2026-06-04T05:20:00.000Z"
                    }
                  ]
                }
                """
            )
        }

        let projects = try await client.fetchProjects(all: true)

        XCTAssertEqual(projects.count, 1)
        XCTAssertEqual(projects[0].name, "clawk-ios")
        XCTAssertEqual(projects[0].path, "/Users/kishparikh/Code/clawk-ios")
        XCTAssertEqual(projects[0].relPath, "~/Code/clawk-ios")
        XCTAssertEqual(projects[0].branch, "main")
        XCTAssertNotNil(projects[0].lastModified)
    }

    func testCancelPostsThreadId() async throws {
        var capturedBody: Data?
        let client = makeClient { request in
            XCTAssertEqual(request.url?.path, "/cancel")
            XCTAssertEqual(request.httpMethod, "POST")
            capturedBody = requestBodyData(from: request)
            return jsonResponse(#"{"ok":true}"#)
        }

        try await client.cancel(threadId: "thread-1")

        let body = try XCTUnwrap(capturedBody)
        let request = try JSONDecoder().decode(TestCancelRequest.self, from: body)

        XCTAssertEqual(request.threadId, "thread-1")
        XCTAssertEqual(client.status, "Ready")
        XCTAssertEqual(client.chatStatus, "Ready")
        XCTAssertEqual(client.detail, "Stopped")
    }

    func testUploadAttachmentPostsMultipartAndDecodesResponse() async throws {
        var capturedRequest: URLRequest?
        var capturedBody: Data?
        let client = makeClient { request in
            capturedRequest = request
            capturedBody = requestBodyData(from: request)
            return jsonResponse(
                """
                {
                  "ok": true,
                  "attachment": {
                    "id": "att_123",
                    "filename": "receipt.jpg",
                    "mimeType": "image/jpeg",
                    "byteCount": 5,
                    "kind": "image"
                  }
                }
                """
            )
        }

        let payload = PendingAttachmentPayload(
            attachmentId: UUID(uuidString: "11111111-2222-3333-4444-555555555555")!,
            filename: "receipt.jpg",
            mimeType: "image/jpeg",
            data: Data("image".utf8)
        )

        let uploaded = try await client.uploadAttachment(payload, conversationId: UUID(uuidString: "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee")!, threadId: "thread-1")
        let request = try XCTUnwrap(capturedRequest)
        let body = String(data: try XCTUnwrap(capturedBody), encoding: .utf8)

        XCTAssertEqual(request.url?.path, "/attachments")
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertTrue(request.value(forHTTPHeaderField: "Content-Type")?.hasPrefix("multipart/form-data; boundary=") == true)
        XCTAssertTrue(body?.contains(#"name="filename""#) == true)
        XCTAssertTrue(body?.contains("receipt.jpg") == true)
        XCTAssertTrue(body?.contains(#"name="mimeType""#) == true)
        XCTAssertTrue(body?.contains("image/jpeg") == true)
        XCTAssertTrue(body?.contains(#"name="conversationId""#) == true)
        XCTAssertTrue(body?.contains("aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee") == true)
        XCTAssertTrue(body?.contains(#"name="threadId""#) == true)
        XCTAssertTrue(body?.contains("thread-1") == true)
        XCTAssertEqual(uploaded.id, "att_123")
        XCTAssertEqual(uploaded.filename, "receipt.jpg")
        XCTAssertEqual(uploaded.byteCount, 5)
    }

    func testStreamingMissingFinalThrowsRecoverableError() async {
        let client = makeClient { _ in
            ndjsonResponse(
                #"{"type":"status","status":"running","threadId":"thread-1","engine":"claude"}"#,
                #"{"type":"text","text":"partial"}"#
            )
        }

        do {
            _ = try await client.sendStreaming("hello", threadId: "thread-1") { _ in }
            XCTFail("Expected stream without final event to throw")
        } catch {
            XCTAssertEqual(error.localizedDescription, "Agent stream ended without a final response")
        }

        XCTAssertEqual(client.status, "Error")
        XCTAssertEqual(client.chatStatus, "Error")
        XCTAssertEqual(client.detail, "Agent stream ended without a final response")
        XCTAssertFalse(client.isSending)
    }

    func testStreamingCancelledFinalIsNeutral() async {
        let client = makeClient { _ in
            ndjsonResponse(
                #"{"type":"status","status":"running","threadId":"thread-1","engine":"claude"}"#,
                #"{"type":"final","ok":false,"cancelled":true,"threadId":"thread-1","engine":"claude","error":"Stopped.","elapsedMs":20,"events":["stopped"]}"#
            )
        }

        do {
            _ = try await client.sendStreaming("hello", threadId: "thread-1") { _ in }
            XCTFail("Expected cancelled stream to throw neutral cancellation")
        } catch {
            XCTAssertEqual(error.localizedDescription, "Stopped.")
        }

        XCTAssertEqual(client.status, "Ready")
        XCTAssertEqual(client.chatStatus, "Ready")
        XCTAssertEqual(client.detail, "Stopped")
        XCTAssertFalse(client.isSending)
    }

    func testStreamingMalformedLineMarksChatError() async {
        let client = makeClient { _ in
            ndjsonResponse(
                #"{"type":"status","status":"running","threadId":"thread-1","engine":"claude"}"#,
                #"not-json"#
            )
        }

        do {
            _ = try await client.sendStreaming("hello", threadId: "thread-1") { _ in }
            XCTFail("Expected malformed stream event to throw")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("data") || error.localizedDescription.contains("JSON"))
        }

        XCTAssertEqual(client.status, "Error")
        XCTAssertEqual(client.chatStatus, "Error")
        XCTAssertFalse(client.isSending)
    }

    func testStreamingNon200MarksChatRequestFailure() async {
        let client = makeClient { _ in
            jsonResponse(#"{ "ok": false, "error": "unauthorized" }"#, statusCode: 401)
        }

        do {
            _ = try await client.sendStreaming("hello", threadId: "thread-1") { _ in }
            XCTFail("Expected non-200 stream response to throw")
        } catch {
            XCTAssertEqual(error.localizedDescription, "Agent returned HTTP 401")
        }

        XCTAssertEqual(client.miniStatus, "Online")
        XCTAssertEqual(client.httpStatus, "Online")
        XCTAssertEqual(client.agentStatus, "Online")
        XCTAssertEqual(client.chatStatus, "Error")
        XCTAssertEqual(client.detail, "Agent returned HTTP 401")
    }

    func testAnswerApprovalPostsPayloadAndDecodesSuccess() async throws {
        var capturedBody: Data?
        let client = makeClient { request in
            XCTAssertEqual(request.url?.path, "/approve")
            XCTAssertEqual(request.httpMethod, "POST")
            capturedBody = requestBodyData(from: request)
            return jsonResponse(#"{ "ok": true }"#)
        }

        try await client.answerApproval("approval-1", approved: false, answer: "No")
        let body = try XCTUnwrap(capturedBody)
        let request = try JSONDecoder().decode(TestApprovalAnswerRequest.self, from: body)

        XCTAssertEqual(request.approvalId, "approval-1")
        XCTAssertFalse(request.approved)
        XCTAssertEqual(request.answer, "No")
    }

    func testAnswerApprovalFailureThrows() async {
        let client = makeClient { _ in
            jsonResponse(#"{ "ok": false, "error": "approval not found" }"#, statusCode: 404)
        }

        do {
            try await client.answerApproval("missing", approved: true, answer: "Yes")
            XCTFail("Expected approval failure to throw")
        } catch {
            XCTAssertEqual(error.localizedDescription, "approval not found")
        }
    }

    func testFetchConversationsDecodesSharedHistory() async throws {
        let client = makeClient { request in
            XCTAssertEqual(request.url?.path, "/conversations")
            return jsonResponse(
                """
                {
                  "ok": true,
                  "conversations": [
                    {
                      "id": "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee",
                      "threadId": "mac-aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee",
                      "title": "Hello",
                      "idea": "Hello",
                      "messages": [
                        {
                          "id": "11111111-2222-3333-4444-555555555555",
                          "sender": "user",
                          "text": "Hello",
                          "createdAt": "2026-06-04T05:20:00.000Z",
                          "deliveryState": "sent",
                          "activityEvents": []
                        },
                        {
                          "id": "66666666-7777-8888-9999-000000000000",
                          "sender": "agent",
                          "text": "Hi",
                          "createdAt": "2026-06-04T05:20:01.000Z",
                          "deliveryState": "sent",
                          "activityEvents": ["reply received"]
                        }
                      ],
                      "events": ["reply received"],
                      "engine": "claude",
                      "elapsedMs": 100,
                      "isRunning": false,
                      "updatedAt": "2026-06-04T05:20:01.000Z",
                      "lastError": null,
                      "approvals": []
                    }
                  ]
                }
                """
            )
        }

        let conversations = try await client.fetchConversations()

        XCTAssertEqual(conversations.count, 1)
        XCTAssertEqual(conversations[0].id.uuidString.lowercased(), "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee")
        XCTAssertEqual(conversations[0].threadId, "mac-aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee")
        XCTAssertEqual(conversations[0].messages.map(\.text), ["Hello", "Hi"])
        XCTAssertEqual(conversations[0].events, ["reply received"])
        XCTAssertEqual(conversations[0].elapsedMs, 100)
    }

    func testDeleteConversationUsesLowercasePathAndThrowsOnFailure() async {
        let id = UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!
        let client = makeClient { request in
            XCTAssertEqual(request.url?.path, "/conversations/aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee")
            XCTAssertEqual(request.httpMethod, "DELETE")
            return jsonResponse(#"{ "ok": false, "error": "conversation not found" }"#, statusCode: 404)
        }

        do {
            try await client.deleteConversation(id)
            XCTFail("Expected delete failure to throw")
        } catch {
            XCTAssertEqual(error.localizedDescription, "conversation not found")
        }
    }

    func testFetchToolInventoryRequestsToolsEndpoint() async throws {
        let client = makeClient { request in
            XCTAssertEqual(request.url?.path, "/tools")
            return jsonResponse(
                """
                {
                  "ok": true,
                  "commands": [{ "name": "/status", "status": "Available" }],
                  "engines": [{ "name": "codex", "status": "Available", "detail": "workspace-write" }],
                  "recentTools": [{ "name": "Read", "count": 2, "lastSeen": "2026-06-04T05:20:00.000Z" }],
                  "updatedAt": "2026-06-04T05:21:00.000Z"
                }
                """
            )
        }

        let inventory = try await client.fetchToolInventory()

        XCTAssertEqual(inventory.commands.first?.name, "/status")
        XCTAssertEqual(inventory.engines.first?.name, "codex")
        XCTAssertEqual(inventory.recentTools.first?.count, 2)
        XCTAssertNotNil(inventory.updatedAt)
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
    let conversationId: UUID?
    let attachments: [TestChatRequestAttachment]?
    let references: [TestChatRequestReference]?
    let projectPath: String?
}

private struct TestChatRequestAttachment: Decodable {
    let id: String
    let filename: String
    let mimeType: String?
    let kind: String?
}

private struct TestChatRequestReference: Decodable {
    let path: String
    let title: String
    let kind: String
}

private struct TestCancelRequest: Decodable {
    let threadId: String
}

private struct TestApprovalAnswerRequest: Decodable {
    let approvalId: String
    let approved: Bool
    let answer: String?
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

private func ndjsonResponse(_ lines: String..., statusCode: Int = 200) -> (HTTPURLResponse, Data) {
    (
        HTTPURLResponse(
            url: URL(string: "http://kish-agent.test")!,
            statusCode: statusCode,
            httpVersion: nil,
            headerFields: ["Content-Type": "application/x-ndjson"]
        )!,
        Data((lines.joined(separator: "\n") + "\n").utf8)
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
