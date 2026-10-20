import SwiftUI
import UIKit
import WebKit
import SafariServices
import QuickLook

struct GlassSurface: ViewModifier {
    var radius: CGFloat
    func body(content: Content) -> some View {
        if #available(iOS 26.0, *) {
            content.glassEffect(.regular, in: RoundedRectangle(cornerRadius: radius, style: .continuous))
        } else {
            content.background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: radius, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: radius).stroke(.white.opacity(0.12), lineWidth: 0.7))
        }
    }
}
extension View { func glassSurface(_ radius: CGFloat = 24) -> some View { modifier(GlassSurface(radius: radius)) } }

struct OrbitBackground: View {
    var tint: Color = .cyan
    var body: some View {
        ZStack {
            Color(red: 0.025, green: 0.04, blue: 0.075)
            RadialGradient(colors: [tint.opacity(0.2), .clear], center: .topTrailing, startRadius: 10, endRadius: 490)
            RadialGradient(colors: [Color.purple.opacity(0.15), .clear], center: .bottomLeading, startRadius: 30, endRadius: 480)
        }.ignoresSafeArea()
    }
}

struct ToolButton: View {
    let symbol: String
    let label: String
    var selected = false
    var disabled = false
    var action: () -> Void
    var body: some View {
        Button(action: action) { Image(systemName: symbol).font(.system(size: 19, weight: .medium)).foregroundStyle(selected ? Color.cyan : Color.white.opacity(0.85)).frame(minWidth: 44, minHeight: 44).contentShape(Rectangle()) }
            .buttonStyle(.plain).disabled(disabled).opacity(disabled ? 0.3 : 1).accessibilityLabel(label)
    }
}

struct WebSurface: UIViewRepresentable {
    let webView: WKWebView
    func makeUIView(context: Context) -> WKWebView { webView }
    func updateUIView(_ uiView: WKWebView, context: Context) {}
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
