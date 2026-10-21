import XCTest

final class BrowserJourneyTests: XCTestCase {
    func testOriginalHomeGroupedMenusAndGrayTabs() throws {
        let app = launch()
        XCTAssertTrue(app.textFields["homeSearchField"].waitForExistence(timeout: 15)); capture("original-home")
        openToolbar(app); app.buttons["toolsButton"].tap()
        XCTAssertTrue(app.buttons["group-navigation"].waitForExistence(timeout: 5)); XCTAssertTrue(app.buttons["group-account"].exists); capture("grouped-tools")
        app.tapCoordinate(0.2, 0.6)
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.01)).press(forDuration: 0.1, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.4)))
        XCTAssertTrue(app.otherElements["originalTabsTray"].waitForExistence(timeout: 5))
        capture("original-gray-tab-tray")
    }
    func testDualBarsProfileWindowAndIndependentAvatarPickers() throws {
        let app = launch("dualBars")
        app.buttons["profilesButton"].tap()
        XCTAssertTrue(app.buttons["closeProfilePicker"].waitForExistence(timeout: 5)); capture("profile-picker-window")
        XCTAssertTrue(app.textFields["homeSearchField"].exists)
        app.buttons["closeProfilePicker"].tap()
        app.buttons["accountSettingsButton"].tap()
        let symbols = app.buttons["avatarSymbolsButton"]; XCTAssertTrue(symbols.waitForExistence(timeout: 8)); capture("account-settings-rtl")
        symbols.tap(); XCTAssertTrue(app.navigationBars["الصور الرمزية"].waitForExistence(timeout: 8)); capture("avatar-symbols")
        app.buttons["تم"].firstMatch.tap()
        app.buttons["avatarAlbumButton"].tap()
        XCTAssertTrue(app.otherElements["avatarAlbumPicker"].waitForExistence(timeout: 10)); XCTAssertFalse(app.navigationBars["الصور الرمزية"].exists); capture("device-album-picker")
        let photo = app.images.matching(NSPredicate(format: "label BEGINSWITH[c] 'Photo' OR label CONTAINS 'صورة'")).firstMatch
        XCTAssertTrue(photo.waitForExistence(timeout: 10)); photo.tap()
        let add = app.buttons.matching(NSPredicate(format: "label == 'Add' OR label == 'إضافة'")).firstMatch
        if add.waitForExistence(timeout: 2) { add.tap() }
        XCTAssertTrue(app.buttons["إزالة الصورة"].waitForExistence(timeout: 12))
        let dismissed = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: app.otherElements["avatarAlbumPicker"])
        wait(for: [dismissed], timeout: 8); capture("saved-device-photo-avatar")
    }
    func testThemesAndAllChromeLayouts() throws {
        let app = launch("dualBars")
        app.buttons["accountSettingsButton"].tap()
        openCategory("appearance", app)
        for layout in ["icab", "original", "dualBars"] { app.buttons["layout-" + layout].tap() }
        app.buttons["themeEditorButton"].tap()
        XCTAssertTrue(app.buttons["theme-ذهب ليلي"].waitForExistence(timeout: 8)); app.buttons["theme-ذهب ليلي"].tap(); capture("gold-glass-theme")
        app.swipeUp(); capture("custom-theme-controls")
    }
    func testOriginalReaderAndGalleryWithBackgroundAndLazyImages() throws {
        let app = launch()
        let search = app.textFields["homeSearchField"]; XCTAssertTrue(search.waitForExistence(timeout: 15)); search.tap(); search.typeText("http://127.0.0.1:8765/\n")
        XCTAssertTrue(app.webViews.firstMatch.waitForExistence(timeout: 10))
        XCTAssertTrue(app.webViews.staticTexts["ZEUS integration fixture"].waitForExistence(timeout: 30))
        openToolbar(app); app.buttons["readerButton"].tap()
        XCTAssertTrue(app.buttons["closeReaderButton"].waitForExistence(timeout: 10)); capture("reader-fullscreen"); app.buttons["closeReaderButton"].tap()
        openToolbar(app); app.buttons["galleryButton"].tap()
        XCTAssertTrue(app.staticTexts["galleryCount"].waitForExistence(timeout: 10)); XCTAssertTrue(app.staticTexts["galleryCount"].label.contains("3")); capture("gallery-original-grid")
    }
    private func openCategory(_ category: String, _ app: XCUIApplication) {
        let row = app.buttons["category-" + category]
        if !row.exists { let back = app.navigationBars.buttons.matching(identifier: "الإعدادات").firstMatch; if back.exists { back.tap() } else { app.navigationBars.buttons.element(boundBy: 0).tap() } }
        XCTAssertTrue(row.waitForExistence(timeout: 5)); row.tap()
    }
    private func launch(_ layout: String = "original") -> XCUIApplication { let app = XCUIApplication(); app.launchArguments = ["--uitesting", "--layout=" + layout]; app.launch(); return app }
    private func openToolbar(_ app: XCUIApplication) { let edge = app.otherElements["toolbarEdge"]; XCTAssertTrue(edge.waitForExistence(timeout: 10)); edge.tap() }
    private func capture(_ name: String) { let image = XCTAttachment(screenshot: XCUIScreen.main.screenshot()); image.name = name; image.lifetime = .keepAlways; add(image) }
}
private extension XCUIApplication {
    func tapCoordinate(_ x: CGFloat, _ y: CGFloat) { coordinate(withNormalizedOffset: CGVector(dx: x, dy: y)).tap() }
}
