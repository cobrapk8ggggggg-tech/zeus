import XCTest

final class BrowserJourneyTests: XCTestCase {
    func testHomeProfilesDownloadsAndSettings() throws {
        let app = XCUIApplication(); app.launchArguments = ["--uitesting"]; app.launch()
        XCTAssertTrue(app.buttons["profilesButton"].waitForExistence(timeout: 15))
        capture("01-home")
        app.buttons["profilesButton"].tap()
        XCTAssertTrue(app.buttons["addProfileButton"].waitForExistence(timeout: 5)); capture("02-profiles")
        app.buttons["addProfileButton"].tap()
        let name = app.textFields["profileNameField"]; XCTAssertTrue(name.waitForExistence(timeout: 5)); name.tap(); name.typeText("Work")
        app.buttons["createProfileButton"].tap()
        XCTAssertTrue(app.buttons["downloadsButton"].waitForExistence(timeout: 8))
        app.buttons["downloadsButton"].tap(); capture("03-downloads"); app.buttons["تم"].firstMatch.tap()
        app.buttons["settingsButton"].tap()
        app.swipeUp()
        XCTAssertTrue(app.buttons["clearCacheButton"].waitForExistence(timeout: 8)); capture("04-settings")
    }
    private func capture(_ name: String) { let image = XCTAttachment(screenshot: XCUIScreen.main.screenshot()); image.name = name; image.lifetime = .keepAlways; add(image) }
}
