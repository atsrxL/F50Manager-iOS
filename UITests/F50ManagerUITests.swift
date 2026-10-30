import XCTest

final class F50ManagerUITests: XCTestCase {
    func testDemoNavigationWithoutBluetoothOrDeviceActions() {
        let app = XCUIApplication()
        app.launch()
        let demo = app.buttons["先看看演示"]
        XCTAssertTrue(demo.waitForExistence(timeout: 10))
        for _ in 0..<3 where !demo.isHittable { app.swipeUp() }
        demo.tap()
        XCTAssertTrue(app.staticTexts["ZTE F50"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["演示数据 · 不连接真实设备"].exists)
        XCTAssertLessThanOrEqual(app.buttons["退出"].frame.maxY, app.buttons["刷新概览"].frame.minY + 2)
        capture(app, name: "demo-dashboard")
        app.buttons["短信"].firstMatch.tap()
        let read = app.buttons["读取收件箱"]
        XCTAssertTrue(read.waitForExistence(timeout: 5))
        read.tap()
        XCTAssertTrue(app.staticTexts["演示通知"].waitForExistence(timeout: 5))
        capture(app, name: "demo-messages")
        XCTAssertFalse(app.buttons["撰写短信"].isEnabled)
        app.buttons["设备"].firstMatch.tap()
        XCTAssertTrue(app.buttons["退出演示，连接设备"].waitForExistence(timeout: 5))
        capture(app, name: "demo-device")
        app.buttons["退出演示，连接设备"].tap()
        XCTAssertTrue(app.buttons["查找附近设备"].waitForExistence(timeout: 5))
        app.terminate()
    }

    func testLargeTextLandingKeepsExplicitDemoChoice() {
        let app = XCUIApplication()
        app.launchArguments = ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"]
        app.launch()
        let demo = app.buttons["先看看演示"]
        XCTAssertTrue(demo.waitForExistence(timeout: 10))
        for _ in 0..<5 where !demo.isHittable { app.swipeUp() }
        XCTAssertTrue(demo.isHittable)
        capture(app, name: "accessibility-large-text")
        app.terminate()
    }

    private func capture(_ app: XCUIApplication, name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
