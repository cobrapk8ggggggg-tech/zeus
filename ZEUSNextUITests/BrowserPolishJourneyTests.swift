import XCTest

final class BrowserPolishJourneyTests: XCTestCase {
    func testTabGroupCreationCollapseAndExpandInICab() {
        let app = XCUIApplication(); app.launchArguments = ["--uitesting", "--layout=icab", "--tabs-polish-fixture"]; app.launch()
        let tabs = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'tab-' AND NOT identifier BEGINSWITH 'tab-group-'"))
        XCTAssertTrue(tabs.firstMatch.waitForExistence(timeout: 15))
        XCTAssertEqual(tabs.count, 3)
        tabs.element(boundBy: 0).press(forDuration: 1)
        let create = app.buttons["إنشاء مجلد"]; XCTAssertTrue(create.waitForExistence(timeout: 5)); create.tap()
        let name = app.textFields["tabGroupName"]; XCTAssertTrue(name.waitForExistence(timeout: 5)); name.tap(); name.typeText("روايات")
        app.buttons["createTabGroup"].tap()
        let group = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'tab-group-' ")).firstMatch
        XCTAssertTrue(group.waitForExistence(timeout: 5)); capture("icab-colored-group-expanded")
        group.tap(); XCTAssertEqual(tabs.count, 2); capture("icab-colored-group-collapsed")
        group.tap(); XCTAssertEqual(tabs.count, 3)
        tabs.element(boundBy: 0).press(forDuration: 0.6, thenDragTo: tabs.element(boundBy: 2))
        XCTAssertEqual(tabs.count, 3); capture("icab-tab-drag")
    }
    private func capture(_ name: String) { let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot()); attachment.name = name; attachment.lifetime = .keepAlways; add(attachment) }
}
