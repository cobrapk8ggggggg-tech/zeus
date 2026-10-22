import SwiftUI
// Adapted from OpenMinis AssistantBlockView.swift: native browser executor replaces Linux tools.
struct ToolCapsuleView: View {
    @ObservedObject var block: AssistantBlock
    let icon: String
    let accentColor: Color
    var onStop: (() -> Void)?
    @Binding var detailBlock: AssistantBlock?
    @State private var dotsActive = false
    private var displayText: String { block.toolSummary ?? block.toolDescription }
    private var isStreaming: Bool { if case .streaming = block.toolStatus { return true }; return false }
    private var isActive: Bool { switch block.toolStatus { case .running, .streaming: return true; default: return false } }
    var body: some View {
        HStack {
            HStack(spacing: 8) {
                // Status indicator / icon
                statusOrIcon

                // Description text with bouncing dots during streaming
                HStack(spacing: 0) {
                    Text(displayText)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(ChatColors.primaryText)
                        .lineLimit(1)
                    if isStreaming {
                        ForEach(0..<3, id: \.self) { i in
                            Text(".")
                                .font(.system(size: 13, weight: .medium))
                                .foregroundStyle(ChatColors.primaryText)
                                .offset(y: dotsActive ? -2 : 1)
                                .animation(
                                    .easeInOut(duration: 0.35)
                                        .repeatForever(autoreverses: true)
                                        .delay(Double(i) * 0.12),
                                    value: dotsActive
                                )
                        }
                    }
                }
                .lineLimit(1)

                // Execution duration (shown after completion). The HH:mm:ss
                // start time is surfaced inside the detail view's bottom bar
                // (ToolLiveSheet.bottomBar) instead of here — the inline
                // pill list stays clean.
                if let dur = durationText {
                    Text(dur)
                        .font(.system(size: 11, weight: .regular, design: .monospaced))
                        .foregroundStyle(ChatColors.tertiaryText)
                }

                // Stop button for running commands
                if case .running = block.toolStatus {
                    Button {
                        onStop?()
                    } label: {
                        // Visual: 10×10 red square unchanged. Hit area enlarged to
                        // 24×24 via an expanded contentShape, while the negative
                        // padding pins the *layout* footprint back to 18×18 so the
                        // capsule width/height is identical to before.
                        RoundedRectangle(cornerRadius: 2)
                            .fill(.red)
                            .frame(width: 10, height: 10)
                            .frame(width: 24, height: 24)
                            .contentShape(Rectangle())
                            .padding(-3)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 12)
            .frame(height: 36)
            .background(Color(UIColor.systemGray6))
            .clipShape(Capsule())
            .overlay(
                Group {
                    if isActive {
                        ShimmerOverlay()
                            .clipShape(Capsule())
                            .allowsHitTesting(false)
                    }
                }
            )
            .overlay(
                Capsule()
                    .stroke(ChatColors.toolBorder, lineWidth: 0.5)
            )
            .contentShape(Capsule())
            .onTapGesture {
                detailBlock = block
            }
            .contextMenu {
                Button("نسخ تفاصيل الأداة", systemImage: "doc.on.doc") { UIPasteboard.general.string = (block.toolInputArgs ?? "") + "\n" + block.content }
            }
            Spacer(minLength: 0)
        }.onAppear { dotsActive = true }
    }
    private var statusOrIcon: some View {
        Image(systemName: icon)
            .font(.system(size: 13))
            .foregroundStyle(iconColor)
    }

    private var iconColor: Color {
        switch block.toolStatus {
        case .success: return .green
        case .failed: return .red
        case .cancelled: return .yellow
        default: return accentColor
        }
    }

    /// Formatted execution duration (e.g. "1.2s", "45s", "2m 10s").
    private var durationText: String? {
        guard let dur = block.toolDuration else { return nil }
        if dur < 1 { return String(format: "%.1fs", dur) }
        if dur < 60 { return String(format: "%.0fs", dur) }
        let mins = Int(dur) / 60
        let secs = Int(dur) % 60
        return "\(mins)m \(secs)s"
    }

}
