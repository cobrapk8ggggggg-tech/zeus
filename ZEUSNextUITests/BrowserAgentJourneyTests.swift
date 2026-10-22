import XCTest

final class BrowserAgentJourneyTests: XCTestCase {
    func testAgentApprovalAndSourceBasedChatInBothTopBarLayouts() {
        for layout in ["icab", "dualBars"] {
            let app = XCUIApplication(); app.launchArguments = ["--uitesting", "--layout=" + layout, "--agent-fixture"]; app.launch()
            let button = app.buttons["assistantButton"]; XCTAssertTrue(button.waitForExistence(timeout: 15)); button.tap()
            let consent = app.buttons["approveAgentContext"]; XCTAssertTrue(consent.waitForExistence(timeout: 10)); consent.tap()
            let composer = app.textViews["openMinisComposer"]; XCTAssertTrue(composer.waitForExistence(timeout: 10)); composer.tap(); composer.typeText("Open fixture")
            app.buttons["sendAgentMessage"].tap()
            let once = app.buttons["هذه المرة"]; XCTAssertTrue(once.waitForExistence(timeout: 25)); capture(layout + "-native-tool-approval")
            once.tap()
            XCTAssertTrue(app.textViews.matching(NSPredicate(format: "value CONTAINS 'Agent completed' OR label CONTAINS 'Agent completed'")).firstMatch.waitForExistence(timeout: 30))
            capture(layout + "-openminis-agent-result")
            app.terminate()
        }
    }
    private func capture(_ name: String) { let screenshot = XCTAttachment(screenshot: XCUIScreen.main.screenshot()); screenshot.name = name; screenshot.lifetime = .keepAlways; add(screenshot) }
}
