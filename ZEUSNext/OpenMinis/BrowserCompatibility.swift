// Browser integration for the OpenMinis views vendored at 6339bfcb2519.
import SwiftUI
import AVKit
import ImageIO
import OSLog
import ObjectiveC

let mediaPlaceholderHeight: CGFloat = 200
// Bridge OpenMinis' selection/autoscroll contract to SwiftUI's UIScrollView.
typealias NoAnimationCollectionView = UIScrollView
private var selectionBridgeKey: UInt8 = 0
@MainActor private final class SelectionScrollBridge: NSObject {
    weak var scroll: UIScrollView?
    var lockedOffset: CGPoint?
    var selected = false
    var onStep: ((CGPoint) -> Void)?
    var point = CGPoint.zero
    var ticker: CADisplayLink?
    func stop() { ticker?.invalidate(); ticker = nil }
    func update(_ point: CGPoint) {
        self.point = point
        guard ticker == nil else { return }
        let link = CADisplayLink(target: self, selector: #selector(tick)); ticker = link; link.add(to: .main, forMode: .common)
    }
    @objc func tick() {
        guard let scroll, selected else { stop(); return }
        let visible = scroll.bounds, edge: CGFloat = 55
        let delta: CGFloat = point.y < visible.minY + edge ? -min(10, (visible.minY + edge - point.y) / 5) : point.y > visible.maxY - edge ? min(10, (point.y - visible.maxY + edge) / 5) : 0
        guard delta != 0 else { return }
        let y = max(-scroll.adjustedContentInset.top, min(scroll.contentSize.height - visible.height + scroll.adjustedContentInset.bottom, scroll.contentOffset.y + delta))
        let movement = y - scroll.contentOffset.y
        scroll.setContentOffset(CGPoint(x: scroll.contentOffset.x, y: y), animated: false)
        point.y += movement; onStep?(point)
    }
}
extension UIScrollView {
    private var selectionBridge: SelectionScrollBridge {
        if let bridge = objc_getAssociatedObject(self, &selectionBridgeKey) as? SelectionScrollBridge { return bridge }
        let bridge = SelectionScrollBridge(); bridge.scroll = self
        objc_setAssociatedObject(self, &selectionBridgeKey, bridge, .OBJC_ASSOCIATION_RETAIN_NONATOMIC); return bridge
    }
    var offsetLocked: Bool {
        get { selectionBridge.lockedOffset != nil }
        set { if newValue { selectionBridge.lockedOffset = contentOffset } else if let offset = selectionBridge.lockedOffset { selectionBridge.lockedOffset = nil; setContentOffset(offset, animated: false) } }
    }
    var hasActiveTextSelection: Bool { get { selectionBridge.selected } set { selectionBridge.selected = newValue; if !newValue { selectionBridge.stop() } } }
    var onAutoScrollStep: ((CGPoint) -> Void)? { get { selectionBridge.onStep } set { selectionBridge.onStep = newValue } }
    func updateSelectionAutoScroll(touchPoint: CGPoint) { selectionBridge.update(touchPoint) }
    func stopSelectionAutoScroll() { selectionBridge.stop() }
}

struct AppLogger {
    let category: String
    func debug(_ message: @autoclosure () -> String) { }
    func info(_ message: @autoclosure () -> String) { }
    func notice(_ message: @autoclosure () -> String) { }
    func warning(_ message: @autoclosure () -> String) { Logger(subsystem: "tools.zeus", category: category).warning("\(message(), privacy: .private)") }
    func error(_ message: @autoclosure () -> String) { warning(message()) }
}
struct LLMUsage { var inputTokens = 0; var outputTokens = 0; var cacheCreationInputTokens: Int?; var cacheReadInputTokens: Int? }
final class LoggingManager {
    static let shared = LoggingManager()
    func writeRawLine(_ line: String) { Logger(subsystem: "tools.zeus", category: "Markdown").debug("\(line, privacy: .private)") }
    func writeRawLine(category: String, level: String, message: String) { writeRawLine(message) }
    func flush() { }
}
enum OpenMinisMedia {
    static var root: URL?
    static func resolve(_ url: URL) -> URL? {
        guard url.scheme == "minis", let root else { return nil }
        let candidate = root.appendingPathComponent((url.host ?? "") + url.path).standardizedFileURL.resolvingSymlinksInPath()
        let base = root.standardizedFileURL.resolvingSymlinksInPath().path + "/"
        return candidate.path.hasPrefix(base) && FileManager.default.fileExists(atPath: candidate.path) ? candidate : nil
    }
}
func resolveMinisFileURLCached(url: URL) -> URL? { OpenMinisMedia.resolve(url) }
func minisMediaCacheKey(for source: String) -> String {
    guard let url = URL(string: source), let file = OpenMinisMedia.resolve(url), let values = try? file.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey]) else { return source }
    return source + ":\(values.fileSize ?? 0):\(values.contentModificationDate?.timeIntervalSince1970 ?? 0)"
}
func minisMediaCacheKey(for url: URL) -> String { minisMediaCacheKey(for: url.absoluteString) }
func downsampleImage(data: Data, maxPixelSize: CGFloat = 2048) -> UIImage? {
    guard let source = CGImageSourceCreateWithData(data as CFData, nil), let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceCreateThumbnailWithTransform: true, kCGImageSourceThumbnailMaxPixelSize: maxPixelSize] as CFDictionary) else { return UIImage(data: data) }
    return UIImage(cgImage: image)
}
final class MinisMediaCache {
    static let shared = MinisMediaCache()
    private let thumbnails = NSCache<NSString, UIImage>()
    func thumbnail(for key: String) -> UIImage? { thumbnails.object(forKey: key as NSString) }
    func setThumbnail(_ image: UIImage, for key: String) { thumbnails.countLimit = 30; thumbnails.setObject(image, forKey: key as NSString) }
}
@MainActor final class VoiceOutputPlayer {
    static let shared = VoiceOutputPlayer()
    static let manualOwnerId = "zeus-selected-text"
    private let synthesizer = AVSpeechSynthesizer()
    func stopAll() { synthesizer.stopSpeaking(at: .immediate) }
    func enqueueSegmented(_ text: String, sessionId: String) {
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = AVSpeechSynthesisVoice(language: text.range(of: "[؀-ۿ]", options: .regularExpression) == nil ? "en-US" : "ar-SA")
        synthesizer.speak(utterance)
    }
}
@MainActor final class GlobalAudioPlayer: ObservableObject {
    static let shared = GlobalAudioPlayer()
    @Published var isPlaying = false
    @Published var currentTime: TimeInterval = 0
    @Published var duration: TimeInterval = 0
    @Published var activeFileURL: URL?
    private var player: AVPlayer?
    private var observer: Any?
    func loadAndPlay(url: URL) {
        if let observer { player?.removeTimeObserver(observer) }
        activeFileURL = url; player = AVPlayer(url: url)
        observer = player?.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.25, preferredTimescale: 600), queue: .main) { [weak self] time in
            Task { @MainActor in guard let self else { return }; self.currentTime = time.seconds; let length = self.player?.currentItem?.duration.seconds ?? 0; self.duration = length.isFinite ? length : 0 }
        }
        player?.play(); isPlaying = true
    }
    func play(url: URL) { loadAndPlay(url: url) }
    func isActive(url: URL) -> Bool { activeFileURL == url }
    func togglePlayPause() { if isPlaying { pause() } else { play() } }
    func play() { player?.play(); isPlaying = true }
    func pause() { player?.pause(); isPlaying = false }
    func seek(to value: TimeInterval) { player?.seek(to: CMTime(seconds: value, preferredTimescale: 600)); currentTime = value }
}
struct MinisAudioPreviewView: View {
    let fileURL: URL
    var body: some View { VideoPlayer(player: AVPlayer(url: fileURL)).preferredColorScheme(.dark) }
}
