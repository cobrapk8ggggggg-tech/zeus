import XCTest
import UIKit

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
            if UIDevice.current.userInterfaceIdiom == .pad {
                let page = app.webViews.firstMatch
                XCTAssertTrue(page.waitForExistence(timeout: 10))
                XCTAssertGreaterThan(page.frame.width, app.frame.width * 0.5)
                XCTAssertLessThan(page.frame.width, app.frame.width * 0.85, "The agent must reduce the actual WebKit width")
                app.buttons["خيارات المساعد"].tap(); app.buttons["ملء الشاشة"].tap()
                capture(layout + "-agent-fullscreen")
                app.buttons["خيارات المساعد"].tap(); app.buttons["تصغير"].tap()
                let split = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in page.frame.width < app.frame.width * 0.85 }, object: nil)
                XCTAssertEqual(XCTWaiter.wait(for: [split], timeout: 8), .completed)
            }
            app.terminate()
        }
    }
    private func capture(_ name: String) { let screenshot = XCTAttachment(screenshot: XCUIScreen.main.screenshot()); screenshot.name = name; screenshot.lifetime = .keepAlways; add(screenshot) }
}
