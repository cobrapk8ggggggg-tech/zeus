import SwiftUI

/// Shared by every existing browser entry point. Only one BrowserSheetView
/// owns the WKViews at a time; the original pool (cookies, tabs, scroll and
/// downloads) survives expansion. The parent sheet remains the return route.
struct ZeusAgentBrowserWindow: View {
    @ObservedObject var pool: BrowserTabPool
    var isAgentBusy = false
    var onTakeover: (() -> Void)? = nil
    @Environment(\.dismiss) private var dismiss
    @State private var expanded = false
    @State private var closing = false
    @State private var inlineVisible = true
    var body: some View {
        Group {
            if inlineVisible {
                BrowserSheetView(pool: pool, isAgentBusy: isAgentBusy, onTakeover: onTakeover,
                                 onWindowResize: { inlineVisible = false; expanded = true })
            } else { Color(uiColor: .systemBackground) }
        }
        .fullScreenCover(isPresented: $expanded, onDismiss: {
            if closing { closing = false; dismiss() } else { inlineVisible = true }
        }) {
            BrowserSheetView(pool: pool, isAgentBusy: isAgentBusy, onTakeover: onTakeover,
                             onWindowResize: { expanded = false }, windowExpanded: true,
                             onWindowClose: { closing = true; expanded = false })
        }
    }
}
