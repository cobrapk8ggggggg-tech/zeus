import SwiftUI

/// Review existing durable task state, rather than a second model-generated
/// account of progress. Reading this view never resumes commands or writes.
struct ZeusTaskDashboard: View {
    struct Row: Identifiable {
        let id: String
        let state: ZeusAgentHarness.State
    }
    @State private var rows: [Row] = []
    @State private var query = ""
    var body: some View {
        List {
            if rows.isEmpty { Text("لا توجد مهام محفوظة بعد").foregroundStyle(.secondary) }
            ForEach(rows.filter { query.isEmpty || $0.state.goal.localizedCaseInsensitiveContains(query) }) { row in
                NavigationLink { ZeusTaskDetail(state: row.state) } label: {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(row.state.goal.isEmpty ? "مهمة بلا عنوان" : row.state.goal).lineLimit(2)
                        HStack {
                            Text(Self.status(row.state.status))
                            Spacer()
                            Text("\(row.state.plan.filter { $0.status == "completed" }.count) / \(row.state.plan.count)")
                        }.font(.caption).foregroundStyle(.secondary)
                        Text(row.state.updated, style: .relative).font(.caption2).foregroundStyle(.secondary)
                    }.padding(.vertical, 4)
                }
            }
        }
        .navigationTitle("متابعة المشاريع والمهام")
        .searchable(text: $query, prompt: "بحث في المهام")
        .task { await refresh() }.refreshable { await refresh() }
    }
    @MainActor private func refresh() async {
        let directory = ZeusAgentHarness.shared.taskStorageDirectory
        let items = await Task.detached(priority: .utility) {
            let urls = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
            return urls.filter { $0.pathExtension == "json" }.compactMap { url -> Row? in
                guard let data = try? Data(contentsOf: url), let state = try? JSONDecoder().decode(ZeusAgentHarness.State.self, from: data) else { return nil }
                return Row(id: url.lastPathComponent, state: state)
            }.sorted { $0.state.updated > $1.state.updated }
        }.value
        rows = items
    }
    static func status(_ value: String) -> String {
        switch value {
        case "completed": return "مكتملة"
        case "running": return "قيد التنفيذ أو محفوظة للاستئناف"
        case "blocked": return "متوقفة بسبب عائق"
        case "waiting_user": return "بانتظار المتابعة"
        default: return value
        }
    }
}

private struct ZeusTaskDetail: View {
    let state: ZeusAgentHarness.State
    var body: some View {
        List {
            Section("الهدف والحالة") {
                Text(state.goal).textSelection(.enabled)
                Text(ZeusTaskDashboard.status(state.status))
                Text(state.updated, style: .date)
            }
            Section("المراحل") {
                ForEach(Array(state.plan.enumerated()), id: \.offset) { _, step in
                    Label(step.step, systemImage: step.status == "completed" ? "checkmark.circle.fill" : step.status == "in_progress" ? "arrow.trianglehead.2.clockwise" : "circle")
                        .foregroundStyle(step.status == "completed" ? .green : .primary)
                }
            }
            if !state.checkpoint.isEmpty { Section("آخر نقطة استئناف") { Text(state.checkpoint).textSelection(.enabled) } }
            if let notes = state.project?.notes, !notes.isEmpty {
                Section("مستجدات المشروع") {
                    ForEach(Array(notes.enumerated()), id: \.offset) { _, note in
                        VStack(alignment: .leading) { Text(note.text); Text(note.date, style: .relative).font(.caption).foregroundStyle(.secondary) }
                    }
                }
            }
            Section {
                ForEach(Array((state.checks + (state.remoteChecks ?? [])).enumerated()), id: \.offset) { _, check in
                    DisclosureGroup {
                        Text(check.command).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                        Text(check.output).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                    } label: {
                        VStack(alignment: .leading) {
                            Label(check.exitCode == 0 ? "نجح الفحص" : "فشل الفحص: \(check.exitCode)", systemImage: check.exitCode == 0 ? "checkmark.circle" : "xmark.circle")
                            Text(check.generation == state.generation ? "ينطبق على آخر تعديلات مسجلة" : "نتيجة سابقة؛ يلزم فحص التعديلات الأحدث").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            } header: { Text("نتائج التحقق الفعلية") } footer: {
                Text("هذه سجلات محفوظة، وليست دليلاً على استمرار التطبيق في الخلفية. للمتابعة افتح المحادثة الأصلية؛ لا تعيد هذه الشاشة أي أمر تلقائياً.")
            }
        }.navigationTitle("تفاصيل المهمة").navigationBarTitleDisplayMode(.inline)
    }
}
