import SwiftUI
struct EmptyChatDirectoryTimeline: View {
    var onBrowse: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "lightbulb")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(ChatColors.secondaryText)
                Text("سياق المتصفح")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(ChatColors.secondaryText)
            }
            Text("كل محادثة تحتفظ برسائلها ومرفقاتها وخطوات أدواتها داخل هذا البروفايل.")
                .font(.system(size: 12))
                .foregroundStyle(ChatColors.primaryText)
                .fixedSize(horizontal: false, vertical: true)
            Text("يستخدم الوكيل الصفحة والتبويبات والذاكرة وفق الصلاحيات التي تختارها.")
                .font(.system(size: 12))
                .foregroundStyle(ChatColors.primaryText)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button(action: onBrowse) {
                    HStack(spacing: 4) {
                        Image(systemName: "folder")
                            .font(.system(size: 10, weight: .semibold))
                        Text("إعدادات السياق")
                            .font(.system(size: 11, weight: .semibold))
                    }
                    .foregroundStyle(ChatColors.primaryText)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(
                        Capsule().fill(ChatColors.secondaryBg)
                    )
                    .overlay(
                        Capsule().stroke(ChatColors.toolBorder, lineWidth: 0.5)
                    )
                }
                .buttonStyle(.plain)
            }
            .padding(.top, 2)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(maxWidth: 460, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(ChatColors.secondaryBg.opacity(0.6))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(ChatColors.toolBorder, lineWidth: 0.5)
        )
        .fixedSize(horizontal: false, vertical: true)
    }
}
