import XCTest

final class NativePersonalizationUITests: XCTestCase {
    override func tearDownWithError() throws {
        if let testRun, testRun.failureCount > 0 {
            let app = XCUIApplication()
            let screen = XCTAttachment(screenshot: app.screenshot()); screen.name = "Failure-System-UI"; screen.lifetime = .keepAlways; add(screen)
            let tree = XCTAttachment(string: app.debugDescription); tree.name = "Failure-Accessibility"; tree.lifetime = .keepAlways; add(tree)
        }
        try super.tearDownWithError()
    }
    @MainActor func test00CreateImportFixturesThroughSystemFilesExport() throws {
        let app = launchFiles()
        let prepare = app.buttons["prepareFiles"]
        expectation(for: NSPredicate(format: "enabled == true"), evaluatedWith: prepare)
        waitForExpectations(timeout: 10); prepare.tap()
        try browseLocalFixture(app)
        let save = app.buttons.matching(NSPredicate(format: "label IN %@", ["Export", "Save", "Copy", "Move", "تصدير", "حفظ", "نسخ", "نقل"])).firstMatch
        XCTAssertTrue(save.waitForExistence(timeout: 10)); XCTAssertTrue(save.isEnabled); save.tap()
        expectation(for: NSPredicate(format: "label == %@", "fixtures-ready"), evaluatedWith: app.staticTexts["fixtureStatus"])
        waitForExpectations(timeout: 20)
    }
    @MainActor func testFilesSingleSelectionAndCancellationThroughSystemUI() throws {
        let app = launchFiles()
        app.buttons["importSingle"].tap()
        try browseLocalFixture(app)
        file("ZEUS-Picker-A", app).tap()
        confirmOpen(app)
        expectation(for: NSPredicate(format: "label == %@", "1:readable:ZEUS-Picker-A.txt"), evaluatedWith: app.staticTexts["importResult"])
        waitForExpectations(timeout: 15)
        app.buttons["importSingle"].tap()
        let cancel = app.buttons.matching(NSPredicate(format: "label IN %@", ["Cancel", "إلغاء"])).firstMatch
        XCTAssertTrue(cancel.waitForExistence(timeout: 10)); cancel.tap()
        expectation(for: NSPredicate(format: "hittable == true"), evaluatedWith: app.buttons["importSingle"])
        waitForExpectations(timeout: 10)
    }
    @MainActor func testFilesMultipleSelectionThroughSystemOpenButton() throws {
        let app = launchFiles()
        app.buttons["importMultiple"].tap()
        try browseLocalFixture(app)
        file("ZEUS-Picker-A", app).tap(); file("ZEUS-Picker-B", app).tap()
        let screen = XCTAttachment(screenshot: app.screenshot()); screen.name = "Files-Multiple-Before-Open"; screen.lifetime = .keepAlways; add(screen)
        confirmOpen(app)
        let result = app.staticTexts["importResult"]
        let completed = NSPredicate(format: "label == %@", "2:readable:ZEUS-Picker-A.txt,ZEUS-Picker-B.txt")
        expectation(for: completed, evaluatedWith: result); waitForExpectations(timeout: 15)
    }
    @MainActor func testFolderSelectionThroughSystemOpenButton() throws {
        let app = launchFiles()
        app.buttons["importFolder"].tap()
        try browseLocalFixture(app)
        confirmOpen(app)
        let result = app.staticTexts["importResult"]
        expectation(for: NSPredicate(format: "label == %@", "1:readable:ZEUS-Import-Test"), evaluatedWith: result)
        waitForExpectations(timeout: 15)
    }
    @MainActor func testExternalFolderSettingsCancellationLeavesSettingsUsable() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--zeus-mounted-folders", "--zeus-native-fixture", "-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launch()
        let pick = app.buttons["mountExternalFolder"]
        XCTAssertTrue(pick.waitForExistence(timeout: 30)); pick.tap()
        let cancel = app.buttons.matching(NSPredicate(format: "label IN %@", ["Cancel", "إلغاء"])).firstMatch
        XCTAssertTrue(cancel.waitForExistence(timeout: 15)); cancel.tap()
        expectation(for: NSPredicate(format: "hittable == true"), evaluatedWith: pick)
        waitForExpectations(timeout: 15)
        pick.tap(); try browseLocalFixture(app); confirmOpen(app)
        XCTAssertTrue(app.buttons["confirmExternalMount"].waitForExistence(timeout: 15))
        XCTAssertTrue(cancel.waitForExistence(timeout: 10)); cancel.tap()
        expectation(for: NSPredicate(format: "hittable == true"), evaluatedWith: pick)
        waitForExpectations(timeout: 15)
    }
    @MainActor func testExternalFolderSettingsOpensConfirmationAndMountsSelectedFolder() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--zeus-mounted-folders", "--zeus-native-fixture", "-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launch()
        let pick = app.buttons["mountExternalFolder"]
        XCTAssertTrue(pick.waitForExistence(timeout: 30)); pick.tap()
        try browseLocalFixture(app)
        confirmOpen(app)
        let confirm = app.buttons["confirmExternalMount"]
        XCTAssertTrue(confirm.waitForExistence(timeout: 15), "Picking a folder must dismiss Files and open the real mount confirmation")
        let name = app.textFields["externalMountName"]
        XCTAssertTrue(name.exists)
        XCTAssertEqual(name.value as? String, "ZEUS-Import-Test")
        confirm.tap()
        XCTAssertTrue(pick.waitForExistence(timeout: 10))
        let mounted = app.staticTexts["ZEUS-Import-Test"].firstMatch
        XCTAssertTrue(mounted.waitForExistence(timeout: 15), "The selected folder must be listed after confirming the mount")
        let screen = XCTAttachment(screenshot: app.screenshot()); screen.name = "External-Folder-Mounted"; screen.lifetime = .keepAlways; add(screen)
    }
    @MainActor private func launchFiles() -> XCUIApplication {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--zeus-file-picker", "--zeus-native-fixture", "-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launch(); XCTAssertTrue(app.buttons["importSingle"].waitForExistence(timeout: 30)); return app
    }
    @MainActor private func file(_ name: String, _ app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any).matching(NSPredicate(format: "label BEGINSWITH %@", name)).firstMatch
    }
    @MainActor private func browseLocalFixture(_ app: XCUIApplication) throws {
        let local = app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS[c] %@ AND (label CONTAINS[c] %@ OR label CONTAINS %@)", "iPad", "On My", "على")).firstMatch
        for _ in 0..<3 where !local.exists || !local.isHittable {
            let browse = app.buttons.matching(NSPredicate(format: "label IN %@", ["Browse", "Show Sidebar", "Sidebar", "استعراض", "إظهار الشريط الجانبي"])).firstMatch
            if browse.waitForExistence(timeout: 5) { browse.tap() }
        }
        XCTAssertTrue(local.waitForExistence(timeout: 10)); local.tap()
        let zeus = app.descendants(matching: .any).matching(NSPredicate(format: "label == %@", "ZEUS")).firstMatch
        XCTAssertTrue(zeus.waitForExistence(timeout: 10)); zeus.tap()
        let fixture = file("ZEUS-Import-Test", app)
        XCTAssertTrue(fixture.waitForExistence(timeout: 10)); fixture.tap()
    }
    @MainActor private func confirmOpen(_ app: XCUIApplication) {
        let open = app.buttons.matching(NSPredicate(format: "label IN %@ OR label BEGINSWITH %@", ["Open", "Import", "Choose", "فتح", "استيراد", "اختيار"], "Open (")).firstMatch
        if open.waitForExistence(timeout: 3), open.isEnabled { open.tap() }
    }
    @MainActor func testPortraitIPadEditedPresetKeepsTabletButtonsAndSizesAfterRotation() throws {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        app.launchArguments = ["--uitesting", "--layout=icab", "--zeus-layout-editor", "--zeus-native-fixture", "-AppleLanguages", "(ar)", "-AppleLocale", "ar_SA"]
        app.launch()
        let save = app.buttons["saveChromeDesign"]; XCTAssertTrue(save.waitForExistence(timeout: 45))
        let share = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@ AND label == %@", "chromeStudioBlock-", "مشاركة")).firstMatch
        XCTAssertTrue(share.waitForExistence(timeout: 10))
        let start = share.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        start.press(forDuration: 0.08, thenDragTo: start.withOffset(CGVector(dx: 4, dy: 5)))
        save.tap()
        let assistant = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@ AND label == %@", "custom-", "وكيل ZEUS")).firstMatch
        XCTAssertTrue(assistant.waitForExistence(timeout: 15))
        XCTAssertEqual(assistant.frame.width, 44, accuracy: 1); XCTAssertEqual(assistant.frame.height, 44, accuracy: 1)
        let library = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@ AND label == %@", "custom-", "المواقع")).firstMatch
        XCTAssertTrue(library.exists, "Editing the iPad preset must retain its tablet-only actions")
        let portrait = XCTAttachment(screenshot: app.screenshot()); portrait.name = "Edited-iPad-Portrait"; portrait.lifetime = .keepAlways; add(portrait)
        XCUIDevice.shared.orientation = .landscapeLeft
        expectation(for: NSPredicate { _, _ in
            let window = app.windows.firstMatch.frame
            return window.width > window.height && assistant.frame.maxX > window.maxX - 100
        }, evaluatedWith: assistant)
        waitForExpectations(timeout: 15)
        XCTAssertEqual(assistant.frame.width, 44, accuracy: 1); XCTAssertEqual(assistant.frame.height, 44, accuracy: 1)
        XCTAssertTrue(library.exists)
        let landscape = XCTAttachment(screenshot: app.screenshot()); landscape.name = "Edited-iPad-Landscape"; landscape.lifetime = .keepAlways; add(landscape)
        XCUIDevice.shared.orientation = .portrait
    }
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
        XCTAssertEqual(moved.width, before.width, accuracy: 3, "Dragging the centre must move a button without resizing it")
        XCTAssertEqual(moved.height, before.height, accuracy: 3)
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
