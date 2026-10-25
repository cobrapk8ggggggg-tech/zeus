import XCTest

final class NativePersonalizationUITests: XCTestCase {
    @MainActor func testIPadLayoutDragResizeAndSave() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--uitesting", "--layout=icab", "--zeus-layout-editor", "--zeus-native-fixture", "-AppleLanguages", "(ar)", "-AppleLocale", "ar_SA"]
        app.launch()
        let save = app.buttons["saveChromeDesign"]
        XCTAssertTrue(save.waitForExistence(timeout: 45))
        let palette = app.buttons["chromePalette-action:translate"]
        XCTAssertTrue(palette.waitForExistence(timeout: 10))
        if !palette.isHittable { app.scrollViews.allElementsBoundByIndex.last?.swipeLeft() }
        palette.tap()
        let predicate = NSPredicate(format: "identifier BEGINSWITH %@ AND label == %@", "chromeStudioBlock-", "ترجمة الصفحة")
        let block = app.buttons.matching(predicate).firstMatch
        XCTAssertTrue(block.waitForExistence(timeout: 10))
        let before = block.frame
        let canvas = app.otherElements["chromeStudioCanvas"]
        XCTAssertTrue(canvas.exists)
        let destination = canvas.coordinate(withNormalizedOffset: CGVector(dx: 0.55, dy: 0.58))
        block.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).press(forDuration: 0.08, thenDragTo: destination)
        let moved = block.frame
        XCTAssertGreaterThan(abs(moved.midX - before.midX) + abs(moved.midY - before.midY), 35)
        let handle = block.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: moved.width - 14, dy: moved.height - 14))
        handle.press(forDuration: 0.08, thenDragTo: handle.withOffset(CGVector(dx: 80, dy: 35)))
        let resized = block.frame
        XCTAssertGreaterThan(resized.width, moved.width + 20)
        XCTAssertGreaterThan(resized.height, moved.height + 10)
        let editor = XCTAttachment(screenshot: app.screenshot()); editor.name = "IPad-Layout-Drag-Resize"; editor.lifetime = .keepAlways; add(editor)
        save.tap()
        let installed = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@ AND label == %@", "custom-", "ترجمة الصفحة")).firstMatch
        XCTAssertTrue(installed.waitForExistence(timeout: 10), "Saved designs must render through the real browser actions")
        let runtime = XCTAttachment(screenshot: app.screenshot()); runtime.name = "IPad-Custom-Layout-Applied"; runtime.lifetime = .keepAlways; add(runtime)
    }
}
