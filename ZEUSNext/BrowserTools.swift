import Foundation
import WebKit
import UIKit

enum BrowserTools {
    static let consoleScript = """
    (()=>{for(const kind of ['log','warn','error','info']){const original=console[kind];console[kind]=function(...args){try{window.webkit.messageHandlers.zeusConsole.postMessage({type:kind,message:args.map(a=>{try{return typeof a==='string'?a:JSON.stringify(a)}catch{return String(a)}}).join(' ').slice(0,4000)})}catch{};original.apply(console,args)}}})();
    """
    static let reader = """
    (()=>{const root=document.querySelector('article,main,[role=main],.entry-content,.chapter-content')||document.body;const seen=new Set();const paragraphs=[];let size=0;for(const el of root.querySelectorAll('h1,h2,h3,p,li')){const s=getComputedStyle(el);const t=(el.innerText||'').replace(/\\s+/g,' ').trim();if(t.length<3||seen.has(t)||s.display==='none'||s.visibility==='hidden')continue;if(paragraphs.length>=500||size+t.length>180000)break;paragraphs.push(t);seen.add(t);size+=t.length}return {title:document.title||'القارئ',paragraphs}})();
    """
    static let gallery = """
    (()=>{const urls=new Set();for(const img of document.images){const src=img.currentSrc||img.src;if(src&&img.naturalWidth>=160&&img.naturalHeight>=160&&/^https?:/.test(src))urls.add(src);if(urls.size>=150)break}return Array.from(urls)})();
    """
}

extension BrowserModel {
    func readerMode() {
        guard let view = webView else { return }
        view.evaluateJavaScript(BrowserTools.reader) { [weak self] result, error in
            guard let self else { return }
            guard let value = result as? [String: Any], let paragraphs = value["paragraphs"] as? [String], !paragraphs.isEmpty else { self.notify(error?.localizedDescription ?? "لم يُعثر على نص مناسب لوضع القراءة."); return }
            self.article = ReaderArticle(title: value["title"] as? String ?? "القارئ", paragraphs: paragraphs)
        }
    }
    func galleryMode() {
        webView?.evaluateJavaScript(BrowserTools.gallery) { [weak self] value, error in
            guard let self else { return }
            if let urls = value as? [String], !urls.isEmpty { self.gallery = GalleryArticle(images: urls) }
            else { self.notify(error?.localizedDescription ?? "لا توجد صور كبيرة جاهزة في الصفحة.") }
        }
    }
    func savePDF() {
        guard let view = webView else { return }
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
        guard let view = webView else { return }; let owner = profile
        view.takeSnapshot(with: nil) { [weak self] image, error in
            guard let self, let bytes = image?.pngData() else { self?.notify(error?.localizedDescription ?? "تعذّر تصوير الصفحة."); return }
            let path = FileManager.default.temporaryDirectory.appendingPathComponent("ZEUS-" + UUID().uuidString.prefix(8) + ".png")
            do { try bytes.write(to: path, options: .atomic); Task { await self.downloads.importFile(path, profile: owner); try? FileManager.default.removeItem(at: path); self.notify("حُفظت اللقطة في التنزيلات.") } }
            catch { self.notify(error.localizedDescription) }
        }
    }
    func printPage() {
        guard let view = webView, view.window != nil else { return }
        let controller = UIPrintInteractionController.shared
        let info = UIPrintInfo(dictionary: nil); info.jobName = current?.title ?? "ZEUS"; info.outputType = .general
        controller.printInfo = info; controller.printFormatter = view.viewPrintFormatter()
        controller.present(from: CGRect(x: view.bounds.midX, y: view.bounds.maxY - 1, width: 1, height: 1), in: view, animated: true)
    }
}
