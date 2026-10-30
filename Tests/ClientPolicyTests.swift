import XCTest
@testable import F50Manager

final class ClientPolicyTests: XCTestCase {
    func testSMSPhoneAndIDsStayASCIIStrings() throws {
        XCTAssertEqual(try SMSValidation.phone(" +123456 "), "+123456")
        for invalid in ["12", "１２３", "++123", "123-456", "../123", "123456789012345678901"] {
            XCTAssertThrowsError(try SMSValidation.phone(invalid))
        }
        XCTAssertTrue(SMSValidation.validID("000001"))
        XCTAssertTrue(SMSValidation.validID("1"))
        for invalid in ["000000", "0000001", "1/2", "-1", "１２３"] {
            XCTAssertFalse(SMSValidation.validID(invalid))
        }
    }

    func testSMSBoundaryAndUnicodeRules() throws {
        XCTAssertEqual(try SMSValidation.body(String(repeating: "a", count: 160)).count, 160)
        XCTAssertNoThrow(try SMSValidation.body(String(repeating: "^", count: 80)))
        XCTAssertThrowsError(try SMSValidation.body(String(repeating: "^", count: 81)))
        XCTAssertThrowsError(try SMSValidation.body(String(repeating: "a", count: 161)))
        XCTAssertNoThrow(try SMSValidation.body(String(repeating: "中", count: 70)))
        XCTAssertThrowsError(try SMSValidation.body(String(repeating: "中", count: 71)))
        for invalid in ["", "   ", "a\n", "emoji😀", "a\r", "a\u{0000}"] {
            XCTAssertThrowsError(try SMSValidation.body(invalid))
        }
        XCTAssertNoThrow(try SMSValidation.body("第一行\n第二行"))
    }

    func testConnectionScopedAuthorizationRequiresExplicitNull() {
        XCTAssertNoThrow(try ActionPolicy.requireAuthorization(.object(["scope": .string("connection"), "expires_in_s": .null])))
        for bad in [
            .object(["scope": .string("connection")]),
            .object(["scope": .string("connection"), "expires_in_s": .number(300)]),
            .object(["scope": .string("session"), "expires_in_s": .null]), .null
        ] as [JSONValue] {
            XCTAssertThrowsError(try ActionPolicy.requireAuthorization(bad))
        }
    }

    func testBandValidationDoesNotClearImplicitly() {
        XCTAssertNoThrow(try ActionPolicy.validateBands(kind: "nr_band", bands: [41, 78], supported: [1, 41, 78]))
        for bands in [[], [78, 78], [0], [1025], [79]] {
            XCTAssertThrowsError(try ActionPolicy.validateBands(kind: "nr_band", bands: bands, supported: [41, 78]))
        }
        XCTAssertThrowsError(try ActionPolicy.validateBands(kind: "lte_band", bands: [256], supported: nil))
    }

    func testUnknownReadbackNeverClaimsVerified() {
        XCTAssertTrue(ActionPolicy.outcome(kind: "net.set_lock", result: .object(["status": .string("applied_unverified")])).contains("未能确认"))
        XCTAssertTrue(ActionPolicy.outcome(kind: "net.clear_lock", result: .object(["status": .string("anything")])).contains("未知"))
        XCTAssertTrue(ActionPolicy.outcome(kind: "sms.send", result: .object(["status": .string("submitted")])).contains("不代表送达"))
        XCTAssertTrue(ActionPolicy.outcome(kind: "sms.send", result: .null).contains("不确定"))
        XCTAssertTrue(ActionPolicy.outcome(kind: "wifi.set_mode", result: .null).contains("不会自动确认"))
    }

    func testMissingValuesNeverBecomeZeroAndNRDoesNotImplyRAT() {
        let value: JSONValue = .object(["cellular": .object(["nr": .object(["ss_rsrp_dbm": .number(-88)])])])
        let dash = DashboardSnapshot(value, deviceID: "TEST")
        XCTAssertNil(dash.rat)
        XCTAssertNil(dash.rsrp)
        XCTAssertNil(dash.rxRate)
        XCTAssertNil(dash.memoryPercent)
        XCTAssertEqual(dash.cpu.count, 8)
        XCTAssertTrue(dash.cpu.allSatisfy { $0 == nil })
        XCTAssertEqual(dash.ageText(nil), "数据年龄未知")
    }

    func testDataSourceAddressesAndStaleAgesArePreserved() {
        let dash = DashboardSnapshot(DemoData.dashboard, deviceID: "DEMO")
        XCTAssertEqual(dash.hostIPv4, ["192.0.2.1"])
        XCTAssertEqual(dash.wanIPv4, ["198.51.100.8"])
        XCTAssertEqual(dash.eoipIPv4, ["203.0.113.10"])
        XCTAssertNotEqual(dash.hostIPv4, dash.wanIPv4)
        XCTAssertTrue(dash.ageText(15_001).contains("缓存"))
    }

    func testExplicitUnknownSourceAgeCannotBorrowFreshness() {
        let dash = DashboardSnapshot(.object(["freshness_ms": .object(["cellular_signal": .null, "cellular": .number(0), "device": .number(0)])]), deviceID: "TEST")
        XCTAssertNil(dash.signalAgeMS)
        XCTAssertNil(dash.cpuAgeMS)
        XCTAssertNil(dash.memoryAgeMS)
        XCTAssertNil(dash.addressAgeMS)
        XCTAssertEqual(dash.deviceAgeMS, 0)
    }

    func testPreparedActionExpiryIsSingleDeadline() {
        let action = PreparedAction(id: "test", kind: "sms.send", summary: "synthetic", risk: "medium", ttl: -1)
        XCTAssertTrue(action.isExpired)
    }

    func testSMSBodyIsNotTruncatedOrStrippedOnRead() {
        let message = SMSMessage(.object([
            "id": .string("000001"), "peer": .string("fixture"),
            "body": .string("完整正文\n"), "box": .string("inbox"),
            "status": .string("unread"), "ts": .null
        ]))
        XCTAssertEqual(message?.id, "000001")
        XCTAssertEqual(message?.body, "完整正文\n")
        XCTAssertNil(message?.date)
    }

    func testBooleanIsNotNumericAndJSONRoundtrip() throws {
        let parsed = try JSONDecoder().decode(JSONValue.self, from: Data(#"{"n":12,"b":true,"empty":null}"#.utf8))
        XCTAssertNil(parsed["b"].number)
        XCTAssertNil(parsed["n"].bool)
        XCTAssertEqual(parsed, try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(parsed)))
    }
}
