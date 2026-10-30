import XCTest
import CryptoKit
@testable import F50Manager

final class TransportTests: XCTestCase {
    private let sample = Data(#"{"jsonrpc":"2.0","id":1,"method":"sys.hello","params":{}}"#.utf8)
    private func hex(_ data: Data) -> String { data.map { String(format: "%02x", $0) }.joined() }

    func testCanonicalWireVectorsAndMinimumMTU() throws {
        let frame = try WireCodec.frame(sample)
        XCTAssertEqual(hex(frame), "000000397b226a736f6e727063223a22322e30222c226964223a312c226d6574686f64223a227379732e68656c6c6f222c22706172616d73223a7b7d7d")
        XCTAssertEqual(hex(WireCodec.open), "0201")
        XCTAssertEqual(try WireCodec.chunks(frame, valueLimit: 20).map(hex), [
            "01000000397b226a736f6e727063223a22322e30", "01222c226964223a312c226d6574686f64223a22",
            "017379732e68656c6c6f222c22706172616d7322", "013a7b7d7d"
        ])
        XCTAssertNil(try WireCodec.payload(WireCodec.open, awaitingOpen: true, valueLimit: 20))
    }
    func testBundledCanonicalProtocolFixture() throws {
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "protocol-vectors", withExtension: "json", subdirectory: "Fixtures"))
        let vector = try JSONDecoder().decode(JSONValue.self, from: Data(contentsOf: url))
        let json = try XCTUnwrap(vector["app_frame"]["json"].string)
        let frame = try WireCodec.frame(Data(json.utf8))
        XCTAssertEqual(hex(frame), vector["app_frame"]["frame_hex"].string)
        XCTAssertEqual(hex(WireCodec.open), vector["gatt"]["open_hex"].string)
        XCTAssertEqual(try WireCodec.chunks(frame, valueLimit: 20).map(hex), vector["gatt"]["data_chunks_att_mtu_23_for_app_frame_hex"].strings)
    }

    func testEveryFragmentBoundaryAndCoalescedFrames() throws {
        let framed = try WireCodec.frame(sample)
        for cut in 0...framed.count {
            var decoder = FrameDecoder()
            let first = try decoder.feed(Data(framed.prefix(cut)))
            let second = try decoder.feed(Data(framed.dropFirst(cut)))
            XCTAssertEqual(first + second, [sample])
        }
        var decoder = FrameDecoder(), output: [Data] = []
        for byte in framed { output += try decoder.feed(Data([byte])) }
        XCTAssertEqual(output, [sample])
        XCTAssertEqual(try decoder.feed(framed + framed), [sample, sample])
    }
    func testLengthBoundsAndPoisonedDecoder() throws {
        XCTAssertThrowsError(try WireCodec.frame(Data()))
        XCTAssertThrowsError(try WireCodec.frame(Data(repeating: 1, count: 65_537)))
        let maximum = Data(repeating: 65, count: 65_536)
        var decoder = FrameDecoder()
        XCTAssertEqual(try decoder.feed(WireCodec.frame(maximum)), [maximum])
        for header in [Data([0,0,0,0]), Data([0,1,0,1]), Data([255,255,255,255])] {
            var bad = FrameDecoder()
            XCTAssertThrowsError(try bad.feed(header))
            XCTAssertThrowsError(try bad.feed(WireCodec.frame(sample)))
        }
        var badUTF8 = FrameDecoder()
        XCTAssertThrowsError(try badUTF8.feed(Data([0,0,0,1,255])))
        var flooded = FrameDecoder()
        XCTAssertThrowsError(try flooded.feed(Data(repeating: 0, count: 131_073)))
    }
    func testUnexpectedOpcodeAndOversizeFailClosed() throws {
        for frame in [Data([1, 0]), Data([2, 2]), Data([4, 1]), Data([2, 1, 0])] {
            XCTAssertThrowsError(try WireCodec.payload(frame, awaitingOpen: true, valueLimit: 20))
        }
        for frame in [Data(), Data([1]), Data([2, 1]), Data([4, 1]), Data(repeating: 1, count: 513)] {
            XCTAssertThrowsError(try WireCodec.payload(frame, awaitingOpen: false, valueLimit: 512))
        }
        XCTAssertThrowsError(try WireCodec.payload(Data([3, 5]), awaitingOpen: false, valueLimit: 20)) { error in
            XCTAssertEqual(error as? TransportError, .remote(5))
        }
        let chunks = try WireCodec.chunks(Data(repeating: 3, count: 65_540), valueLimit: 512)
        XCTAssertTrue(chunks.allSatisfy { $0.count <= 512 && $0.first == 1 })
        let negotiated = try WireCodec.chunks(Data(repeating: 3, count: 363), valueLimit: 182)
        XCTAssertEqual(negotiated.map(\.count), [182, 182, 2])
        XCTAssertThrowsError(try WireCodec.chunks(sample, valueLimit: 513))
        XCTAssertThrowsError(try WireCodec.chunks(Data(repeating: 0, count: 131_073), valueLimit: 20))
    }
    func testPinMustBeProvisionedAndMatchWholeLeafDigest() throws {
        XCTAssertEqual(try ProvisionedDevices.pin(for: "W3MJZCCR").count, 32)
        XCTAssertThrowsError(try ProvisionedDevices.pin(for: "5PVKQJAS"))
        let der: [UInt8] = [1,2,3,4]
        let pin = Array(SHA256.hash(data: Data(der)))
        XCTAssertTrue(ProvisionedDevices.verify(der: der, pin: pin))
        for i in 0..<32 {
            var wrong = pin; wrong[i] ^= 1
            XCTAssertFalse(ProvisionedDevices.verify(der: der, pin: wrong))
        }
        XCTAssertFalse(ProvisionedDevices.verify(der: der, pin: Array(pin.prefix(31))))
    }
    func testMonotonicDeadlineDoesNotSlideOnPartialInput() {
        let deadline = TransportDeadline(now: 10, timeout: 30)
        XCTAssertFalse(deadline.expired(at: 39.999))
        XCTAssertTrue(deadline.expired(at: 40))
        XCTAssertTrue(deadline.expired(at: 200))
    }
    func testRPCMatchingEventsAndPrivateErrorSanitization() throws {
        let result = Data(#"{"jsonrpc":"2.0","id":2,"result":{"ok":true}}"#.utf8)
        if case .result(let value) = try RPCMessage.decode(result, pendingID: 2) { XCTAssertEqual(value["ok"].bool, true) }
        else { XCTFail("Expected result") }
        XCTAssertThrowsError(try RPCMessage.decode(result, pendingID: 1))
        XCTAssertThrowsError(try RPCMessage.decode(result, pendingID: nil))
        let event = Data(#"{"jsonrpc":"2.0","method":"event.sms","params":{"new_count":1}}"#.utf8)
        if case .event(let name, _) = try RPCMessage.decode(event, pendingID: 2) { XCTAssertEqual(name, "event.sms") }
        else { XCTFail("Expected event") }
        let error = Data(#"{"jsonrpc":"2.0","id":2,"error":{"code":-32031,"message":"PRIVATE SMS BODY","data":{"private":"123456789"}}}"#.utf8)
        if case .failure(let failure) = try RPCMessage.decode(error, pendingID: 2) {
            XCTAssertEqual(failure.code, -32031)
            XCTAssertFalse(failure.localizedDescription.contains("PRIVATE"))
            XCTAssertFalse(failure.localizedDescription.contains("123456789"))
        } else { XCTFail("Expected sanitized error") }
        for invalid in [#"[]"#, #"{"jsonrpc":"2.0","id":true,"result":{}}"#,
                        #"{"jsonrpc":"2.0","id":2,"result":{},"error":{}}"#,
                        #"{"jsonrpc":"2.0","id":2.5,"result":{}}"#,
                        #"{"jsonrpc":"2.0","id":2,"result":null}"#,
                        #"{"jsonrpc":"2.0","method":"sys.hello","params":{}}"#] {
            XCTAssertThrowsError(try RPCMessage.decode(Data(invalid.utf8), pendingID: 2))
        }
    }
    @MainActor func testNewSessionIsNotSecureAndCannotRPCOffline() async {
        let session = F50Session() // must not start CoreBluetooth or ask permission
        XCTAssertFalse(session.isConnected)
        XCTAssertNil(session.connectedDeviceID)
        do { _ = try await session.request(method: "action.commit"); XCTFail("Must reject offline RPC") }
        catch { XCTAssertEqual(error as? TransportError, .disconnected) }
        session.disconnect()
        XCTAssertFalse(session.isConnected)
    }
}
