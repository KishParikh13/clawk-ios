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

    func testConcurrentStreamingSendsKeepClientSendingUntilAllComplete() async throws {
        let lock = NSLock()
        var startedRequestCount = 0
        var firstStatusReceived = false
        var resumeFirstStatusEvent: CheckedContinuation<Void, Never>?

        func requestCount() -> Int {
            lock.lock()
            defer { lock.unlock() }
            return startedRequestCount
        }

        let client = makeClient { _ in
            lock.lock()
            startedRequestCount += 1
            let currentRequest = startedRequestCount
            lock.unlock()

            if currentRequest == 1 {
                return ndjsonResponse(
                    #"{"type":"status","status":"running","threadId":"thread-1","engine":"claude"}"#,
                    #"{"type":"final","ok":true,"threadId":"thread-1","engine":"claude","text":"done 1","elapsedMs":1,"events":[]}"#
                )
            }

            return ndjsonResponse(
                #"{"type":"final","ok":true,"threadId":"thread-2","engine":"claude","text":"done 2","elapsedMs":1,"events":[]}"#
            )
        }

        let firstSend = Task {
            try await client.sendStreaming("first", threadId: "thread-1") { event in
                if event.type == "status" {
                    firstStatusReceived = true
                    await withCheckedContinuation { continuation in
                        resumeFirstStatusEvent = continuation
                    }
                }
            }
        }
        while !firstStatusReceived {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertTrue(client.isSending)

        let secondSend = Task {
            try await client.sendStreaming("second", threadId: "thread-2") { _ in }
        }
        while requestCount() < 2 {
            try await Task.sleep(for: .milliseconds(10))
        }

        _ = try await secondSend.value
        XCTAssertTrue(client.isSending)

        resumeFirstStatusEvent?.resume()
        _ = try await firstSend.value
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

    func testFetchProjectBranchesUsesBranchesEndpoint() async throws {
        let client = makeClient { request in
            XCTAssertEqual(request.url?.path, "/projects/branches")
            XCTAssertEqual(request.url?.query, "path=/Users/kishparikh/Code/clawk-ios")
            return jsonResponse(
                """
                {
                  "ok": true,
                  "branches": [
                    { "name": "main", "isCurrent": true, "isRemote": false, "worktreePath": "/Users/kishparikh/Code/clawk-ios" },
                    { "name": "origin/feature", "isCurrent": false, "isRemote": true, "worktreePath": null }
                  ]
                }
                """
            )
        }

        let branches = try await client.fetchProjectBranches(projectPath: "/Users/kishparikh/Code/clawk-ios")

        XCTAssertEqual(branches.map(\.name), ["main", "origin/feature"])
        XCTAssertEqual(branches.first?.isCurrent, true)
        XCTAssertEqual(branches.first?.worktreePath, "/Users/kishparikh/Code/clawk-ios")
    }

    func testFetchProjectFilesUsesFilesEndpoint() async throws {
        let client = makeClient { request in
            XCTAssertEqual(request.url?.path, "/projects/files")
            XCTAssertEqual(
                request.url?.query,
                "path=/Users/kishparikh/Code/clawk-ios&limit=5000&exclude=node_modules,.git,build,dist,.next,.nuxt,.turbo,.cache,.parcel-cache,.svelte-kit,.vercel,coverage,out,target,vendor,Pods,DerivedData,.build,.gradle,.expo&branch=feature"
            )
            return jsonResponse(
                """
                {
                  "ok": true,
                  "files": [
                    {
                      "name": "App.swift",
                      "path": "/Users/kishparikh/Code/clawk-ios/Sources/App.swift",
                      "relPath": "Sources/App.swift",
                      "repoPath": "/Users/kishparikh/Code/clawk-ios",
                      "branch": "feature"
                    }
                  ],
                  "truncated": false
                }
                """
            )
        }

        let files = try await client.fetchProjectFiles(projectPath: "/Users/kishparikh/Code/clawk-ios", branch: "feature")

        XCTAssertEqual(files.count, 1)
        XCTAssertEqual(files[0].name, "App.swift")
        XCTAssertEqual(files[0].path, "/Users/kishparikh/Code/clawk-ios/Sources/App.swift")
        XCTAssertEqual(files[0].relPath, "Sources/App.swift")
        XCTAssertEqual(files[0].repoPath, "/Users/kishparikh/Code/clawk-ios")
        XCTAssertEqual(files[0].branch, "feature")
    }

    func testSwitchProjectBranchPostsBranchRequest() async throws {
        var capturedBody: Data?
        let client = makeClient { request in
            XCTAssertEqual(request.url?.path, "/projects/switch-branch")
            XCTAssertEqual(request.httpMethod, "POST")
            capturedBody = requestBodyData(from: request)
            return jsonResponse(
                """
                {
                  "ok": true,
                  "usedExistingWorktree": true,
                  "project": {
                    "name": "clawk-ios-feature",
                    "path": "/Users/kishparikh/conductor/workspaces/clawk-ios/feature",
                    "relPath": "~/conductor/workspaces/clawk-ios/feature",
                    "branch": "feature",
                    "lastModified": "2026-06-04T05:20:00.000Z"
                  }
                }
                """
            )
        }

        let result = try await client.switchProjectBranch(
            projectPath: "/Users/kishparikh/Code/clawk-ios",
            branch: "feature",
            dirtyAction: .stash
        )

        let body = try XCTUnwrap(capturedBody)
        let request = try JSONDecoder().decode(TestBranchSwitchRequest.self, from: body)
        XCTAssertEqual(request.projectPath, "/Users/kishparikh/Code/clawk-ios")
        XCTAssertEqual(request.branch, "feature")
        XCTAssertEqual(request.dirtyAction, "stash")
        XCTAssertEqual(result.project?.branch, "feature")
        XCTAssertEqual(result.usedExistingWorktree, true)
    }

    func testSwitchProjectBranchReturnsDirtyPromptResponse() async throws {
        let client = makeClient { request in
            XCTAssertEqual(request.url?.path, "/projects/switch-branch")
            return jsonResponse(
                """
                {
                  "ok": false,
                  "error": "dirty_worktree",
                  "requiresDirtyAction": true,
                  "dirtySummary": {
                    "isDirty": true,
                    "changedFiles": ["README.md", "Sources/App.swift"]
                  }
                }
                """,
                statusCode: 409
            )
        }

        let result = try await client.switchProjectBranch(projectPath: "/Users/kishparikh/Code/clawk-ios", branch: "feature")

        XCTAssertEqual(result.ok, false)
        XCTAssertEqual(result.requiresDirtyAction, true)
        XCTAssertEqual(result.dirtySummary?.changedFiles, ["README.md", "Sources/App.swift"])
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

    func testFetchAutonomySummaryDecodesNilBriefAndPolicyIssues() async throws {
        let client = makeClient { request in
            XCTAssertEqual(request.url?.path, "/autonomy/summary")
            return jsonResponse(
                """
                {
                  "ok": true,
                  "schemaVersion": 1,
                  "traceId": "trace_summary",
                  "data": {
                    "summary": {
                      "latestBrief": null,
                      "pendingReviewCount": 2,
                      "urgentReviewCount": 1,
                      "recentRuns": [],
                      "memoryCounts": {
                        "active": 12,
                        "pinned": 3,
                        "archived": 4,
                        "forgotten": 9,
                        "needsReview": 1,
                        "sensitive": 1,
                        "conflicted": 0
                      },
                      "routineCounts": {
                        "proposed": 1,
                        "enabled": 4,
                        "paused": 0,
                        "disabled": 0
                      },
                      "policyIssues": [
                        {
                          "id": "issue_1",
                          "policyId": "policy_1",
                          "routineId": "routine_1",
                          "severity": "warning",
                          "message": "Policy expansion needs durable approval.",
                          "reviewCardId": "review_1"
                        }
                      ],
                      "updatedAt": "2026-06-05T12:00:00Z"
                    }
                  }
                }
                """
            )
        }

        let summary = try await client.fetchAutonomySummary()

        XCTAssertNil(summary.latestBrief)
        XCTAssertEqual(summary.pendingReviewCount, 2)
        XCTAssertEqual(summary.urgentReviewCount, 1)
        XCTAssertEqual(summary.memoryCounts.active, 12)
        XCTAssertEqual(summary.routineCounts.enabled, 4)
        XCTAssertEqual(summary.policyIssues.first?.severity, .warning)
        XCTAssertEqual(summary.policyIssues.first?.message, "Policy expansion needs durable approval.")
    }

    func testFetchMemoryDecodesProvenanceFlagsAndOptionalDates() async throws {
        let client = makeClient { request in
            XCTAssertEqual(request.url?.path, "/memory")
            let components = try XCTUnwrap(URLComponents(url: try XCTUnwrap(request.url), resolvingAgainstBaseURL: false))
            XCTAssertEqual(components.queryItems?.first(where: { $0.name == "includeForgotten" })?.value, "true")
            return jsonResponse(
                """
                {
                  "ok": true,
                  "schemaVersion": 1,
                  "traceId": "trace_memory",
                  "data": {
                    "memory": [
                      {
                        "id": "mem_active",
                        "state": "pinned",
                        "text": "Kish prefers concise engineering updates.",
                        "summary": "Prefers concise updates.",
                        "reviewFlags": ["sensitive"],
                        "confidence": 0.96,
                        "provenance": [
                          {
                            "id": "prov_1",
                            "sourceType": "conversation",
                            "sourceId": "conv_1",
                            "threadId": "thread_1",
                            "routineRunId": null,
                            "quote": "Keep it concise.",
                            "observedAt": "2026-06-04T19:00:00Z",
                            "url": null
                          }
                        ],
                        "createdAt": "2026-06-04T19:00:00Z",
                        "updatedAt": "2026-06-05T15:00:00Z",
                        "lastUsedAt": "2026-06-05T15:00:00Z",
                        "forgottenAt": null,
                        "tombstoneReason": null
                      },
                      {
                        "id": "mem_forgotten",
                        "state": "forgotten",
                        "text": "Forgotten text.",
                        "summary": null,
                        "reviewFlags": ["needsReview", "conflicted"],
                        "confidence": 0.5,
                        "provenance": [
                          {
                            "id": "prov_2",
                            "sourceType": "manualEdit",
                            "sourceId": null,
                            "threadId": null,
                            "routineRunId": null,
                            "quote": null,
                            "observedAt": "2026-06-04T20:00:00Z",
                            "url": "kishos://memory/mem_forgotten"
                          }
                        ],
                        "createdAt": "2026-06-04T20:00:00Z",
                        "updatedAt": "2026-06-05T16:00:00Z",
                        "lastUsedAt": null,
                        "forgottenAt": "2026-06-05T16:00:00Z",
                        "tombstoneReason": "User requested forgetting."
                      }
                    ],
                    "nextCursor": null
                  }
                }
                """
            )
        }

        let memory = try await client.fetchMemory(includeForgotten: true)

        XCTAssertEqual(memory.count, 2)
        XCTAssertEqual(memory[0].state, .pinned)
        XCTAssertEqual(memory[0].reviewFlags, [.sensitive])
        XCTAssertEqual(memory[0].provenance.first?.sourceType, .conversation)
        XCTAssertNotNil(memory[0].lastUsedAt)
        XCTAssertNil(memory[0].forgottenAt)
        XCTAssertEqual(memory[1].state, .forgotten)
        XCTAssertEqual(memory[1].reviewFlags, [.needsReview, .conflicted])
        XCTAssertNil(memory[1].lastUsedAt)
        XCTAssertNotNil(memory[1].forgottenAt)
        XCTAssertEqual(memory[1].tombstoneReason, "User requested forgetting.")
    }

    func testPagedAutonomyListsFollowNextCursor() async throws {
        var seenRequests: [(path: String, cursor: String?)] = []
        let client = makeClient { request in
            let url = try XCTUnwrap(request.url)
            let components = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false))
            let cursor = components.queryItems?.first(where: { $0.name == "cursor" })?.value
            seenRequests.append((url.path, cursor))

            switch (url.path, cursor) {
            case ("/memory", nil):
                XCTAssertEqual(components.queryItems?.first(where: { $0.name == "includeForgotten" })?.value, "false")
                return jsonResponse(autonomyEnvelope(data: #"{ "memory": [\#(memoryJSON(id: "mem_page_1"))], "nextCursor": "memory_cursor" }"#))
            case ("/memory", "memory_cursor"):
                return jsonResponse(autonomyEnvelope(data: #"{ "memory": [\#(memoryJSON(id: "mem_page_2"))], "nextCursor": null }"#))
            case ("/routine-runs", nil):
                XCTAssertEqual(components.queryItems?.first(where: { $0.name == "routineId" })?.value, "routine_1")
                return jsonResponse(autonomyEnvelope(data: #"{ "runs": [\#(routineRunJSON(id: "run_page_1"))], "nextCursor": "run_cursor" }"#))
            case ("/routine-runs", "run_cursor"):
                XCTAssertEqual(components.queryItems?.first(where: { $0.name == "routineId" })?.value, "routine_1")
                return jsonResponse(autonomyEnvelope(data: #"{ "runs": [\#(routineRunJSON(id: "run_page_2"))], "nextCursor": null }"#))
            case ("/review-cards", nil):
                XCTAssertEqual(components.queryItems?.first(where: { $0.name == "state" })?.value, "open")
                return jsonResponse(autonomyEnvelope(data: #"{ "reviewCards": [\#(reviewCardJSON(id: "review_page_1"))], "nextCursor": "review_cursor" }"#))
            case ("/review-cards", "review_cursor"):
                XCTAssertEqual(components.queryItems?.first(where: { $0.name == "state" })?.value, "open")
                return jsonResponse(autonomyEnvelope(data: #"{ "reviewCards": [\#(reviewCardJSON(id: "review_page_2"))], "nextCursor": null }"#))
            default:
                XCTFail("Unexpected request \(url.absoluteString)")
                return jsonResponse(#"{ "ok": false, "error": "unexpected path" }"#, statusCode: 404)
            }
        }

        let memory = try await client.fetchMemory()
        let runs = try await client.fetchRoutineRuns(routineId: "routine_1")
        let reviewCards = try await client.fetchReviewCards()

        XCTAssertEqual(memory.map(\.id), ["mem_page_1", "mem_page_2"])
        XCTAssertEqual(runs.map(\.id), ["run_page_1", "run_page_2"])
        XCTAssertEqual(reviewCards.map(\.id), ["review_page_1", "review_page_2"])
        XCTAssertEqual(
            seenRequests.map { "\($0.path):\($0.cursor ?? "nil")" },
            [
                "/memory:nil",
                "/memory:memory_cursor",
                "/routine-runs:nil",
                "/routine-runs:run_cursor",
                "/review-cards:nil",
                "/review-cards:review_cursor"
            ]
        )
    }

    func testRunDailyBriefPostsRequestAndDecodesResult() async throws {
        var capturedBody: Data?
        let client = makeClient { request in
            XCTAssertEqual(request.url?.path, "/briefs/daily")
            XCTAssertEqual(request.httpMethod, "POST")
            capturedBody = requestBodyData(from: request)
            return jsonResponse(
                """
                {
                  "ok": true,
                  "schemaVersion": 1,
                  "traceId": "trace_daily",
                  "data": {
                    "brief": {
                      "id": "brief_1",
                      "routineRunId": "run_1",
                      "conversationId": "conv_1",
                      "threadId": "thread_1",
                      "previousBriefRunId": null,
                      "summary": "One item needs review.",
                      "sections": [
                        { "title": "Needs input", "items": ["Review one sensitive memory."] }
                      ],
                      "reviewCardIds": ["review_1"],
                      "createdAt": "2026-06-05T15:00:00Z"
                    },
                    "run": {
                      "id": "run_1",
                      "routineId": "routine_dailyBrief",
                      "idempotencyKey": "routine:routine_dailyBrief:manual:manual_1",
                      "status": "needsReview",
                      "conversationId": "conv_1",
                      "threadId": "thread_1",
                      "startedAt": "2026-06-05T14:59:00Z",
                      "finishedAt": "2026-06-05T15:00:00Z",
                      "priorRunIdsUsed": [],
                      "error": null,
                      "retryOfRunId": null,
                      "reviewCardIdsCreated": ["review_1"],
                      "createdAt": "2026-06-05T14:59:00Z",
                      "updatedAt": "2026-06-05T15:00:00Z"
                    },
                    "reviewCards": [
                      {
                        "id": "review_1",
                        "kind": "reviewSensitiveMemory",
                        "state": "open",
                        "title": "Review sensitive memory",
                        "body": "A routine found a possible sensitive memory.",
                        "routineId": "routine_dailyBrief",
                        "routineRunId": "run_1",
                        "memoryId": "mem_1",
                        "policyId": null,
                        "conversationId": "conv_1",
                        "threadId": "thread_1",
                        "reviewFlags": ["sensitive"],
                        "recommendedAction": "approve",
                        "notificationBehavior": "autonomyInbox",
                        "createdAt": "2026-06-05T15:00:00Z",
                        "updatedAt": "2026-06-05T15:00:00Z",
                        "resolvedAt": null
                      }
                    ],
                    "conversationId": "conv_1",
                    "threadId": "thread_1"
                  }
                }
                """
            )
        }

        let result = try await client.runDailyBrief(
            idempotencyKey: "routine:routine_dailyBrief:manual:manual_1",
            trigger: RoutineRunTrigger(type: .manual, manualRunId: "manual_1")
        )
        let body = try XCTUnwrap(capturedBody)
        let request = try JSONDecoder().decode(TestRoutineRunRequest.self, from: body)

        XCTAssertEqual(request.idempotencyKey, "routine:routine_dailyBrief:manual:manual_1")
        XCTAssertEqual(request.trigger.type, "manual")
        XCTAssertEqual(request.trigger.manualRunId, "manual_1")
        XCTAssertEqual(result.brief.id, "brief_1")
        XCTAssertEqual(result.run.status, .needsReview)
        XCTAssertEqual(result.reviewCards.first?.id, "review_1")
        XCTAssertEqual(result.conversationId, "conv_1")
        XCTAssertEqual(result.threadId, "thread_1")
    }

    func testRunRoutineDuplicateResponseDecodesDuplicateTrue() async throws {
        var capturedBody: Data?
        let client = makeClient { request in
            XCTAssertEqual(request.url?.path, "/routines/routine_1/run")
            XCTAssertEqual(request.httpMethod, "POST")
            capturedBody = requestBodyData(from: request)
            return jsonResponse(
                """
                {
                  "ok": true,
                  "schemaVersion": 1,
                  "traceId": "trace_duplicate",
                  "data": {
                    "run": {
                      "id": "run_1",
                      "routineId": "routine_1",
                      "idempotencyKey": "routine:routine_1:manual:manual_1",
                      "status": "done",
                      "conversationId": "conv_1",
                      "threadId": "thread_1",
                      "startedAt": "2026-06-05T15:10:00Z",
                      "finishedAt": "2026-06-05T15:11:00Z",
                      "priorRunIdsUsed": ["run_0"],
                      "error": null,
                      "retryOfRunId": null,
                      "reviewCardIdsCreated": [],
                      "createdAt": "2026-06-05T15:10:00Z",
                      "updatedAt": "2026-06-05T15:11:00Z"
                    },
                    "reviewCards": [],
                    "conversationId": "conv_1",
                    "threadId": "thread_1",
                    "duplicate": true
                  }
                }
                """
            )
        }

        let result = try await client.runRoutine(
            "routine_1",
            idempotencyKey: "routine:routine_1:manual:manual_1",
            trigger: RoutineRunTrigger(type: .manual, manualRunId: "manual_1")
        )
        let body = try XCTUnwrap(capturedBody)
        let request = try JSONDecoder().decode(TestRoutineRunRequest.self, from: body)

        XCTAssertEqual(request.trigger.manualRunId, "manual_1")
        XCTAssertEqual(result.run.id, "run_1")
        XCTAssertEqual(result.duplicate, true)
        XCTAssertEqual(result.conversationId, "conv_1")
        XCTAssertEqual(result.threadId, "thread_1")
    }

    func testUpdateReviewCardPatchesDecisionAndNoteAndDecodesRelatedObjects() async throws {
        var capturedBody: Data?
        let client = makeClient { request in
            XCTAssertEqual(request.url?.path, "/review-cards/review_1")
            XCTAssertEqual(request.httpMethod, "PATCH")
            capturedBody = requestBodyData(from: request)
            return jsonResponse(
                """
                {
                  "ok": true,
                  "schemaVersion": 1,
                  "traceId": "trace_review_update",
                  "data": {
                    "reviewCard": {
                      "id": "review_1",
                      "kind": "reviewSensitiveMemory",
                      "state": "approved",
                      "title": "Review sensitive memory",
                      "body": "Looks correct.",
                      "routineId": "routine_1",
                      "routineRunId": "run_1",
                      "memoryId": "mem_1",
                      "policyId": null,
                      "conversationId": "conv_1",
                      "threadId": "thread_1",
                      "reviewFlags": ["sensitive"],
                      "recommendedAction": "approve",
                      "notificationBehavior": "autonomyInbox",
                      "createdAt": "2026-06-05T15:00:00Z",
                      "updatedAt": "2026-06-05T15:05:00Z",
                      "resolvedAt": "2026-06-05T15:05:00Z"
                    },
                    "relatedMemory": {
                      "id": "mem_1",
                      "state": "active",
                      "text": "Kish prefers concise updates.",
                      "summary": "Prefers concise updates.",
                      "reviewFlags": [],
                      "confidence": 0.9,
                      "provenance": [],
                      "createdAt": "2026-06-04T19:00:00Z",
                      "updatedAt": "2026-06-05T15:05:00Z",
                      "lastUsedAt": null,
                      "forgottenAt": null,
                      "tombstoneReason": null
                    },
                    "relatedRoutine": null,
                    "relatedPolicy": {
                      "id": "policy_1",
                      "routineId": "routine_1",
                      "allowedActions": ["readContext", "summarize"],
                      "blockedActions": ["startCoding"],
                      "allowedContextSources": ["conversation", "memory"],
                      "allowedProjectPaths": [],
                      "maxRuntimeClass": "short",
                      "maxCostClass": "low",
                      "notificationBehavior": "dailyBriefDigest",
                      "createdAt": "2026-06-05T12:00:00Z",
                      "approvedAt": null,
                      "updatedAt": "2026-06-05T12:00:00Z"
                    }
                  }
                }
                """
            )
        }

        let result = try await client.updateReviewCard("review_1", decision: .approve, note: "Looks correct.")
        let body = try XCTUnwrap(capturedBody)
        let request = try JSONDecoder().decode(TestReviewCardUpdateRequest.self, from: body)
        let rawRequest = try JSONSerialization.jsonObject(with: body) as? [String: Any]

        XCTAssertEqual(request.decision, "approve")
        XCTAssertEqual(request.note, "Looks correct.")
        XCTAssertNil(request.state)
        XCTAssertTrue(rawRequest?.keys.contains("memoryPatch") == true)
        XCTAssertTrue(rawRequest?["memoryPatch"] is NSNull)
        XCTAssertTrue(rawRequest?.keys.contains("routinePatch") == true)
        XCTAssertTrue(rawRequest?["routinePatch"] is NSNull)
        XCTAssertEqual(result.reviewCard.state, .approved)
        XCTAssertEqual(result.relatedMemory?.id, "mem_1")
        XCTAssertNil(result.relatedRoutine)
        XCTAssertEqual(result.relatedPolicy?.id, "policy_1")
    }

    func testAutonomyErrorEnvelopeThrowsUsefulMessage() async {
        let client = makeClient { request in
            XCTAssertEqual(request.url?.path, "/policies")
            return jsonResponse(
                """
                {
                  "ok": false,
                  "schemaVersion": 1,
                  "traceId": "trace_error",
                  "error": {
                    "code": "forbidden_by_policy",
                    "message": "Policy does not allow this action.",
                    "details": { "actionClass": "startCoding" }
                  }
                }
                """,
                statusCode: 403
            )
        }

        do {
            _ = try await client.fetchPolicies()
            XCTFail("Expected autonomy envelope error to throw")
        } catch {
            XCTAssertEqual(error.localizedDescription, "Policy does not allow this action.")
        }
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

private struct TestBranchSwitchRequest: Decodable {
    let projectPath: String
    let branch: String
    let dirtyAction: String?
}

private struct TestRoutineRunRequest: Decodable {
    let idempotencyKey: String
    let trigger: TestRoutineRunTrigger
}

private struct TestRoutineRunTrigger: Decodable {
    let type: String
    let manualRunId: String?
    let scheduledFor: String?
    let eventName: String?
}

private struct TestReviewCardUpdateRequest: Decodable {
    let decision: String
    let note: String?
    let memoryPatch: JSONValue?
    let routinePatch: JSONValue?
    let state: String?
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

private func autonomyEnvelope(data: String) -> String {
    """
    {
      "ok": true,
      "schemaVersion": 1,
      "traceId": "trace_paged",
      "data": \(data)
    }
    """
}

private func memoryJSON(id: String) -> String {
    """
    {
      "id": "\(id)",
      "state": "active",
      "text": "Remember \(id).",
      "summary": null,
      "reviewFlags": [],
      "confidence": 0.8,
      "provenance": [],
      "createdAt": "2026-06-04T19:00:00Z",
      "updatedAt": "2026-06-05T15:00:00Z",
      "lastUsedAt": null,
      "forgottenAt": null,
      "tombstoneReason": null
    }
    """
}

private func routineRunJSON(id: String) -> String {
    """
    {
      "id": "\(id)",
      "routineId": "routine_1",
      "idempotencyKey": "routine:routine_1:manual:\(id)",
      "status": "done",
      "conversationId": "conv_1",
      "threadId": "thread_1",
      "startedAt": "2026-06-05T15:10:00Z",
      "finishedAt": "2026-06-05T15:11:00Z",
      "priorRunIdsUsed": [],
      "error": null,
      "retryOfRunId": null,
      "reviewCardIdsCreated": [],
      "createdAt": "2026-06-05T15:10:00Z",
      "updatedAt": "2026-06-05T15:11:00Z"
    }
    """
}

private func reviewCardJSON(id: String) -> String {
    """
    {
      "id": "\(id)",
      "kind": "reviewSensitiveMemory",
      "state": "open",
      "title": "Review \(id)",
      "body": "Needs review.",
      "routineId": "routine_1",
      "routineRunId": "run_1",
      "memoryId": "mem_1",
      "policyId": null,
      "conversationId": "conv_1",
      "threadId": "thread_1",
      "reviewFlags": ["sensitive"],
      "recommendedAction": "approve",
      "notificationBehavior": "autonomyInbox",
      "createdAt": "2026-06-05T15:00:00Z",
      "updatedAt": "2026-06-05T15:00:00Z",
      "resolvedAt": null
    }
    """
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
