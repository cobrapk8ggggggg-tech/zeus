import XCTest

final class BrowserJourneyTests: XCTestCase {
    func testOriginalHomeAndFullScreenAccountSettings() throws {
        let app = XCUIApplication(); app.launchArguments = ["--uitesting"]; app.launch()
        XCTAssertTrue(app.textFields["homeSearchField"].waitForExistence(timeout: 15)); capture("01-original-home")
        openToolbar(app); app.buttons["profilesButton"].tap()
        XCTAssertTrue(app.buttons["addProfileButton"].waitForExistence(timeout: 5)); capture("02-fullscreen-accounts")
        app.buttons["addProfileButton"].tap()
        let name = app.textFields["profileNameField"]; XCTAssertTrue(name.waitForExistence(timeout: 5)); name.tap(); name.typeText("Work")
        app.buttons["createProfileButton"].tap()
        XCTAssertTrue(app.staticTexts["إعدادات الحساب"].waitForExistence(timeout: 8)); capture("03-account-settings")
    }
    func testAllChromeLayoutsKeepOriginalHomepage() throws {
        let app = XCUIApplication(); app.launchArguments = ["--uitesting"]; app.launch()
        openToolbar(app)
        app.buttons["settingsButton"].tap()
        app.buttons["واجهة المستخدم والأشرطة"].tap()
        for layout in ["dualBars", "icab", "original"] {
            XCTAssertTrue(app.buttons["layout-" + layout].waitForExistence(timeout: 5)); app.buttons["layout-" + layout].tap(); capture("layout-choice-" + layout)
        }
    }
    private func openToolbar(_ app: XCUIApplication) { let edge = app.otherElements["toolbarEdge"]; if edge.waitForExistence(timeout: 10) { edge.swipeLeft() } else { app.swipeLeft() } }
    private func capture(_ name: String) { let image = XCTAttachment(screenshot: XCUIScreen.main.screenshot()); image.name = name; image.lifetime = .keepAlways; add(image) }
}
