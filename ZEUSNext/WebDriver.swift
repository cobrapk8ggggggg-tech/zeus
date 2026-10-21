import WebKit
import UIKit

@MainActor final class WebDriver: NSObject, WKNavigationDelegate, WKUIDelegate, WKScriptMessageHandler, UIScrollViewDelegate {
    weak var model: BrowserModel?
    weak var tab: BrowserTab?
    var observations: [NSKeyValueObservation] = []
    private var scrollAnchor: CGFloat = 0
    func scrollViewWillBeginDragging(_ scrollView: UIScrollView) { scrollAnchor = scrollView.contentOffset.y }
    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        guard scrollView.isDragging || scrollView.isDecelerating, let model, model.data.settings.advanced?.hideChromeOnScroll != false, tab?.id == model.current?.id else { return }
        let y = scrollView.contentOffset.y
        guard y >= -scrollView.adjustedContentInset.top, y <= max(0, scrollView.contentSize.height - scrollView.bounds.height) else { return }
        let delta = y - scrollAnchor
        if y < 20 { model.chromeHidden = false; scrollAnchor = y }
        else if abs(delta) > 18 { model.chromeHidden = delta > 0; scrollAnchor = y }
    }
    init(model: BrowserModel, tab: BrowserTab) { self.model = model; self.tab = tab }
    func observe(_ view: WKWebView) {
        observations.append(view.observe(\.estimatedProgress, options: [.new]) { [weak self] view, _ in
            Task { @MainActor in self?.tab?.progress = view.estimatedProgress; self?.model?.changed() }
        })
        observations.append(view.observe(\.isLoading, options: [.new]) { [weak self] view, _ in
            Task { @MainActor in self?.tab?.loading = view.isLoading; self?.model?.changed() }
        })
        observations.append(view.observe(\.canGoBack, options: [.new]) { [weak self] _, _ in Task { @MainActor in self?.model?.changed() } })
        observations.append(view.observe(\.canGoForward, options: [.new]) { [weak self] _, _ in Task { @MainActor in self?.model?.changed() } })
    }
    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        guard let model, let tab, model.profile.id == tab.profileID, let url = navigationAction.request.url else { decisionHandler(.cancel); return }
        let scheme = url.scheme?.lowercased() ?? ""
        if ["mailto", "tel", "sms"].contains(scheme) {
            if model.profile.role == .kiosk { decisionHandler(.cancel); return }
            model.dialog = WebDialog(kind: .confirm, text: "فتح الرابط في تطبيق الجهاز؟") { result in if result != nil { UIApplication.shared.open(url) } }
            decisionHandler(.cancel); return
        }
        guard ["http", "https", "about", "blob", "data"].contains(scheme) else { decisionHandler(.cancel); model.notify("تعذر فتح مخطط الرابط داخل المتصفح."); return }
        if scheme == "http", model.data.settings.advanced?.upgradeHTTPS == true, var components = URLComponents(url: url, resolvingAgainstBaseURL: false) { components.scheme = "https"; if let secure = components.url { var request = navigationAction.request; request.url = secure; decisionHandler(.cancel); webView.load(request); return } }
        let host = url.host ?? ""
        if BrowserURL.isWeb(url), !model.permits(url) { decisionHandler(.cancel); return }
        if navigationAction.shouldPerformDownload, model.profile.account?.allowDownloads == false { decisionHandler(.cancel); model.notify("التنزيلات غير مسموحة لهذا الحساب."); return }
        if model.data.settings.shieldsEnabled && !model.siteCompatible && model.shield.blocks(host) {
            model.blockedNavigations += 1; model.changed(); decisionHandler(.cancel); return
        }
        if navigationAction.shouldPerformDownload { decisionHandler(.download); return }
        if navigationAction.targetFrame == nil && navigationAction.navigationType != .linkActivated && navigationAction.navigationType != .formSubmitted && !model.siteCompatible && !model.data.settings.popupExceptions.contains(where: { BrowserURL.hostMatches(webView.url?.host ?? "", domain: $0) }) {
            model.pendingPopup = navigationAction.request; model.blockedNavigations += 1
            decisionHandler(.cancel); return
        }
        decisionHandler(.allow)
    }
    func webView(_ webView: WKWebView, decidePolicyFor navigationResponse: WKNavigationResponse, decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void) {
        let response = navigationResponse.response as? HTTPURLResponse
        let disposition = response?.value(forHTTPHeaderField: "Content-Disposition")?.lowercased() ?? ""
        if !navigationResponse.canShowMIMEType || disposition.hasPrefix("attachment") { decisionHandler(model?.profile.account?.allowDownloads == false ? .cancel : .download) }
        else { decisionHandler(.allow) }
    }
    func webView(_ webView: WKWebView, navigationAction: WKNavigationAction, didBecome download: WKDownload) { attach(download) }
    func webView(_ webView: WKWebView, navigationResponse: WKNavigationResponse, didBecome download: WKDownload) { attach(download) }
    private func attach(_ download: WKDownload) {
        guard let model, let tab, let owner = model.profiles.profile(tab.profileID) else { download.cancel { _ in }; return }
        model.downloads.attach(download, profile: owner); tab.loading = false; model.changed(); model.notify("أُضيف الملف إلى التنزيلات.")
    }
    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) { tab?.translation?.navigationStarted(); tab?.error = nil; tab?.loading = true; model?.changed() }
    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        tab?.committed = true
        if let url = webView.url { tab?.url = url.absoluteString; if model?.current?.id == tab?.id { model?.address = url.absoluteString } }
        model?.changed()
    }
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        guard let model, let tab else { return }
        tab.url = webView.url?.absoluteString ?? tab.url; tab.title = webView.title.flatMap { $0.isEmpty ? nil : $0 } ?? BrowserURL.displayHost(tab.url)
        tab.loading = false; tab.error = nil
        if model.current?.id == tab.id { model.address = tab.url }
        model.addVisit(tab: tab); model.persist(); model.changed()
    }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { fail(error) }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { fail(error) }
    private func fail(_ error: Error) {
        let ns = error as NSError
        if ns.code == NSURLErrorCancelled || (ns.domain == "WebKitErrorDomain" && ns.code == 102) { tab?.loading = false; model?.changed(); return }
        tab?.error = error.localizedDescription; tab?.loading = false; model?.changed()
    }
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        tab?.loading = false; tab?.error = "أوقف النظام الصفحة لتوفير الذاكرة. يمكنك إعادة تحميلها."; model?.changed()
    }
    func webView(_ webView: WKWebView, didReceive challenge: URLAuthenticationChallenge, completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) { completionHandler(.performDefaultHandling, nil) }
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration, for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        guard let model, navigationAction.targetFrame == nil, model.tabs.count < 30 else { return nil }
        let saved = SavedTab(title: "صفحة جديدة", url: navigationAction.request.url?.absoluteString ?? "about:blank")
        let tab = BrowserTab(saved: saved, profileID: model.profile.id)
        // WebKit supplies the opener's configuration and data store. Keep that
        // exact configuration so target=_blank/OAuth windows keep their opener.
        let view = WKWebView(frame: .zero, configuration: configuration)
        let driver = WebDriver(model: model, tab: tab)
        view.scrollView.delegate = driver
        view.navigationDelegate = driver; view.uiDelegate = driver; view.allowsBackForwardNavigationGestures = true; view.isFindInteractionEnabled = true
        tab.webView = view; tab.driver = driver; driver.observe(view)
        let translation = PageTranslation(model: model, tab: tab); tab.translation = translation; translation.attach(to: view, installScript: false)
        model.tabs.append(tab); model.selectedTabID = tab.id; model.persist()
        return view
    }
    func webViewDidClose(_ webView: WKWebView) { if let tab { model?.closeTab(tab) } }
    func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String, initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping () -> Void) {
        guard let model else { completionHandler(); return }
        if model.dialog != nil { completionHandler(); return }
        model.dialog = WebDialog(kind: .alert, text: String(message.prefix(3000))) { _ in completionHandler() }
    }
    func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String, initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping (Bool) -> Void) {
        guard let model, model.dialog == nil else { completionHandler(false); return }
        model.dialog = WebDialog(kind: .confirm, text: String(message.prefix(3000))) { completionHandler($0 != nil) }
    }
    func webView(_ webView: WKWebView, runJavaScriptTextInputPanelWithPrompt prompt: String, defaultText: String?, initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping (String?) -> Void) {
        guard let model, model.dialog == nil else { completionHandler(nil); return }
        model.dialog = WebDialog(kind: .prompt, text: String(prompt.prefix(3000)), initial: defaultText ?? "", complete: completionHandler)
    }
    func webView(_ webView: WKWebView, requestMediaCapturePermissionFor origin: WKSecurityOrigin, initiatedByFrame frame: WKFrameInfo, type: WKMediaCaptureType, decisionHandler: @escaping (WKPermissionDecision) -> Void) { decisionHandler(model?.data.settings.advanced?.allowMediaCapture == false ? .deny : .prompt) }
    func webView(_ webView: WKWebView, contextMenuConfigurationForElement elementInfo: WKContextMenuElementInfo, completionHandler: @escaping (UIContextMenuConfiguration?) -> Void) {
        guard let url = elementInfo.linkURL, BrowserURL.isWeb(url) else { completionHandler(nil); return }
        completionHandler(UIContextMenuConfiguration(identifier: nil, previewProvider: nil) { [weak self] _ in
            UIMenu(children: [
                UIAction(title: "فتح في تبويب جديد", image: UIImage(systemName: "plus.square")) { _ in self?.model?.newTab(url: url) },
                UIAction(title: "تنزيل الرابط", image: UIImage(systemName: "arrow.down.circle")) { _ in guard let model = self?.model else { return }; Task { await model.downloads.start(url: url, profile: model.profile, referrer: webView.url, webView: webView) } },
                UIAction(title: "نسخ الرابط", image: UIImage(systemName: "doc.on.doc")) { _ in UIPasteboard.general.url = url }
            ])
        })
    }
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let model, let tab, model.current?.id == tab.id, model.data.settings.developerTools, message.frameInfo.isMainFrame,
              let body = message.body as? [String: String], let text = body["message"] else { return }
        model.console.append(ConsoleEntry(text: String(text.prefix(4000)), kind: body["type"] ?? "log"))
        if model.console.count > 300 { model.console.removeFirst(model.console.count - 300) }
    }
}
