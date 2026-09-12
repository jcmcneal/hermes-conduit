import XCTest
@testable import Conduit

@MainActor
final class MessagingServiceDecodingTests: XCTestCase {
    func testDecodingRunsOffMainThreadAndPreservesPayload() async throws {
        let service = MessagingService(requester: Requester())
        let result = try await service.request(DecodedProbe.self, "/probe")
        XCTAssertEqual(result.value, "hello")
        XCTAssertFalse(result.decodedOnMainThread)
    }

    func testMalformedPayloadStillThrowsDecodingError() async {
        let service = MessagingService(requester: Requester())
        do {
            _ = try await service.request(MessagingHistory.self, "/probe")
            XCTFail("Malformed history must not be admitted")
        } catch is DecodingError {
            // Typed decoding failures are preserved for the caller.
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testCancelledRequestDoesNotReturnDecodedValue() async {
        let service = MessagingService(requester: Requester())
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await service.request(DecodedProbe.self, "/probe")
        }
        do {
            _ = try await task.value
            XCTFail("Cancelled decoding should not publish a value")
        } catch is CancellationError {
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    private struct DecodedProbe: Decodable {
        let value: String
        let decodedOnMainThread: Bool
        enum CodingKeys: CodingKey { case value }
        init(from decoder: Decoder) throws {
            decodedOnMainThread = Thread.isMainThread
            value = try decoder.container(keyedBy: CodingKeys.self).decode(String.self, forKey: .value)
        }
    }

    private final class Requester: DashboardJSONRequester {
        func requestJSON(path: String, method: String, body: [String: Any]?, timeoutMilliseconds: Int,
                         maxResponseBytes: Int) async throws -> [String: Any] {
            XCTAssertTrue(Thread.isMainThread)
            return ["value": "hello"]
        }
    }
}
