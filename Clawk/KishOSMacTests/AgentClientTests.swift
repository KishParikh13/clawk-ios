import XCTest
@testable import KishOS

final class AgentClientTests: XCTestCase {
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
}
