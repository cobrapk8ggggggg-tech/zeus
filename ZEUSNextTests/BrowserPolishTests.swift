import XCTest
import WebKit
@testable import ZEUSNext

@MainActor final class BrowserPolishTests: XCTestCase {
    func testGroupsReorderPersistAndDoNotChangeWebViewOrSelectedTab() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ProfileStore(root: root, downloadsRoot: root.appendingPathComponent("Downloads"))
        let model = BrowserModel(profiles: store, useBackgroundDownloads: false)
        let a = try XCTUnwrap(model.current), b = try XCTUnwrap(model.newTab()), c = try XCTUnwrap(model.newTab())
        let selected = model.selectedTabID
        let group = try XCTUnwrap(model.createGroup(name: "روايات", color: "64A8FF", tab: a))
        model.assign(c, to: group)
        XCTAssertEqual(model.tabs.map(\.id), [a.id,b.id,c.id], "Grouping preserves existing positions")
        model.toggleGroup(group)
        XCTAssertTrue(try XCTUnwrap(model.groups.first).collapsed)
        XCTAssertEqual(model.selectedTabID, selected, "Collapsing must not navigate or unload a page")
        model.moveTab(a.id, before: c.id)
        XCTAssertEqual(model.tabs.map(\.id), [b.id,c.id,a.id])
        let saved = store.load(store.active)
        XCTAssertEqual(saved.tabs.map(\.id), [b.id,c.id,a.id]); XCTAssertEqual(saved.tabGroups?.first?.name, "روايات")
        XCTAssertEqual(saved.tabs.last?.groupID, group)
        let other = store.add(name: "آخر", accent: "cyan", isPrivate: false)
        XCTAssertTrue(store.load(other).tabGroups?.isEmpty != false)
        model.removeGroup(group)
        XCTAssertTrue(model.tabs.allSatisfy { $0.groupID == nil }); XCTAssertEqual(model.tabs.count, 3)
    }
    func testManualICabHidingIgnoresScrollingAndOtherLayoutsStillReveal() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let model = BrowserModel(profiles: ProfileStore(root: root, downloadsRoot: root.appendingPathComponent("Downloads")), useBackgroundDownloads: false)
        let tab = try XCTUnwrap(model.current), driver = WebDriver(model: model, tab: tab)
        let scroll = DraggingScrollView(frame: CGRect(x: 0, y: 0, width: 400, height: 400)); scroll.contentSize = CGSize(width: 400, height: 2000)
        model.data.settings.chromeLayout = .icab; model.chromeHidden = true; model.chromeManuallyHidden = true
        scroll.contentOffset.y = 0; driver.scrollViewDidScroll(scroll); XCTAssertTrue(model.chromeHidden)
        scroll.contentOffset.y = 500; driver.scrollViewDidScroll(scroll); XCTAssertTrue(model.chromeHidden)
        model.chromeManuallyHidden = false; scroll.contentOffset.y = 0; driver.scrollViewDidScroll(scroll); XCTAssertFalse(model.chromeHidden)
        model.data.settings.chromeLayout = .dualBars; model.chromeHidden = true; model.chromeManuallyHidden = true
        driver.scrollViewDidScroll(scroll); XCTAssertFalse(model.chromeHidden)
    }
    func testNewPreferencesDecodeOlderProfileAndRoundTrip() throws {
        let old = Data(#"{"fontSize":20,"textOpacity":1,"blockedWords":[],"imageScale":1,"scrollDistance":300}"#.utf8)
        var reader = try JSONDecoder().decode(ReadingPreferences.self, from: old)
        XCTAssertNil(reader.backgroundHex); reader.fontName = "GeezaPro"; reader.backgroundHex = "000000"; reader.textOpacity = 0.6
        let copy = try JSONDecoder().decode(ReadingPreferences.self, from: JSONEncoder().encode(reader))
        XCTAssertEqual(copy.fontName, "GeezaPro"); XCTAssertEqual(copy.textOpacity, 0.6)
        var prefs = TranslationPreferences(); XCTAssertEqual(prefs.suggestionSeconds, 1.5)
        prefs.suggestionDuration = 0; XCTAssertEqual(prefs.suggestionSeconds, 0)
        prefs.suggestionDuration = 999; XCTAssertEqual(prefs.suggestionSeconds, 30)
    }
    func testForcedDarkCoversNestedDynamicAndShadowContentWithoutInvertingMedia() async throws {
        let view = WKWebView()
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene); let controller = UIViewController(); window.rootViewController = controller; window.frame = scene.screen.bounds; view.frame = window.bounds; controller.view.addSubview(view); window.makeKeyAndVisible()
        defer { window.isHidden = true }
        let loaded = DarkNavigation(); view.navigationDelegate = loaded
        view.loadHTMLString("<html><body><main style='background:white!important;color:black!important'><p id='text'>A bright article</p><div id='gradient' style='background:linear-gradient(white,yellow)'>Gradient</div><img id='photo'><div id='host'></div></main></body></html>", baseURL: nil)
        let deadline = Date().addingTimeInterval(20)
        while !loaded.done && Date() < deadline { try await Task.sleep(for: .milliseconds(100)) }
        XCTAssertTrue(loaded.done); XCTAssertFalse(BrowserTools.darkPage.isEmpty)
        _ = try await view.evaluateJavaScript(BrowserTools.darkPage)
        _ = try await view.evaluateJavaScript("document.querySelector('#host').attachShadow({mode:'open'}).innerHTML='<p style=\"background:white;color:black\">Shadow</p>'; const dynamic=document.createElement('section');dynamic.id='dynamic';dynamic.style.background='white';document.body.append(dynamic)")
        try await Task.sleep(for: .milliseconds(300))
        let values = try await view.evaluateJavaScript("[getComputedStyle(document.querySelector('main')).backgroundColor,getComputedStyle(document.querySelector('#text')).color,getComputedStyle(document.querySelector('#dynamic')).backgroundColor,getComputedStyle(document.querySelector('#host').shadowRoot.querySelector('p')).backgroundColor,getComputedStyle(document.querySelector('#photo')).filter,getComputedStyle(document.querySelector('#gradient')).backgroundImage]") as? [String]
        XCTAssertEqual(values, ["rgb(16, 17, 20)","rgb(229, 231, 235)","rgb(16, 17, 20)","rgb(16, 17, 20)","none","none"])
    }
}
@MainActor private final class DarkNavigation: NSObject, WKNavigationDelegate {
    var done = false
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { done = true }
}

@MainActor private final class DraggingScrollView: UIScrollView { override var isDragging: Bool { true } }
