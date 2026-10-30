import Combine
import XCTest
@testable import F50Manager

@MainActor
private final class MockSession: SessionServing {
    var devicePublisher: AnyPublisher<[NearbyDevice], Never> { Just([]).eraseToAnyPublisher() }
    var statusPublisher: AnyPublisher<String, Never> { Just("mock").eraseToAnyPublisher() }
    var scanPublisher: AnyPublisher<Bool, Never> { Just(false).eraseToAnyPublisher() }
    var connectedDeviceID: String? = "W3MJZCCR"
    var onDisconnect: ((String) -> Void)?
    var onEvent: ((String, JSONValue) -> Void)?
    var calls: [String] = []
    var commits = 0
    var rejectCommit = false
    var rejectAuthorization = false
    var connected = false

    func startScan() { calls.append("scan") }
    func stopScan() {}
    func disconnect() {
        guard connected else { return }
        connected = false
        onDisconnect?("mock disconnected")
    }
    func connect(id: UUID) async throws { connected = true }
    func request(method: String, params: [String: JSONValue], timeout: TimeInterval) async throws -> JSONValue {
        calls.append(method)
        switch method {
        case "sys.hello":
            return .object([
                "proto": .string("f50mgr/1"), "device_id": .string("W3MJZCCR"),
                "access": .object(["authorized": .bool(false)]),
                "caps": .object(["sms": .object(["list": .bool(true), "list_marks_read": .bool(false), "send": .bool(true), "delete": .bool(true)])])
            ])
        case "access.authorize":
            if rejectAuthorization { throw RPCError(code: -32002) }
            return .object(["scope": .string("connection"), "expires_in_s": .null])
        case "action.prepare":
            return .object(["action_id": .string(Data(repeating: 1, count: 16).base64EncodedString()),
                            "summary_zh": .string("原样服务端确认摘要"), "risk": .string("medium"), "expires_in_s": .number(60)])
        case "action.commit":
            commits += 1
            if rejectCommit { throw TransportError.timeout }
            return .object(["status": .string("submitted")])
        case "sms.list":
            return .object(["items": .array([.object(["id": .string("000001"), "peer": .string("synthetic"),
                                                      "body": .string("private fixture"), "box": .string("inbox"),
                                                      "status": .string("unread")])]), "next_cursor": .null])
        default: return .object([:])
        }
    }
}

final class AppModelTests: XCTestCase {
    @MainActor
    private func settle(_ model: AppModel) async throws {
        for _ in 0..<100 {
            if !model.isBusy { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("Operation failed to settle in one second")
    }
    @MainActor
    private func connect(_ model: AppModel) async throws {
        model.connect(NearbyDevice(id: UUID(), name: "fixture", rssi: -40))
        try await settle(model)
        XCTAssertTrue(model.isConnected)
    }

    @MainActor
    func testDemoNeverCallsLiveTransportOrMutations() async throws {
        let session = MockSession()
        let demo = AppModel(session: session)
        demo.enterDemo()
        demo.refreshDashboard()
        demo.loadMessages(box: "inbox")
        demo.prepareSend(to: "12345", body: "test")
        demo.prepareReboot()
        demo.commitPrepared()
        XCTAssertTrue(session.calls.isEmpty)
        XCTAssertFalse(demo.isConnected)
        XCTAssertTrue(demo.isDemo)
        XCTAssertNil(demo.preparedAction)
        demo.disconnect()
    }

    @MainActor
    func testCommitRequiresExplicitConfirmationAndNeverReplaysAfterFailure() async throws {
        let session = MockSession()
        let live = AppModel(session: session)
        try await connect(live)
        session.rejectCommit = true
        live.prepareSend(to: "12345", body: "test")
        try await settle(live)
        XCTAssertEqual(session.commits, 0)
        XCTAssertEqual(live.preparedAction?.summary, "原样服务端确认摘要")
        live.commitPrepared()
        try await settle(live)
        live.commitPrepared()
        try await settle(live)
        XCTAssertEqual(session.commits, 1)
        XCTAssertNil(live.preparedAction)
        XCTAssertTrue(live.errorMessage?.contains("不确定") == true)
        live.disconnect()
    }

    @MainActor
    func testAuthorizationLifetimeAndBackgroundPrivacy() async throws {
        let session = MockSession()
        let model = AppModel(session: session)
        try await connect(model)
        model.loadMessages(box: "inbox")
        try await settle(model)
        XCTAssertEqual(model.messages.count, 1)
        model.loadMessages(box: "inbox")
        try await settle(model)
        XCTAssertEqual(session.calls.filter { $0 == "access.authorize" }.count, 1)
        model.prepareSend(to: "12345", body: "test")
        try await settle(model)
        XCTAssertNotNil(model.preparedAction)
        model.setForeground(false)
        XCTAssertFalse(model.isConnected)
        XCTAssertTrue(model.messages.isEmpty)
        XCTAssertNil(model.preparedAction)
        model.setForeground(true)
        try await connect(model)
        model.loadMessages(box: "inbox")
        try await settle(model)
        XCTAssertEqual(session.calls.filter { $0 == "access.authorize" }.count, 2)
        XCTAssertEqual(session.commits, 0)
        model.disconnect()
    }

    @MainActor
    func testFailedAuthorizationDoesNotResumeProtectedIntent() async throws {
        let session = MockSession()
        let model = AppModel(session: session)
        session.rejectAuthorization = true
        try await connect(model)
        model.prepareSend(to: "12345", body: "test")
        try await settle(model)
        XCTAssertEqual(session.calls.filter { $0 == "access.authorize" }.count, 1)
        XCTAssertFalse(session.calls.contains("action.prepare"))
        XCTAssertNil(model.preparedAction)
        model.disconnect()
    }
}
