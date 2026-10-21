import SwiftUI
import UIKit
import WebKit
import SafariServices
import QuickLook

struct GlassSurface: ViewModifier {
    @Environment(\.browserTheme) private var theme
    var radius: CGFloat
    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        let gradient = LinearGradient(colors: [theme.surfaceColor, theme.secondSurfaceColor], startPoint: .topLeading, endPoint: .bottomTrailing)
        if theme.style == .solid {
            content.background(theme.surfaceColor, in: shape).overlay(shape.stroke(theme.borderColor.opacity(0.45), lineWidth: 0.7))
        } else if #available(iOS 26.0, *) {
            content.background(gradient.opacity(0.4), in: shape).glassEffect(.regular.tint(theme.surfaceColor.opacity(0.18)), in: shape).overlay(shape.stroke(theme.borderColor.opacity(0.4), lineWidth: 0.7))
        } else {
            content.background(gradient.opacity(0.35), in: shape).background(.ultraThinMaterial, in: shape).overlay(shape.stroke(theme.borderColor.opacity(0.45), lineWidth: 0.7))
        }
    }
}

extension View { func glassSurface(_ radius: CGFloat = 24) -> some View { modifier(GlassSurface(radius: radius)) } }

struct OrbitBackground: View {
    @Environment(\.browserTheme) private var theme
    var tint: Color = Color(red: 1, green: 1, blue: 1)
    var body: some View { theme.backgroundColor.ignoresSafeArea() }

}

struct ToolButton: View {
    @Environment(\.browserTheme) private var theme
    let symbol: String
    let label: String
    var selected = false
    var disabled = false
    var action: () -> Void
    var body: some View {
        Button(action: action) { Image(systemName: symbol).font(.system(size: 19, weight: .medium)).foregroundStyle(selected ? theme.textColor : theme.textColor.opacity(0.85)).frame(minWidth: 44, minHeight: 44).contentShape(Rectangle()) }
            .buttonStyle(.plain).disabled(disabled).opacity(disabled ? 0.3 : 1).accessibilityLabel(label)
    }
}

struct WebSurface: UIViewRepresentable {
    let webView: WKWebView
    func makeUIView(context: Context) -> WebSurfaceHost { let host = WebSurfaceHost(); host.show(webView); return host }
    func updateUIView(_ uiView: WebSurfaceHost, context: Context) { uiView.show(webView) }
}
final class WebSurfaceHost: UIView {
    private(set) weak var displayedWebView: WKWebView?
    func show(_ webView: WKWebView) {
        guard displayedWebView !== webView || webView.superview !== self else { return }
        for child in subviews { child.removeFromSuperview() }
        webView.removeFromSuperview(); webView.frame = bounds
        webView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        addSubview(webView); displayedWebView = webView
    }
}

struct ActivitySheet: UIViewControllerRepresentable {
    let url: URL
    func makeUIViewController(context: Context) -> UIActivityViewController { UIActivityViewController(activityItems: [url], applicationActivities: nil) }
    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}

struct FilePreview: UIViewControllerRepresentable {
    let url: URL
    func makeCoordinator() -> Coordinator { Coordinator(url: url) }
    func makeUIViewController(context: Context) -> QLPreviewController { let controller = QLPreviewController(); controller.dataSource = context.coordinator; return controller }
    func updateUIViewController(_ controller: QLPreviewController, context: Context) {}
    final class Coordinator: NSObject, QLPreviewControllerDataSource {
        let url: URL
        init(url: URL) { self.url = url }
        func numberOfPreviewItems(in controller: QLPreviewController) -> Int { FileManager.default.fileExists(atPath: url.path) ? 1 : 0 }
        func previewController(_ controller: QLPreviewController, previewItemAt index: Int) -> QLPreviewItem { url as NSURL }
    }
}

struct FileExporter: UIViewControllerRepresentable {
    let url: URL
    func makeUIViewController(context: Context) -> UIDocumentPickerViewController { UIDocumentPickerViewController(forExporting: [url], asCopy: true) }
    func updateUIViewController(_ controller: UIDocumentPickerViewController, context: Context) {}
}

struct SystemBrowser: UIViewControllerRepresentable {
    let url: URL
    func makeUIViewController(context: Context) -> SFSafariViewController { let controller = SFSafariViewController(url: url); controller.dismissButtonStyle = .done; return controller }
    func updateUIViewController(_ controller: SFSafariViewController, context: Context) {}
}

struct PanelHeader: View {
    @Environment(\.browserTheme) private var theme
    var title: String
    var caption: String
    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(title).font(.system(size: 31, weight: .bold, design: .rounded))
            Text(caption).font(.subheadline).foregroundStyle(.secondary)
        }.frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 10)
    }
}

func byteText(_ bytes: Int64) -> String { ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file) }
