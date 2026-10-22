import SwiftUI
// Browser adapter for the original OpenMinis tool inspector chrome and step navigation.
struct ToolLiveSheet: View {
    @ObservedObject var vm: BrowserAgent
    @Environment(\.dismiss) private var dismiss
    @State private var currentIdx: Int
    init(vm: BrowserAgent, selected: AssistantBlock) {
        self.vm = vm
        let blocks = vm.messages.flatMap(\.blocks).filter { $0.toolStatus != nil }
        _currentIdx = State(initialValue: blocks.firstIndex(where: { $0.id == selected.id }) ?? 0)
    }
    private var toolBlocks: [AssistantBlock] { vm.messages.flatMap(\.blocks).filter { $0.toolStatus != nil } }
    private var block: AssistantBlock { toolBlocks[min(max(0,currentIdx),toolBlocks.count-1)] }
    private var isLive: Bool { block.toolStatus == .running }
    private var toolTitle: String { block.toolDescription }
    private var toolSubtitle: String { block.toolUseId ?? "" }
    static func formatDuration(_ value: Double) -> String { String(format: "%.1fs", value) }
    var body: some View {
        Group {
            if !toolBlocks.isEmpty {
                VStack(spacing: 0) {
                    HStack {
                        Button { dismiss() } label: { Image(systemName: "xmark").font(.system(size:14,weight:.semibold)).frame(width:32,height:32).background(ChatColors.secondaryBg,in:Circle()) }
                        Spacer();Text("ZEUS Computer").font(.system(size:15,weight:.semibold));Spacer();Image(systemName:"globe").frame(width:32,height:32)
                    }.padding(16)
                    Divider()
                    ScrollView {
                        VStack(alignment:.leading,spacing:16) {
                            if let path=block.imageFilePath,let image=UIImage(contentsOfFile:path) { ZoomableImageView(image:image).frame(height:250) }
                            if let args=block.toolInputArgs { SelectableMarkdownView(markdown:"```json\n"+args+"\n```") }
                            SelectableMarkdownView(markdown:block.content.isEmpty ? "جارٍ التنفيذ…" : "```text\n" + sanitizeForDisplay(String(block.content.prefix(50_000))) + "\n```")
                        }.padding(16)
                    }.frame(maxWidth:.infinity,maxHeight:.infinity)
                    bottomBar
                }
            }
        }.frame(maxWidth:.infinity,maxHeight:.infinity).background(Color(UIColor.systemGroupedBackground)).preferredColorScheme(.dark).presentationDragIndicator(.hidden)
    }
    private var bottomBar: some View {
        VStack(spacing: 0) {
            Divider()

            // Tool info row
            HStack(spacing: 8) {
                statusIcon
                VStack(alignment: .leading, spacing: 1) {
                    Text(toolTitle)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(ChatColors.primaryText)
                        .lineLimit(1)
                    Text(toolSubtitle)
                        .font(.system(size: 11))
                        .foregroundStyle(ChatColors.secondaryText)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                Spacer()
                // [T-step-timestamp v3-fix aa8b1128] Trailing column in the
                // detail-view bottom bar: duration on top, the step's
                // HH:mm:ss start time on a smaller / lighter line right
                // beneath it. This is where the user goes to inspect a
                // single step, so the timestamp lives here instead of on
                // every pill in the message list.
                let dur = block.toolDuration
                if dur != nil || block.toolStartTime != nil {
                    VStack(alignment: .trailing, spacing: 1) {
                        if let dur {
                            Text(Self.formatDuration(dur))
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundStyle(ChatColors.tertiaryText)
                        }
                        if let started = block.toolStartTime {
                            Text(MinisStepTimestampFormatter.string(from: started))
                                .font(.system(size: 9, design: .monospaced))
                                .foregroundStyle(ChatColors.tertiaryText.opacity(0.75))
                        }
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)

            // Navigation row: |< ... Live ... >|
            HStack {
                Button {
                    if currentIdx > 0 { withAnimation { currentIdx -= 1 } }
                } label: {
                    Image(systemName: "backward.end.fill")
                        .font(.system(size: 18))
                        .foregroundStyle(currentIdx > 0 ? ChatColors.primaryText : ChatColors.tertiaryText)
                }
                .disabled(currentIdx <= 0)

                Spacer()

                if isLive {
                    HStack(spacing: 4) {
                        Circle()
                            .fill(.green)
                            .frame(width: 7, height: 7)
                        Text("Live")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(ChatColors.primaryText)
                    }
                } else {
                    Text("\(currentIdx + 1) / \(toolBlocks.count)")
                        .font(.system(size: 13, weight: .medium, design: .monospaced))
                        .foregroundStyle(ChatColors.secondaryText)
                }

                Spacer()

                Button {
                    if currentIdx < toolBlocks.count - 1 { withAnimation { currentIdx += 1 } }
                } label: {
                    Image(systemName: "forward.end.fill")
                        .font(.system(size: 18))
                        .foregroundStyle(currentIdx < toolBlocks.count - 1 ? ChatColors.primaryText : ChatColors.tertiaryText)
                }
                .disabled(currentIdx >= toolBlocks.count - 1)
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 12)
        }
        .background(Color(UIColor.systemBackground))
    }

    @ViewBuilder
    private var statusIcon: some View {
        switch block.toolStatus {
        case .streaming, .running:
            ProgressView()
                .scaleEffect(0.7)
                .frame(width: 20, height: 20)
        case .success:
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 18))
                .foregroundStyle(.green)
        case .failed:
            Image(systemName: "xmark.circle.fill")
                .font(.system(size: 18))
                .foregroundStyle(.red)
        case .cancelled:
            Image(systemName: "stop.circle.fill")
                .font(.system(size: 18))
                .foregroundStyle(.yellow)
        case nil:
            EmptyView()
        }
    }

}

enum MinisStepTimestampFormatter {
    private static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "HH:mm:ss"
        return f
    }()

    static func string(from date: Date) -> String {
        formatter.string(from: date)
    }

    /// [T-step-timestamp v2 aa8b1128] Short "elapsed-or-final duration"
    /// label for the tool detail header. Format:
    ///   < 60s   → "3s"
    ///   < 1h    → "2m30s" (drops the seconds suffix when seconds == 0)
    ///   ≥ 1h    → "1h12m"
    /// When `stillRunning` is true the result is suffixed "…" so the
    /// header reads "12s…" while the tool is in flight.
    /// Negative values clamp to 0; non-finite values render as "0s".
    static func duration(seconds: TimeInterval, stillRunning: Bool = false) -> String {
        let safe = (seconds.isFinite && seconds > 0) ? seconds : 0
        let totalSecs = Int(safe.rounded())
        let base: String
        if totalSecs < 60 {
            base = "\(totalSecs)s"
        } else if totalSecs < 3600 {
            let m = totalSecs / 60
            let s = totalSecs % 60
            base = s == 0 ? "\(m)m" : "\(m)m\(s)s"
        } else {
            let h = totalSecs / 3600
            let m = (totalSecs % 3600) / 60
            base = m == 0 ? "\(h)h" : "\(h)h\(m)m"
        }
        return stillRunning ? "\(base)…" : base
    }
}
