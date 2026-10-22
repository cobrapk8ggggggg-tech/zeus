import Foundation
import WebKit
import UIKit

enum BrowserTools {
    static let darkPage: String = {
        guard let url = Bundle.main.url(forResource: "dark-page", withExtension: "js"), let source = try? String(contentsOf: url, encoding: .utf8) else { return "" }
        guard let engineURL = Bundle.main.url(forResource: "darkreader", withExtension: "js"), let engine = try? String(contentsOf: engineURL, encoding: .utf8) else { return "" }
        return engine + "\n" + source
    }()
    static let consoleScript = """
    (()=>{for(const kind of ['log','warn','error','info']){const original=console[kind];console[kind]=function(...args){try{window.webkit.messageHandlers.zeusConsole.postMessage({type:kind,message:args.map(a=>{try{return typeof a==='string'?a:JSON.stringify(a)}catch{return String(a)}}).join(' ').slice(0,4000)})}catch{};original.apply(console,args)}}})();
    """
    // The original ZEUS selection order, short paragraphs and DIV handling are preserved.
    static let reader = """
    (()=>{const selectors=['article','main','.post-content','.entry-content','#article-body','.chapter-content'];let root=null;for(const selector of selectors){const el=document.querySelector(selector);if(el&&(el.innerText||'').length>100){root=el;break}}root=root||document.body;const seen=new Set(),paragraphs=[];let size=0;for(const el of root.querySelectorAll('p,h2,h3,div')){const style=getComputedStyle(el);if(style.display==='none'||style.visibility==='hidden'||style.opacity==='0'||el.offsetHeight===0)continue;if(el.tagName==='DIV'&&el.querySelector('p'))continue;const text=(el.innerText||'').replace(/\\s+/g,' ').trim();if(text.length>=2&&!seen.has(text)){if(size+text.length>500000||paragraphs.length>=3000)break;paragraphs.push(text);seen.add(text);size+=text.length}}return {title:(document.querySelector('h1')?.innerText||document.title||'القارئ').trim(),paragraphs}})();
    """
    // Restore CSS backgrounds and add lazy image sources. Preserve document order for webtoons.
    static let gallery = """
    (()=>{const found=new Set();const add=raw=>{try{if(!raw||found.size>=1000)return;const u=new URL(raw,document.baseURI);if(['http:','https:','data:','blob:'].includes(u.protocol))found.add(u.href)}catch{}};for(const img of document.querySelectorAll('img')){const lazy=img.getAttribute('data-src')||img.getAttribute('data-lazy-src')||img.getAttribute('data-original');if(img.naturalWidth>150&&img.naturalHeight>150){add(img.currentSrc||img.src)}if(lazy)add(lazy);if(!img.complete&&(img.width>150||img.height>150))add(img.currentSrc||img.src)}let count=0;for(const el of document.querySelectorAll('*')){if(++count>30000||found.size>=1000)break;const bg=getComputedStyle(el).backgroundImage;if(bg&&bg!=='none'){const re=/url\\(\\s*(['"]?)(.*?)\\1\\s*\\)/g;let m;while((m=re.exec(bg)))add(m[2])}}return Array.from(found)})();
    """

}

