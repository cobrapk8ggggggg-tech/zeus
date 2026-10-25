import SwiftUI
import ZEUSBrowser

/// A single movable handle keeps shell controls away from the conversation.
/// Its normalized physical position survives split/fullscreen and RTL changes.
struct ZeusAgentControls: View {
    let presentation: NativeAssistantPresentation
    @AppStorage("zeus.agentControls.x") private var x = 0.08
    @AppStorage("zeus.agentControls.y") private var y = 0.45
    @AppStorage("zeus.agentControls.collapsed") private var collapsed = true
    @GestureState private var translation = CGSize.zero
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        GeometryReader { geometry in
            let width: CGFloat = 48
            let height: CGFloat = collapsed ? 48 : (presentation.canResize ? 144 : 96)
            let area = geometry.size
            let center = CGPoint(x: clamp(CGFloat(x) * area.width + translation.width, width / 2 + 6, area.width - width / 2 - 6),
                                 y: clamp(CGFloat(y) * area.height + translation.height, height / 2 + 8, area.height - height / 2 - 8))
            VStack(spacing: 0) {
                Button { withAnimation(reduceMotion ? nil : .spring(response: 0.3, dampingFraction: 0.8)) { collapsed.toggle() } } label: {
                    Image(systemName: collapsed ? "ellipsis" : "minus").frame(width: 48, height: 48).contentShape(Rectangle())
                }.accessibilityLabel(collapsed ? "إظهار أزرار الوكيل؛ اسحب لتغيير موضعها" : "طي أزرار الوكيل")
                    .accessibilityIdentifier("agentControlsHandle")
                if !collapsed {
                    if presentation.canResize {
                        Button(action: presentation.resize) {
                            Image(systemName: presentation.fullScreen ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right").frame(width: 48, height: 48)
                        }.accessibilityLabel(presentation.fullScreen ? "استعادة التقسيم" : "تكبير الوكيل").accessibilityIdentifier("agentResizeButton")
                    }
                    Button(action: presentation.close) { Image(systemName: "xmark").frame(width: 48, height: 48) }
                        .accessibilityLabel("العودة إلى المتصفح").accessibilityIdentifier("agentCloseButton")
                }
            }
            .buttonStyle(.plain).font(.system(size: 16, weight: .semibold))
            .foregroundStyle(.primary).background(.regularMaterial, in: Capsule())
            .overlay(Capsule().strokeBorder(.primary.opacity(0.12), lineWidth: 0.5))
            .shadow(color: .black.opacity(0.12), radius: 8, y: 3)
            .position(center)
            .simultaneousGesture(DragGesture(minimumDistance: 8).updating($translation) { value, state, _ in state = value.translation }.onEnded { value in
                guard area.width > 0, area.height > 0 else { return }
                x = Double(clamp(CGFloat(x) * area.width + value.translation.width, 30, area.width - 30) / area.width)
                y = Double(clamp(CGFloat(y) * area.height + value.translation.height, height / 2 + 8, area.height - height / 2 - 8) / area.height)
            })
            .accessibilityAction(named: "إعادة موضع الأزرار") { x = 0.08; y = 0.45 }
        }.environment(\.layoutDirection, .leftToRight)
    }
    private func clamp(_ value: CGFloat, _ lower: CGFloat, _ upper: CGFloat) -> CGFloat { min(max(value, lower), max(lower, upper)) }
}
