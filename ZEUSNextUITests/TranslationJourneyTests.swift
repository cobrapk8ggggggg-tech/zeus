import XCTest

final class TranslationJourneyTests: XCTestCase {
    func testSuggestionRealDOMTranslationRestoreAndAskAgainOnNextPage() {
        let app = launch()
        let search = app.textFields["homeSearchField"]; XCTAssertTrue(search.waitForExistence(timeout: 15)); search.tap(); search.typeText("http://127.0.0.1:8765/translate-fixture\n")
        let translate = app.buttons["confirmTranslationButton"]; XCTAssertTrue(translate.waitForExistence(timeout: 20)); capture("translation-suggestion")
        translate.tap()
        let original = app.buttons["restoreTranslationButton"]; XCTAssertTrue(original.waitForExistence(timeout: 30)); capture("translated-page-arabic-rtl")
        original.tap(); XCTAssertTrue(app.webViews.staticTexts["A journey beyond the mountains"].waitForExistence(timeout: 10))
        let next = app.webViews.links["Next page"]; next.tap(); XCTAssertTrue(translate.waitForExistence(timeout: 15)); capture("translation-asks-on-next-page")
    }
    func testAutomaticTranslationAndProviderDiscoverySettings() {
        let app = launch(automatic: true)
        let search = app.textFields["homeSearchField"]; XCTAssertTrue(search.waitForExistence(timeout: 15)); search.tap(); search.typeText("http://127.0.0.1:8765/translate-fixture\n")
        XCTAssertTrue(app.buttons["restoreTranslationButton"].waitForExistence(timeout: 30)); XCTAssertFalse(app.buttons["confirmTranslationButton"].exists); capture("automatic-page-translation")
        app.buttons["خيارات الترجمة"].tap(); app.buttons["إعدادات الترجمة"].tap()
        XCTAssertTrue(app.switches["automaticPageTranslation"].waitForExistence(timeout: 10)); capture("translation-settings-rtl")
        let manage = app.buttons["إدارة مزودي الذكاء الاصطناعي"]
        if !manage.isHittable { app.swipeUp() }; manage.tap()
        app.buttons["addAIProvider"].tap()
        let url = app.textFields["Base URL مثل https://api.openai.com/v1"]; XCTAssertTrue(url.waitForExistence(timeout: 10)); url.clearAndEnter("http://127.0.0.1:8765/v1")
        app.buttons["discoverAIProvider"].tap()
        XCTAssertTrue(app.buttons["اختبار توليد رد حقيقي"].waitForExistence(timeout: 15)); capture("ai-provider-discovered-models")
    }
    func testCloudflareSettingsRequirePrivateConnectionAndDoNotExposeAnAccountKey() {
        let app = launch(automatic: true)
        let search = app.textFields["homeSearchField"]; XCTAssertTrue(search.waitForExistence(timeout: 15)); search.tap(); search.typeText("http://127.0.0.1:8765/translate-fixture\n")
        XCTAssertTrue(app.buttons["restoreTranslationButton"].waitForExistence(timeout: 45))
        app.buttons["خيارات الترجمة"].tap(); app.buttons["إعدادات الترجمة"].tap()
        let engine = app.buttons["translationEngine"]; XCTAssertTrue(engine.waitForExistence(timeout: 10)); engine.tap()
        app.buttons["Cloudflare Workers AI"].tap()
        let settings = app.buttons["cloudflareTranslationSettings"]; XCTAssertTrue(settings.waitForExistence(timeout: 10)); settings.tap()
        XCTAssertTrue(app.buttons["importCloudflareConnection"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.secureTextFields["cloudflareConnectionKey"].exists)
        XCTAssertFalse(app.buttons["testCloudflareConnection"].isEnabled)
        capture("cloudflare-private-profile-connection-rtl")
    }
    private func launch(automatic: Bool = false) -> XCUIApplication {
        let app = XCUIApplication(); app.launchArguments = ["--uitesting", "--layout=dualBars", "--translation-fixture"]
        if automatic { app.launchArguments.append("--automatic-translation") }; app.launch(); return app
    }
    private func capture(_ name: String) { let image = XCTAttachment(screenshot: XCUIScreen.main.screenshot()); image.name = name; image.lifetime = .keepAlways; add(image) }
}
private extension XCUIElement {
    func clearAndEnter(_ text: String) {
        tap()
        // The first tap can put the caret in the middle of a long URL. Moving to
        // its trailing edge before deleting avoids leaving an invisible suffix.
        coordinate(withNormalizedOffset: CGVector(dx: 0.97, dy: 0.5)).tap()
        let current = value as? String ?? ""
        typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: current.count + 10) + text + "\n")
        XCTAssertEqual(value as? String, text)
    }
}
