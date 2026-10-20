import SwiftUI
import WebKit
import ImageIO

@MainActor enum FaviconMemory {
    static let images: NSCache<NSString, UIImage> = { let cache = NSCache<NSString, UIImage>(); cache.countLimit = 128; cache.totalCostLimit = 2_097_152; return cache }()
    static func purge() { images.removeAllObjects() }
}
struct FirstPartyFavicon: View {
    let site: Bookmark
    @State private var image: UIImage?
    var body: some View {
        Group {
            if let image { Image(uiImage: image).resizable().scaledToFit().saturation(0).frame(width: 32, height: 32).clipShape(Circle()) }
            else { Text(String(site.title.prefix(1)).uppercased()).font(.title2) }
        }.task(id: site.url) {
            guard let url = URL(string: site.url), BrowserURL.isWeb(url), var parts = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return }
            parts.path = "/favicon.ico"; parts.query = nil; parts.fragment = nil; parts.user = nil; parts.password = nil
            guard let favicon = parts.url else { return }
            if let cached = FaviconMemory.images.object(forKey: favicon.absoluteString as NSString) { image = cached; return }
            let config = URLSessionConfiguration.ephemeral; config.httpCookieStorage = nil; config.httpShouldSetCookies = false; config.urlCache = nil; config.timeoutIntervalForResource = 12
            let session = URLSession(configuration: config, delegate: ThumbnailRedirects(cookies: []), delegateQueue: nil); defer { session.invalidateAndCancel() }
            do {
                let (path, response) = try await session.download(from: favicon); defer { try? FileManager.default.removeItem(at: path) }
                guard (response as? HTTPURLResponse)?.statusCode == 200, ((try path.resourceValues(forKeys: [.fileSizeKey])).fileSize ?? 0) <= 1_048_576, let source = CGImageSourceCreateWithURL(path as CFURL, nil), let bitmap = CGImageSourceCreateThumbnailAtIndex(source, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceThumbnailMaxPixelSize: 64] as CFDictionary) else { return }
                let decoded = UIImage(cgImage: bitmap); image = decoded; FaviconMemory.images.setObject(decoded, forKey: favicon.absoluteString as NSString, cost: bitmap.bytesPerRow * bitmap.height)
            } catch { }
        }
    }
}
