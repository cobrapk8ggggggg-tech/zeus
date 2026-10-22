import SwiftUI

// MARK: - Context-menu preview

/// Opaque rounded-card preview shown under a message's long-press context menu.
///
/// [T-ios-longpress-menu-preview-background] The message cells are hosted with a
/// clear background (host.view / cell backgroundColor = .clear), and the message
/// `.contextMenu`s are attached either to a zero-size `Color.clear` overlay
/// (assistant block/footer) or to a bubble whose fill is the translucent
/// `tertiarySystemFill` (user). Without an explicit `preview:`, SwiftUI snapshots
/// that (transparent) attached view, so the long-press preview platter shows
/// through to the messages below — the reported "transparent preview" bug.
///
/// Supplying this as the `.contextMenu(preview:)` gives the platter an opaque
/// `systemBackground` rounded card with the message text, so it reads as a
/// floating card. System colors only, so dark mode stays correct.
///
/// [T-ios-longpress-preview-full-content-card] The earlier version hard-capped
/// the text at 1500 chars with a trailing "…", which is what users saw as a
/// "truncated" preview on long assistant messages. It now renders the FULL
/// message content inside a vertical ScrollView: short messages size to their
/// content, long ones are capped to a fraction of the screen height and scroll
/// inside the platter (Telegram/iMessage-style), so the preview is both opaque
/// and complete. An explicit measured height is required because a ScrollView
/// has no intrinsic height — without it the context-menu platter would collapse.
struct MessageContextMenuPreview: View {
    let text: String

    /// [T-ios-usermsg-preview-adaptive-width] Width is now a CAP, not a fixed
    /// size. A short user bubble ("ok") previously lifted into a full 360pt
    /// platter; the platter now hugs the laid-out text width (measured by the
    /// same GeometryReader that already measured height) and only long lines
    /// wrap at this cap, iMessage-style.
    private let maxCardWidth: CGFloat = 360
    /// Long messages cap the platter to this fraction of screen height and
    /// scroll inside; short messages size to content (min of the two).
    private var maxCardHeight: CGFloat { UIScreen.main.bounds.height * 0.55 }

    @State private var contentSize: CGSize = .zero

    var body: some View {
        let shown = text.isEmpty ? " " : text
        ScrollView(.vertical, showsIndicators: true) {
            // No `.frame(maxWidth: .infinity)` here — the Text must report its
            // NATURAL width so short messages yield a narrow platter. The wrap
            // width comes from the ScrollView's width (the outer .frame below),
            // which starts at the cap and shrinks to the measured content.
            Text(shown)
                .font(.system(size: FontSettings.shared.scaledMessage(16.5)))
                .foregroundStyle(ChatColors.primaryText)
                .multilineTextAlignment(.leading)
                .padding(16)
                .background(
                    // Measure the laid-out text size so the platter can hug
                    // content (short) or cap + wrap/scroll (long).
                    GeometryReader { geo in
                        Color.clear
                            .preference(key: PreviewContentSizeKey.self, value: geo.size)
                    }
                )
        }
        .onPreferenceChange(PreviewContentSizeKey.self) { contentSize = $0 }
        // Size = content size, capped. Falls back to the caps until the first
        // measurement lands so the platter never collapses to zero. The small
        // width floor keeps an (attachment-only) empty-text preview from
        // rendering as a sliver.
        .frame(
            width: contentSize.width > 0 ? min(max(contentSize.width, 60), maxCardWidth) : maxCardWidth,
            height: contentSize.height > 0 ? min(contentSize.height, maxCardHeight) : maxCardHeight
        )
        .modifier(ContextMenuPreviewSurface())
    }
}

/// Background for the long-press preview platter.
///
/// Matches `UserBubbleSurface` so lifting a bubble doesn't jump from Liquid
/// Glass to a flat colour card — the shape (`RoundedRectangle(cornerRadius: 18)`,
/// non-`.continuous`) is deliberately the same one the bubble and the row's
/// `.contentShape(.contextMenuPreview, …)` already use.
///
/// **The opaque base stays.** [T-ios-longpress-menu-preview-background] exists
/// because the platter was showing through to the messages underneath: cells are
/// hosted on a clear background and the menus hang off either a zero-size
/// `Color.clear` overlay or a `tertiarySystemFill` bubble, so SwiftUI's snapshot
/// of the attached view was effectively transparent. Glass is a translucent
/// material, so using it ALONE would risk re-opening exactly that bug. Painting
/// it over `ChatColors.background` keeps the platter opaque no matter what the
/// system composites behind it, while the material still supplies the glass
/// highlight and edge that make it read as continuous with the bubble.
private struct ContextMenuPreviewSurface: ViewModifier {
    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: 18)
    }

    func body(content: Content) -> some View {
        if #available(iOS 26.0, *) {
            content
                // Opaque floor first — see the note above.
                .background(shape.fill(ChatColors.background))
                .glassEffect(.regular, in: shape)
        } else {
            content.background(ChatColors.background)
        }
    }
}

/// Preference key carrying the laid-out preview text size up to the platter.
/// Background for the user message bubble.
///
/// Two states that must stay tellable apart at a glance:
///
///  - **Sent** (`isQueued == false`) — Liquid Glass on iOS 26+. These bubbles
///    scroll over other messages, images and code blocks, so the material has
///    genuinely varied content to sample; this is the case glass is for, the
///    same as the tool-status bar and unlike `FolderSurface`, which had to fall
///    back to a sampled constant for want of anything behind it.
///  - **Queued** (`isQueued == true`) — deliberately NOT glass, on either OS.
///    Glass reads as a settled, physical surface, which is the opposite of what
///    a not-yet-sent message means. It keeps the existing empty fill + dashed
///    border, so "queued" still looks provisional next to the solid glass of
///    everything already sent.
///
/// The text is the modified content rather than an `.overlay`, which is what
/// keeps it above the material: `.glassEffect` composites the material over the
/// view it modifies, so an overlaid label would be painted underneath it and
/// disappear (the FAB regression).
struct UserBubbleSurface: ViewModifier {
    let isQueued: Bool

    /// Matches `.contentShape(.contextMenuPreview, RoundedRectangle(cornerRadius: 18))`
    /// on the row exactly — including the default (non-`.continuous`) corner
    /// style. A `.continuous` bubble against a circular-arc preview clip would
    /// show the corners subtly change shape as the long-press lift begins.
    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: 18)
    }

    func body(content: Content) -> some View {
        if isQueued {
            // Provisional look, identical on every OS version.
            content
                .background(shape.fill(Color.clear))
                .overlay(
                    shape
                        .strokeBorder(style: StrokeStyle(lineWidth: 1.5, dash: [6, 4]))
                        .foregroundStyle(ChatColors.secondaryText.opacity(0.5))
                )
        } else if #available(iOS 26.0, *) {
            content.glassEffect(.regular, in: shape)
        } else {
            content.background(shape.fill(ChatColors.userBubble))
        }
    }
}

private struct PreviewContentSizeKey: PreferenceKey {
    static var defaultValue: CGSize = .zero
    static func reduce(value: inout CGSize, nextValue: () -> CGSize) {
        let next = nextValue()
        value = CGSize(width: max(value.width, next.width), height: max(value.height, next.height))
    }
}
