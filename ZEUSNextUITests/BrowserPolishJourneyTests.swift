import XCTest

final class BrowserPolishJourneyTests: XCTestCase {
    func testTabGroupCreationCollapseAndExpandInICab() { tabJourney("icab") }
    func testTabGroupsInOriginalLayout() { tabJourney("original") }
    func testTabGroupsInDualBarsLayout() { tabJourney("dualBars") }
    private func tabJourney(_ layout: String) {
        let app = XCUIApplication(); app.launchArguments = ["--uitesting", "--layout=" + layout, "--tabs-polish-fixture"]; app.launch()
        XCTAssertTrue(app.textFields["homeSearchField"].waitForExistence(timeout: 15))
        if layout == "original" {
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.01)).press(forDuration: 0.1, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.25)))
        } else if layout == "dualBars" { app.buttons["tabsButton"].tap() }
        let tabs = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'tab-' AND NOT identifier BEGINSWITH 'tab-group-'"))
        XCTAssertTrue(tabs.firstMatch.waitForExistence(timeout: 15))
        XCTAssertEqual(tabs.count, 3)
        tabs.element(boundBy: 0).press(forDuration: 1)
        let create = app.buttons["إنشاء مجلد"]; XCTAssertTrue(create.waitForExistence(timeout: 5)); create.tap()
        let name = app.textFields["tabGroupName"]; XCTAssertTrue(name.waitForExistence(timeout: 5)); name.tap(); name.typeText("روايات")
        app.buttons["createTabGroup"].tap()
        let group = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'tab-group-' ")).firstMatch
        XCTAssertTrue(group.waitForExistence(timeout: 5)); capture(layout + "-colored-group-expanded")
        group.tap(); XCTAssertEqual(tabs.count, 2); capture(layout + "-colored-group-collapsed")
        group.tap(); XCTAssertEqual(tabs.count, 3)
        tabs.element(boundBy: 0).press(forDuration: 0.6, thenDragTo: tabs.element(boundBy: 2))
        XCTAssertEqual(tabs.count, 3); capture(layout + "-tab-drag")
    }
    func testReaderAppearancePanel() {
        let app = XCUIApplication(); app.launchArguments = ["--uitesting", "--reader-polish-fixture"]; app.launch()
        let settings = app.buttons["readerAppearanceButton"]; XCTAssertTrue(settings.waitForExistence(timeout: 15)); capture("reader-right-aligned")
        settings.tap()
        XCTAssertTrue(app.buttons["readerFontPicker"].waitForExistence(timeout: 5)); capture("reader-appearance-sheet")
        app.swipeUp()
        let black = app.buttons["أسود"]; XCTAssertTrue(black.waitForExistence(timeout: 5)); black.tap(); capture("reader-black-theme")
    }
    private func capture(_ name: String) { let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot()); attachment.name = name; attachment.lifetime = .keepAlways; add(attachment) }
}
