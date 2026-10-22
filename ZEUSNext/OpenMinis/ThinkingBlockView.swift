import SwiftUI
import Combine
@MainActor
final class ThinkingHitchMonitor {
    static let shared = ThinkingHitchMonitor()

    /// Retained so `ThinkingBlockView` keeps compiling; nothing reads it.
    var bodyEvalCount = 0
    var contentLenProvider: (() -> Int)?

    func start(owner: UUID) {}
    func stop(owner: UUID) {}
}

struct ThinkingBlockView: View {
    @ObservedObject var block: AssistantBlock
    let isStreaming: Bool

    // [T-thinking-scroll-followback GH#125] Per-view follow state. Reset on
    // cell reuse / re-entry is fine — a fresh view simply follows again.
    @State private var thinkingUserScrolledAway = false
    @State private var lastThinkingDragAt: Date = .distantPast
    @State private var frozenThinkingContent: String? = nil

    /// Bind to block.isThinkingExpanded so state survives cell reuse and triggers cell re-sizing.
    private var isExpanded: Binding<Bool> {
        Binding(
            get: { block.isThinkingExpanded },
            set: { block.isThinkingExpanded = $0 }
        )
    }

    init(block: AssistantBlock, isStreaming: Bool) {
        self.block = block
        self.isStreaming = isStreaming
        // Auto-expand-on-stream is handled in `.onAppear` (gated by block.id)
        // rather than from `init`. Mutating @Published from a SwiftUI view
        // initializer fires for every cell-reuse pass and was reaching the
        // wrong block when the cell was being recycled between an earlier
        // (frozen) thinking block and the currently-streaming one — manifesting
        // as "tap an old thinking block, see the streaming block's content."
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header
            HStack(spacing: 6) {
                Image("ThinkingIcon")
                    .resizable()
                    .frame(width: 14, height: 14)
                    .foregroundStyle(.blue)
                Text(String(localized: "Deep Thinking"))
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.blue)
                if isStreaming {
                    ProgressView()
                        .controlSize(.mini)
                        .tint(.blue)
                }
                if block.content.count > 0 || block.thinkingContentBuffer.count > 0 {
                    let charCount = max(block.content.count, block.thinkingContentBuffer.count)
                    Text(charCount > 1000 ? "\(charCount / 1000)K" : "\(charCount)")
                        .font(.system(size: 11, weight: .medium, design: .monospaced))
                        .foregroundStyle(.blue.opacity(0.6))
                }
                Spacer()
                Image(systemName: isExpanded.wrappedValue ? "chevron.up" : "chevron.down")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.blue.opacity(0.5))
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .contentShape(Rectangle())
            .onTapGesture {
                // Mark before flipping so any concurrent stream-end collapse
                // observer in this view sees `thinkingUserToggled = true`
                // and bails out instead of stomping the user's choice.
                // The collection view's cached height is invalidated by the
                // `onChange(of: isThinkingExpanded)` observer below — single
                // source of truth so the auto-collapse path stays in sync.
                AppLogger(category: "ThinkingCollapse").info("[ThinkingCollapse] tap block=\(block.id.uuidString.prefix(8)) wasExpanded=\(isExpanded.wrappedValue) streaming=\(isStreaming) contentLen=\(block.content.count)")
                block.thinkingUserToggled = true
                if !isExpanded.wrappedValue {
                    block.flushThinkingBuffer()
                }
                isExpanded.wrappedValue.toggle()
            }