extension BrowserModel {
    func readerMode() {
        guard let view = webView else { return }
        let owner = profile.id, tabID = current?.id
        view.evaluateJavaScript(BrowserTools.reader) { [weak self] result, error in
            guard let self, self.profile.id == owner, self.current?.id == tabID else { return }
            guard let value = result as? [String: Any], let paragraphs = value["paragraphs"] as? [String], !paragraphs.isEmpty else { self.notify(error?.localizedDescription ?? "لم يُعثر على نص مناسب لوضع القراءة."); return }
            self.article = ReaderArticle(title: value["title"] as? String ?? "القارئ", paragraphs: paragraphs, sourceURL: self.current?.url)
        }
    }
    func galleryMode() {
        let owner = profile.id, tabID = current?.id
        webView?.evaluateJavaScript(BrowserTools.gallery) { [weak self] value, error in
            guard let self, self.profile.id == owner, self.current?.id == tabID else { return }
            if let urls = value as? [String], !urls.isEmpty { self.gallery = GalleryArticle(images: urls) }
            else { self.notify(error?.localizedDescription ?? "لا توجد صور كبيرة جاهزة في الصفحة.") }
        }
    }
    func savePDF() {
        guard profile.account?.allowDownloads != false else { notify("حفظ الملفات غير مسموح لهذا الحساب."); return }
        guard let view = webView else { return }
        if data.settings.advanced?.paperSizedPDF != false {
            let renderer = pageRenderer(view)
            let pages = renderer.numberOfPages
            guard pages > 0, pages <= 500 else { notify("عدد صفحات المستند خارج الحد المدعوم (500 صفحة). اختر جزءًا أصغر للطباعة."); return }
            let bytes = UIGraphicsPDFRenderer(bounds: renderer.paperRect).pdfData { context in
                for page in 0..<pages { context.beginPage(); renderer.drawPage(at: page, in: renderer.paperRect) }
            }
            let owner = profile
            let path = FileManager.default.temporaryDirectory.appendingPathComponent("ZEUS-" + UUID().uuidString + ".pdf")
            do { try bytes.write(to: path, options: .atomic); Task { await downloads.importFile(path, profile: owner); try? FileManager.default.removeItem(at: path); notify("حُفظ PDF مقسّمًا إلى \(pages) صفحة.") } } catch { notify(error.localizedDescription) }
            return
        }
        let config = WKPDFConfiguration()
        config.rect = CGRect(x: 0, y: 0, width: max(view.bounds.width, 320), height: min(max(view.scrollView.contentSize.height, view.bounds.height), 20_000))
        let owner = profile
        view.createPDF(configuration: config) { [weak self] result in
            guard let self else { return }
            do {
                let bytes = try result.get()
                let path = FileManager.default.temporaryDirectory.appendingPathComponent("ZEUS-" + UUID().uuidString.prefix(8) + ".pdf")
                try bytes.write(to: path, options: .atomic)
                Task { await self.downloads.importFile(path, profile: owner); try? FileManager.default.removeItem(at: path); self.notify("حُفظ PDF في التنزيلات؛ حُدد طول الصفحة لحماية الذاكرة.") }
            } catch { self.notify(error.localizedDescription) }
        }
    }
    func saveScreenshot() {
        guard profile.account?.allowDownloads != false else { notify("حفظ الملفات غير مسموح لهذا الحساب."); return }
        guard let view = webView else { return }; let owner = profile
        let options = data.settings.advanced ?? AdvancedSettings()
        let config = WKSnapshotConfiguration(); config.snapshotWidth = NSNumber(value: Double(view.bounds.width) * options.screenshotScale)
        view.takeSnapshot(with: config) { [weak self] image, error in
            guard let self, let image, let bytes = options.screenshotJPEG ? image.jpegData(compressionQuality: options.screenshotQuality) : image.pngData() else { self?.notify(error?.localizedDescription ?? "تعذّر تصوير الصفحة."); return }
            let path = FileManager.default.temporaryDirectory.appendingPathComponent("ZEUS-" + UUID().uuidString.prefix(8) + (options.screenshotJPEG ? ".jpg" : ".png"))
            do { try bytes.write(to: path, options: .atomic); Task { await self.downloads.importFile(path, profile: owner); try? FileManager.default.removeItem(at: path); self.notify("حُفظت اللقطة في التنزيلات.") } }
            catch { self.notify(error.localizedDescription) }
        }
    }
    func printPage() {
        guard let view = webView, view.window != nil else { return }
        let controller = UIPrintInteractionController.shared
        let info = UIPrintInfo(dictionary: nil); info.jobName = current?.title ?? "ZEUS"; info.outputType = .general
        controller.printInfo = info; controller.printPageRenderer = pageRenderer(view)
        controller.present(from: CGRect(x: view.bounds.midX, y: view.bounds.maxY - 1, width: 1, height: 1), in: view, animated: true)
    }
    private func pageRenderer(_ view: WKWebView) -> BrowserPrintRenderer {
        let options = data.settings.advanced ?? AdvancedSettings()
        let renderer = BrowserPrintRenderer(); renderer.documentTitle = current?.title ?? "ZEUS"; renderer.showsHeader = options.printHeader; renderer.showsFooter = options.printFooter; renderer.margin = options.printMargin; renderer.headerHeight = options.printHeader ? 24 : 0; renderer.footerHeight = options.printFooter ? 24 : 0
        renderer.addPrintFormatter(view.viewPrintFormatter(), startingAtPageAt: 0)
        return renderer
    }

}

extension BrowserModel {
    func saveWebArchive() {
        guard profile.account?.allowDownloads != false, let view = webView else { return }; let owner = profile
        view.createWebArchiveData { [weak self] result in
            guard let self else { return }
            do { let bytes = try result.get(); let path = FileManager.default.temporaryDirectory.appendingPathComponent("ZEUS-" + UUID().uuidString + ".webarchive"); try bytes.write(to: path, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication]); Task { await self.downloads.importFile(path, profile: owner); try? FileManager.default.removeItem(at: path) } }
            catch { self.notify(error.localizedDescription) }
        }
    }
}
