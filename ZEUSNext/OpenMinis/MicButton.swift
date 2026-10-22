import SwiftUI
struct MicButton: View {
    @ObservedObject var speechManager: SpeechRecognitionManager
    @Binding var inputFocused: Bool
    /// Opens the voice-input (VAD) panel. The mic button no longer drives the
    /// in-bar SFSpeech live dictation directly — the panel (with the configured
    /// ASR provider, or the offline System fallback) is the single voice entry
    /// point. The SpeechRecognitionManager path stays in place but is no longer
    /// triggered from here.
    var onTap: () -> Void = {}
    /// True while inline voice mode is active — the button flips to a "T" glyph
    /// that switches back to text input.
    var isVoiceActive: Bool = false
    /// Press feedback for the custom-gesture button.
    @State private var micPressed = false

    private static let diameter: CGFloat = 34

    var body: some View {
        // NOT a Button: SwiftUI's Button has a generous system touch-slop / touch-
        // up tolerance that fires when the finger lifts slightly outside, or moves
        // a little during a scroll/drag — which made this toggle very easy to
        // mis-tap. We use a DragGesture(minimumDistance: 0) and only activate when
        // BOTH the press and release land inside the circle AND movement is tiny.
        // In voice mode: a keyboard glyph = switch back to text input. The keyboard
        // glyph is wider than the mic, so render it ~4pt smaller for parity.
        Image(systemName: isVoiceActive ? "keyboard" : "mic")
            .font(.system(size: isVoiceActive ? 15 : 18, weight: .medium))
            .foregroundStyle(ChatColors.secondaryText)
            .frame(width: Self.diameter, height: Self.diameter)
            .background(ChatColors.inputIconBg)
            .clipShape(Circle())
            .overlay(Circle().stroke(ChatColors.inputIconBorder, lineWidth: 0.5))
            .scaleEffect(micPressed ? 0.9 : 1.0)
            .contentShape(Circle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        micPressed = Self.isInside(value.location)
                    }
                    .onEnded { value in
                        let started = Self.isInside(value.startLocation)
                        let ended = Self.isInside(value.location)
                        let moved = hypot(value.translation.width, value.translation.height)
                        micPressed = false
                        guard started, ended, moved < 10 else { return }
                        inputFocused = false
                        onTap()
                    }
            )
            .accessibilityAddTraits(.isButton)
            .accessibilityLabel(isVoiceActive
                ? Text("Switch to text input", comment: "Mic button exits voice mode")
                : Text("Voice input", comment: "Mic button opens voice panel"))
    }

    /// Whether a point (in the button's local space) is within the visible circle.
    private static func isInside(_ p: CGPoint) -> Bool {
        let r = diameter / 2
        let dx = p.x - r, dy = p.y - r
        return (dx * dx + dy * dy) <= r * r
    }
}

// MARK: - Speech Language Picker Sheet

struct SpeechLanguagePickerSheet: View {
    @ObservedObject var speechManager: SpeechRecognitionManager
    @Environment(\.dismiss) private var dismiss
    @State private var searchText = ""

    private var filteredLocales: [Locale] {
        if searchText.isEmpty { return speechManager.availableLocales }
        let query = searchText.lowercased()
        return speechManager.availableLocales.filter { loc in
            let name = speechManager.displayName(for: loc).lowercased()
            let id = loc.identifier.lowercased()
            return name.contains(query) || id.contains(query)
        }
    }

    /// Indices where the preferred/non-preferred boundary lies for section headers.
    private var preferredCodes: Set<String> {
        Set(Locale.preferredLanguages.map { Locale(identifier: $0).language.languageCode?.identifier ?? "" })
    }

    var body: some View {
        NavigationStack {
            List {
                let preferred = filteredLocales.filter { preferredCodes.contains($0.language.languageCode?.identifier ?? "") }
                let others = filteredLocales.filter { !preferredCodes.contains($0.language.languageCode?.identifier ?? "") }

                if !preferred.isEmpty {
                    Section(String(localized: "Preferred", comment: "Section header for preferred speech languages")) {
                        ForEach(preferred, id: \.identifier) { loc in
                            languageRow(loc)
                        }
                    }
                }

                if !others.isEmpty {
                    Section(String(localized: "All Languages", comment: "Section header for all speech languages")) {
                        ForEach(others, id: \.identifier) { loc in
                            languageRow(loc)
                        }
                    }
                }
            }
            .searchable(text: $searchText, prompt: Text("Search Languages", comment: "Search field placeholder for speech language picker"))
            .navigationTitle(Text("Voice Language", comment: "Navigation title for speech language picker"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(String(localized: "Done", comment: "Dismiss speech language picker")) {
                        dismiss()
                    }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    private func languageRow(_ loc: Locale) -> some View {
        Button {
            speechManager.setLanguage(loc)
            dismiss()
        } label: {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(speechManager.displayName(for: loc))
                        .foregroundStyle(.primary)
                    Text(loc.identifier)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if loc.identifier == speechManager.locale.identifier {
                    Image(systemName: "checkmark")
                        .foregroundStyle(Color.accentColor)
                        .fontWeight(.semibold)
                }
            }
        }
    }
}
