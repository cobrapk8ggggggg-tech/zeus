import XCTest

final class BrowserJourneyTests: XCTestCase {
    func testOriginalHomeAndFullScreenAccountSettings() throws {
        let app = launch()
        XCTAssertTrue(app.textFields["homeSearchField"].waitForExistence(timeout: 15)); capture("01-original-home")
        openToolbar(app); app.buttons["toolsButton"].tap(); app.buttons["profilesButton"].tap()
        XCTAssertTrue(app.buttons["addProfileButton"].waitForExistence(timeout: 5)); capture("02-fullscreen-accounts")
        app.buttons["addProfileButton"].tap()
        let name = app.textFields["profileNameField"]; XCTAssertTrue(name.waitForExistence(timeout: 5)); name.tap(); name.typeText("Work")
        app.buttons["createProfileButton"].tap()
        XCTAssertTrue(app.staticTexts["إعدادات الحساب"].waitForExistence(timeout: 8)); capture("03-account-settings")
    }
    func testAllChromeLayoutsKeepOriginalHomepage() throws {
        let app = launch()
        for layout in ["dualBars", "icab", "original"] {
            if app.otherElements["toolbarEdge"].exists { openToolbar(app) }
            app.buttons["toolsButton"].firstMatch.tap(); app.buttons["settingsButton"].tap()
            app.buttons["category-appearance"].tap()
            XCTAssertTrue(app.buttons["layout-" + layout].waitForExistence(timeout: 5)); app.buttons["layout-" + layout].tap()
            capture("settings-layout-" + layout)
            app.buttons["تم"].firstMatch.tap()
            XCTAssertTrue(app.textFields["homeSearchField"].waitForExistence(timeout: 8)); capture("chrome-" + layout)
        }
    }
    func testOriginalReaderAndGalleryWithBackgroundAndLazyImages() throws {
        let app = launch()
        let search = app.textFields["homeSearchField"]; XCTAssertTrue(search.waitForExistence(timeout: 15)); search.tap(); search.typeText("http://127.0.0.1:8765/\n")
        XCTAssertTrue(app.webViews.firstMatch.waitForExistence(timeout: 50))
        XCTAssertTrue(app.webViews.staticTexts["ZEUS integration fixture"].waitForExistence(timeout: 25))
        openToolbar(app); app.buttons["readerButton"].tap()
        XCTAssertTrue(app.buttons["closeReaderButton"].waitForExistence(timeout: 10)); capture("reader-fullscreen")
        app.buttons["closeReaderButton"].tap()
        openToolbar(app); app.buttons["galleryButton"].tap()
        XCTAssertTrue(app.staticTexts["galleryCount"].waitForExistence(timeout: 10)); XCTAssertTrue(app.staticTexts["galleryCount"].label.contains("3")); capture("gallery-original-grid")
        app.buttons["closeGalleryButton"].tap()
    }
    private func launch() -> XCUIApplication { let app = XCUIApplication(); app.launchArguments = ["--uitesting"]; app.launch(); return app }
    private func openToolbar(_ app: XCUIApplication) { let edge = app.otherElements["toolbarEdge"]; XCTAssertTrue(edge.waitForExistence(timeout: 10)); edge.tap() }
    private func capture(_ name: String) { let image = XCTAttachment(screenshot: XCUIScreen.main.screenshot()); image.name = name; image.lifetime = .keepAlways; add(image) }
}
