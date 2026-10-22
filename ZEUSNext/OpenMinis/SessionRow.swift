// Adapted from OpenMinis ContentView.swift SessionRow. Browser sessions provide
// the title, preview, timestamp and running state in place of ChatStore.
import SwiftUI

struct OpenMinisSessionRow: View {
    let session: AgentSession
    let active: Bool
    @ObservedObject private var fontSettings = FontSettings.shared
    private var preview: String {
        guard let message = session.messages.last else { return "No messages yet" }
        return message.user ? message.content : message.blocks.filter { $0.kind == "text" }.map(\.content).joined(separator: " ")
    }
    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "bubble.left.fill")
                .font(.system(size: 18)).foregroundStyle(.gray)
                .frame(width: 44, height: 44)
                .background(Color.gray.opacity(0.18)).clipShape(Circle())
                .overlay { if active { ProgressView().tint(.gray).frame(width: 42, height: 42) } }
            VStack(alignment: .leading, spacing: 4) {
                Text(session.title).font(.system(size: fontSettings.scaledApp(16), weight: .semibold)).foregroundStyle(Color(UIColor.label)).lineLimit(1)
                Text(preview).font(.system(size: fontSettings.scaledApp(14))).foregroundStyle(Color(UIColor.secondaryLabel)).lineLimit(1)
            }
            Spacer(minLength: 1)
            VStack(alignment: .trailing, spacing: 4) {
                Text(Self.relativeDate(session.updated)).font(.system(size: fontSettings.scaledApp(13))).foregroundStyle(Color(UIColor.tertiaryLabel))
                if session.pinned { Image(systemName: "pin.fill").font(.system(size: 10)).foregroundStyle(Color(UIColor.tertiaryLabel)) }
            }
        }.padding(.horizontal, 16).padding(.vertical, 12).contentShape(Rectangle())
    }
    private static func relativeDate(_ date: Date) -> String {
        let now = Date(), calendar = Calendar.current, seconds = Int(now.timeIntervalSince(date))
        if calendar.isDateInToday(date) {
            if seconds < 60 { return String(localized: "Just now") }
            else if seconds < 3600 { return String(localized: "\(seconds / 60) min ago") }
            else { return String(localized: "\(seconds / 3600) hr ago") }
        } else if calendar.isDateInYesterday(date) { return String(localized: "Yesterday") }
        else { let days = calendar.dateComponents([.day], from: date, to: now).day ?? 7; let formatter = DateFormatter(); formatter.setLocalizedDateFormatFromTemplate(days < 7 ? "EEEE" : "Md"); return formatter.string(from: date) }
    }
}