            // Content — only visible when expanded, windowed to the tail
            // to prevent UI freeze on very long thinking (T-thinking-render-perf-ios).
            if isExpanded.wrappedValue, !block.content.isEmpty {
                // [T-thinking-stream-window] While STREAMING, shrink the tail
                // window 8000 → 2000: every flush re-lays-out the whole Text
                // on the main thread, and an 8K plain-text relayout per flush
                // is the reported "5K starts to lag, 10K unusable" jank (the
                // hitch cost scales with the WINDOW, not the total). Reading
                // the live tail only needs the recent context; the full 8K
                // window comes back the moment streaming ends.
                let windowSize = isStreaming ? 2000 : 8000
                let total = block.content.count
                let isTruncated = total > windowSize
                let displayContent: String = frozenThinkingContent ?? {
                    // [T-thinkperf-release-displaylink] The slice timing and
                    // body-eval counter that used to wrap this closure are gone.
                    // It runs on EVERY body evaluation of an expanded thinking
                    // block, so it paid two CFAbsoluteTimeGetCurrent calls per
                    // eval to feed a counter only ThinkPerf's own log lines read.
                    // The question it existed to answer — do body re-evals track
                    // per-token contentUpdateSeq rather than the flush? — was
                    // answered (they did) and fixed.
                    guard isTruncated else { return block.content }
                    let startIdx = block.content.index(block.content.endIndex, offsetBy: -windowSize)
                    let cleanStart = block.content[startIdx...].firstIndex(of: "\n")
                        .map { block.content.index(after: $0) } ?? startIdx
                    return String(block.content[cleanStart...])
                }()

                ScrollViewReader { proxy in
                    ScrollView {
                        VStack(alignment: .leading, spacing: 0) {
                            if isTruncated {
                                Text("Showing last \(displayContent.count / 1000)K of \(total / 1000)K characters", comment: "Thinking window truncation hint")
                                    .font(.system(size: 11))
                                    .foregroundStyle(.secondary)
                                    .padding(.horizontal, 12)
                                    .padding(.bottom, 4)
                            }
                            // [T-thinking-stream-jank] textSelection(.enabled)
                            // makes SwiftUI Text substantially more expensive
                            // per layout; selecting text that is actively
                            // moving is useless anyway — enable it only once
                            // streaming finished.
                            let thinkingText = Text(displayContent)
                                .font(.system(size: 13))
                                .foregroundStyle(ChatColors.tertiaryText)
                                .lineSpacing(3)
                            Group {
                                if isStreaming {
                                    thinkingText
                                } else {
                                    thinkingText.textSelection(.enabled)
                                }
                            }
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal, 12)
                                .padding(.bottom, 10)
                                .id("thinkingBottom")
                        }
                    }
                    .frame(maxHeight: 300)
                    // [T-thinking-scroll-followback GH#125] User-intent gate,
                    // Android parity (ChatAssistantMessageUI.kt): mark
                    // scrolled-away ONLY when a real finger drag moved the view
                    // off the bottom — programmatic scrollTo offsets must not
                    // set it, or follow would permanently disarm. Deployment
                    // target is iOS 16 (no onScrollPhaseChange), so "real drag"
                    // = a simultaneous DragGesture seen within the last 350ms.
                    // A downward drag inside the box means "show me earlier
                    // text" — that IS the scrolled-away intent, and unlike a
                    // geometry probe it cannot be spoofed by our own
                    // programmatic scrollTo (which fires no gesture). An
                    // upward drag (heading back toward the tail) re-arms
                    // following, as does the stream ending.
                    .simultaneousGesture(
                        DragGesture(minimumDistance: 6)
                            .onEnded { value in
                                lastThinkingDragAt = Date()
                                if value.translation.height > 12 {
                                    if !thinkingUserScrolledAway {
                                        thinkingUserScrolledAway = true
                                        frozenThinkingContent = displayContent
                                        AppLogger(category: "ThinkPerf").info("[ThinkPerf] user scrolled away (dy=\(Int(value.translation.height))) — follow paused, content frozen at \(displayContent.count) chars")
                                    }
                                } else if value.translation.height < -12, thinkingUserScrolledAway {
                                    thinkingUserScrolledAway = false
                                    frozenThinkingContent = nil
                                    AppLogger(category: "ThinkPerf").info("[ThinkPerf] user scrolled back (dy=\(Int(value.translation.height))) — following resumed")
                                }
                            }
                    )
                    // [T-thinking-stream-jank] Follow the tail at FLUSH pace
                    // (content updates every 0.3s), not per token. The old
                    // trigger was the per-delta contentUpdateSeq — with it
                    // @Published, an expanded block re-ran body + an animated
                    // scrollTo for every delta (~60-105/s measured); the flush
                    // pace is ~3-4/s for the same visual result.
                    .onChange(of: block.content.count) { len in
                        guard isStreaming, !thinkingUserScrolledAway else { return }
                        // [T-thinkperf-release-displaylink] Removed: this fired on
                        // every content flush of a streaming thinking block, and
                        // building the interpolated string cost more than the log
                        // call. The two scroll-gesture lines above stay — they
                        // fire once per user drag, not per flush.
                        // Animated follow only for short content — animating a
                        // long text's scroll re-lays-out every frame of the
                        // 0.15s animation; a jump is one layout.
                        if len > 3000 {
                            proxy.scrollTo("thinkingBottom", anchor: .bottom)
                        } else {
                            withAnimation(.linear(duration: 0.15)) {
                                proxy.scrollTo("thinkingBottom", anchor: .bottom)
                            }
                        }
                    }
                    .onChange(of: isStreaming) { streaming in
                        if !streaming {
                            thinkingUserScrolledAway = false
                            frozenThinkingContent = nil
                        }
                    }
                }
            }
        }
        // [T-thinking-stream-jank] Hitch monitor runs while this block is
        // EXPANDED — streaming or static. The refined report says the jank is
        // tied to the expanded state itself (collapse instantly recovers), so
        // the monitor must also capture expanded-static interactions (list
        // scrolling, new messages arriving) to compare against collapsed.
        .task(id: isExpanded.wrappedValue) {
            if isExpanded.wrappedValue {
                ThinkingHitchMonitor.shared.contentLenProvider = { [weak block] in
                    block?.thinkingContentBuffer.count ?? -1
                }
                ThinkingHitchMonitor.shared.start(owner: block.id)
            } else {
                ThinkingHitchMonitor.shared.stop(owner: block.id)
            }
        }
        .onDisappear {
            ThinkingHitchMonitor.shared.stop(owner: block.id)
        }
        .background(Color.blue.opacity(0.06))
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(Color.blue.opacity(0.15), lineWidth: 0.5)
        )
        .task(id: block.id) {
            // One-shot per-block auto-expand. Runs when this cell first hosts
            // a given thinking block (block.id is stable across content
            // updates) and only flips state if the user hasn't taken control.
            // [T-thinking-auto-expand-toggle] Gated on the Appearance setting
            // (default ON = historical behavior). When the user turned it off,
            // new streaming thinking blocks stay collapsed; a manual tap still
            // expands them (and sets thinkingUserToggled, so nothing here
            // fights the user either way).
            let autoExpand = (UserDefaults.standard.object(forKey: "chat.autoExpandThinking") as? Bool) ?? true
            if autoExpand, isStreaming, !block.thinkingUserToggled, !block.isThinkingExpanded {
                block.isThinkingExpanded = true
            }
        }
        .onChange(of: isStreaming) { streaming in
            // Auto-collapse when streaming for THIS block ends, but only if
            // the user hasn't manually toggled it. Without the user-touched
            // gate, the streaming-end transition stomped a tap the user did
            // on an earlier thinking block while a later one was still live.
            if !streaming, !block.thinkingUserToggled {
                AppLogger(category: "ThinkingCollapse").info("[ThinkingCollapse] auto-collapse block=\(block.id.uuidString.prefix(8)) streaming→false userToggled=false contentLen=\(block.content.count)")
                block.isThinkingExpanded = false
                // [T-ios-thinking-autocollapse-no-post] Post the invalidation
                // HERE rather than relying on the `.onChange(of:)` below.
                //
                // Field evidence (2026-08-13 device log): `auto-collapse` fired
                // 6 times while `[ThinkingCollapse] post` fired 0 times. The
                // observer never ran, because this write happens inside another
                // `onChange` handler in the same view update — SwiftUI compares
                // `isThinkingExpanded` before and after that update as a whole,
                // and the write is not observed as a transition. A manual tap is
                // its own update, which is why tapping to collapse always worked
                // and only the stream-end auto-collapse left a gap.
                //
                // Without the post, `SelfSizingCell`'s width-keyed dedup keeps
                // answering with the EXPANDED height (the cache the
                // `.thinkingBlockToggled` receiver exists to clear), so the pill
                // draws collapsed inside a frame still sized for the expanded
                // body — the blank strip under the first thinking block.
                //
                // Posting from both places is safe: the receiver only clears
                // caches and reconfigures, and a duplicate notification
                // re-measures to the same height.
                NotificationCenter.default.post(name: .thinkingBlockToggled,
                                                object: block.id)
            } else if !streaming {
                AppLogger(category: "ThinkingCollapse").info("[ThinkingCollapse] stream-end-skip block=\(block.id.uuidString.prefix(8)) userToggled=\(block.thinkingUserToggled) currentlyExpanded=\(block.isThinkingExpanded)")
            }
        }
        .onChange(of: block.isThinkingExpanded) { newValue in
            // Single source of truth for cell-height invalidation: fires
            // for BOTH manual taps and the stream-end auto-collapse path
            // above. Previously only the tap gesture posted this, so when
            // a long thinking block auto-collapsed at stream end, the
            // UICollectionView kept the expanded cell height (~300pt) and
            // rendered a tall empty gap below the pill — see 2026-05-17
            // screenshot bug.
            AppLogger(category: "ThinkingCollapse").info("[ThinkingCollapse] post block=\(block.id.uuidString.prefix(8)) expanded=\(newValue) userToggled=\(block.thinkingUserToggled) streaming=\(isStreaming)")
            NotificationCenter.default.post(name: .thinkingBlockToggled,
                                            object: block.id)
        }
    }
}
