import Foundation
import WebKit
import Photos
import ImageIO

@MainActor enum GalleryPhotoSaver {
    static func authorize() async -> Bool {
        let status = await withCheckedContinuation { c in PHPhotoLibrary.requestAuthorization(for: .addOnly) { c.resume(returning: $0) } }
        return status == .authorized || status == .limited
    }
    static func save(address: String, store: WKWebsiteDataStore, source: WKWebView?) async throws {
        guard let url = URL(string: address) else { throw URLError(.badURL) }
        let path: URL
        if ["blob", "data"].contains(url.scheme ?? "") {
            guard let source else { throw URLError(.badURL) }
            let value = try await source.callAsyncJavaScript("const blob=await(await fetch(address)).blob();if(blob.size>16777216)throw Error('image too large');return await new Promise((resolve,reject)=>{const r=new FileReader();r.onload=()=>resolve(r.result);r.onerror=reject;r.readAsDataURL(blob)});", arguments: ["address": address], in: nil, contentWorld: .page)
            guard let raw = value as? String, let encoded = raw.split(separator: ",", maxSplits: 1).last, let data = Data(base64Encoded: String(encoded)) else { throw URLError(.cannotDecodeContentData) }
            path = FileManager.default.temporaryDirectory.appendingPathComponent("ZEUS-Photo-" + UUID().uuidString)
            try data.write(to: path, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        } else {
            guard BrowserURL.isWeb(url) else { throw URLError(.unsupportedURL) }
            let cookies: [HTTPCookie] = await withCheckedContinuation { c in store.httpCookieStore.getAllCookies { c.resume(returning: $0) } }
            let config = URLSessionConfiguration.ephemeral; config.httpCookieStorage = nil; config.httpShouldSetCookies = false; config.urlCache = nil
            let session = URLSession(configuration: config, delegate: ThumbnailRedirects(cookies: cookies), delegateQueue: nil); defer { session.invalidateAndCancel() }
            var request = URLRequest(url: url); request.allHTTPHeaderFields = DownloadFiles.cookieHeaders(cookies, for: url)
            if let page = source?.url, let origin = BrowserModel.origin(page) { request.setValue(origin + "/", forHTTPHeaderField: "Referer") }
            let (temporary, response) = try await session.download(for: request)
            guard (response as? HTTPURLResponse)?.statusCode == 200, ((try temporary.resourceValues(forKeys: [.fileSizeKey])).fileSize ?? 0) <= 25_000_000 else { try? FileManager.default.removeItem(at: temporary); throw URLError(.cannotDecodeContentData) }
            path = FileManager.default.temporaryDirectory.appendingPathComponent("ZEUS-Photo-" + UUID().uuidString + "." + ((response.suggestedFilename ?? "image.jpg") as NSString).pathExtension)
            try FileManager.default.moveItem(at: temporary, to: path)
        }
        defer { try? FileManager.default.removeItem(at: path) }
        guard CGImageSourceCreateWithURL(path as CFURL, nil) != nil else { throw URLError(.cannotDecodeContentData) }
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
            PHPhotoLibrary.shared().performChanges { PHAssetChangeRequest.creationRequestForAssetFromImage(atFileURL: path) } completionHandler: { success, error in
                if success { c.resume() } else { c.resume(throwing: error ?? URLError(.cannotCreateFile)) }
            }
        }
    }
}
