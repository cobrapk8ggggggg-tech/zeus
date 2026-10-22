import SwiftUI
struct OffloadPermissionDialogContent: View {
    let request: AgentApproval
    let respond: (Bool, Bool) -> Void

    var body: some View {
        VStack(spacing: 0) {
            // Scrollable content. Long argument lists previously stretched the
            // outer VStack past the sheet height and pushed the Allow / Deny
            // buttons below the bottom edge with no way to scroll to them.
            // Pinning the buttons in a separate sibling and wrapping the rest
            // in a ScrollView guarantees the action row is always visible.
            ScrollView {
                VStack(spacing: 0) {
                    // Header
                    VStack(spacing: 8) {
                        Image(systemName: "shield.lefthalf.filled")
                            .font(.system(size: 36))
                            .foregroundStyle(.orange)

                        Text("Permission Request")
                            .font(.title3.bold())

                        Text("The agent wants to use **\(BrowserAgentTools.title(request.call.name))**")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    }
                    .padding(.top, 24)
                    .padding(.bottom, 16)

                    // Description
                    if !request.detail.isEmpty {
                        Text(request.detail)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 20)
                            .padding(.bottom, 12)
                    }

                    // Arguments
                    let args = request.call.object.keys.sorted().map { (key: $0, value: String(describing: request.call.object[$0] ?? "")) }
                    if !args.isEmpty {
                        VStack(spacing: 0) {
                            ForEach(Array(args.enumerated()), id: \.offset) { idx, arg in
                                HStack {
                                    Text(arg.key)
                                        .font(.footnote.bold())
                                        .foregroundStyle(.secondary)
                                        .frame(width: 80, alignment: .trailing)
                                    Text(arg.value)
                                        .font(.footnote.monospaced())
                                        .lineLimit(2)
                                    Spacer()
                                }
                                .padding(.horizontal, 20)
                                .padding(.vertical, 8)
                                if idx < args.count - 1 {
                                    Divider().padding(.leading, 108)
                                }
                            }
                        }
                        .background(Color(.secondarySystemGroupedBackground))
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                        .padding(.horizontal, 20)
                        .padding(.bottom, 12)
                    }
                }
            }

            // Buttons — pinned to the bottom of the sheet, outside the
            // ScrollView, so they stay tappable even with very long arg lists.
            VStack(spacing: 10) {
                Button {
                    respond(true, false)
                } label: {
                    Text("هذه المرة")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                }
                .buttonStyle(.borderedProminent)
                .tint(.blue)

                if request.allowAlways {
                    Button("السماح دائمًا لهذه الأداة على هذا الموقع") { respond(true, true) }
                        .font(.subheadline.weight(.semibold)).frame(maxWidth: .infinity).padding(.vertical, 10).buttonStyle(.bordered)
                }
                Button {
                    respond(false, false)
                } label: {
                    Text("رفض")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                }
                .buttonStyle(.borderedProminent)
                .tint(.red)
            }
            .padding(.horizontal, 20)
            .padding(.top, 12)
            .padding(.bottom, 30)
            .background(Color(.systemGroupedBackground))
        }
        .background(Color(.systemGroupedBackground))
    }
}
