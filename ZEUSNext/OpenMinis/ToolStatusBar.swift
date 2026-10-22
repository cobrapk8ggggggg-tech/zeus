import SwiftUI
struct ToolStatusBarSurface: ViewModifier {
    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: 10, style: .continuous)
    }

    func body(content: Content) -> some View {
        if #available(iOS 26.0, *) {
            content.glassEffect(.regular, in: shape)
        } else {
            content
                .background(Color(UIColor { $0.userInterfaceStyle == .dark ? UIColor(white: 0.15, alpha: 1) : UIColor.systemBackground }))
                .clipShape(RoundedRectangle(cornerRadius: 10))
                .overlay(
                    RoundedRectangle(cornerRadius: 10)
                        .stroke(Color(UIColor.separator).opacity(0.3), lineWidth: 0.5)
                )
                .shadow(color: Color(UIColor { $0.userInterfaceStyle == .dark ? UIColor(white: 0.08, alpha: 0.75) : UIColor(white: 0, alpha: 0.12) }), radius: 8, x: 0, y: 4)
        }
    }
}

struct ToolStatusBar: View {
    @ObservedObject var block: AssistantBlock
    let toolBlocks: [AssistantBlock]
    let displayedIdx: Int
    @Binding var expanded: Bool
    @Binding var selectedIdx: Int?
    var leadingInset: CGFloat = 0

    var body: some View {
        HStack(spacing: 2) {
            statusIcon

            // [T-step-timestamp v2 aa8b1128] Inline HH:mm:ss prefix removed
            // — see ToolLiveSheet.sheetNavBar for the new "start +
            // elapsed" display, surfaced only inside the tapped-open
            // detail sheet so the always-visible status bar stays clean.

            Text(displayTitle)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(ChatColors.secondaryText)
                .lineLimit(1)
                .truncationMode(.tail)
                .contentShape(Rectangle())
                .onTapGesture { withAnimation { expanded = true } }

            Spacer(minLength: 1)

            if toolBlocks.count > 1 {
                HStack(spacing: 2) {
                    Button {
                        let prev = (selectedIdx ?? displayedIdx) - 1
                        if prev >= 0 { withAnimation { selectedIdx = prev } }
                    } label: {
                        Image(systemName: "chevron.left")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(displayedIdx > 0 ? ChatColors.primaryText : ChatColors.tertiaryText)
                            .frame(width: 20, height: 20)
                            .contentShape(Rectangle())
                    }
                    .disabled(displayedIdx <= 0)

                    Text("\(displayedIdx + 1)/\(toolBlocks.count)")
                        .font(.system(size: 11, weight: .medium, design: .monospaced))
                        .foregroundStyle(ChatColors.secondaryText)

                    Button {
                        let next = (selectedIdx ?? displayedIdx) + 1
                        if next < toolBlocks.count { withAnimation { selectedIdx = next } }
                    } label: {
                        Image(systemName: "chevron.right")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(displayedIdx < toolBlocks.count - 1 ? ChatColors.primaryText : ChatColors.tertiaryText)
                            .frame(width: 20, height: 20)
                            .contentShape(Rectangle())
                    }
                    .disabled(displayedIdx >= toolBlocks.count - 1)
                }
            }
        }
        .padding(.leading, leadingInset > 0 ? leadingInset : 12)
        .padding(.trailing, 12)
        .padding(.vertical, 5)
        .frame(minHeight: 38)
        .frame(maxWidth: .infinity)
        .modifier(ToolStatusBarSurface())
    }

    @ViewBuilder
    private var statusIcon: some View {
        switch block.toolStatus {
        case .streaming, .running:
            ProgressView()
                .scaleEffect(0.6)
                .frame(width: 16, height: 16)
        case .success:
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 15))
                .foregroundStyle(.green)
        case .failed:
            Image(systemName: "xmark.circle.fill")
                .font(.system(size: 15))
                .foregroundStyle(.red)
        case .cancelled:
            Image(systemName: "stop.circle.fill")
                .font(.system(size: 15))
                .foregroundStyle(.yellow)
        case nil:
            EmptyView()
        }
    }

    private var displayTitle: String {
        if let s = block.toolSummary, !s.isEmpty { return s }
        return block.toolDescription
    }
}
