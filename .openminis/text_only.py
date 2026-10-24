"""Declared Arabic/text-only adapters; keep the original chat renderer intact."""
import json
import re
import shutil
from pathlib import Path


def exact(path, old, new):
    source = path.read_text()
    if source.count(old) != 1:
        raise RuntimeError(f"Text-only adapter changed upstream: {path}: {old[:70]}")
    path.write_text(source.replace(old, new))


def apply(source: Path, browser: Path):
    original = source / "Providers/Voice/VoiceActivityDetector.swift"
    code = original.read_text()
    protocols = code[code.index("enum SegmentEndReason"):code.index("// MARK: - VoiceActivityDetector")]
    configuration = code[code.index("    struct Configuration {"):code.index("    private let configuration:")]
    original.write_text('import Foundation\n' + protocols + '''
// The text edition has no microphone capture, VAD binary or ONNX models.
final class VoiceActivityDetector: NSObject {
    weak var delegate: VoiceActivityDelegate?
    private(set) var isRunning = false
    private(set) var isSpeaking = false
    var maxSegmentSeconds: Double = 60
    var currentSessionId: String? { nil }
''' + configuration + '''
    init(configuration: Configuration = Configuration()) { super.init() }
    func start() throws { throw NSError(domain: "ZeusTextEdition", code: 1,
        userInfo: [NSLocalizedDescriptionKey: "الإدخال الصوتي غير متاح في النسخة النصية."]) }
    func stop() {}
    func flush() {}
    func flushRawFallback() -> Bool { false }
    var runningDuration: TimeInterval { 0 }
    var hasRawFallbackAudio: Bool { false }
    enum MicrophonePermission { case granted, denied, undetermined }
    static var microphonePermission: MicrophonePermission { .denied }
    static func requestMicrophonePermission() async -> Bool { false }
}
''')
    for name in ("iSH/ISHKernel.m", "MinisApp-Bridging-Header.h"):
        path = source / name
        path.write_text(path.read_text().replace('#import "FFmpegOffload.h"', '// FFmpeg omitted in the text edition.').replace('    ffmpeg_offload_register();', '    // No bundled FFmpeg offload in the text edition.'))
    # NLTokenizer is the existing fallback when Jieba is unavailable. Avoid
    # linking a dictionary implementation for a removed speech-correction path.
    (source / "Shared/JiebaWrapper.mm").write_text('''#import "JiebaWrapper.h"
@implementation JiebaWrapper
+ (instancetype)shared { static JiebaWrapper *value; static dispatch_once_t once;
    dispatch_once(&once, ^{ value = [JiebaWrapper new]; }); return value; }
- (BOOL)isReady { return NO; }
- (NSArray<NSString *> *)segment:(NSString *)text { return @[]; }
- (NSArray<NSString *> *)segmentForSearch:(NSString *)text { return @[]; }
- (NSArray<NSArray<NSString *> *> *)posTag:(NSString *)text { return @[]; }
@end
''')
    chat = source / "Views/Chat/AIChatView.swift"
    exact(chat, 'get { voiceMode.isVoiceActive }\n        nonmutating set { voiceMode.isVoiceActive = newValue }',
          'get { false }\n        nonmutating set { voiceMode.isVoiceActive = false }')
    exact(chat, '            micButtonContainer\n', '            // Text edition: no microphone control.\n')
    exact(chat, 'matching: .any(of: [.images, .videos])', 'matching: .images')
    exact(chat, '.onDrop(of: [.image, .movie, .fileURL, .data]', '.onDrop(of: [.image, .fileURL, .data]')
    attachments = source / "Agent/Chat/AIChatViewModel+Attachments.swift"
    exact(attachments, '    func finalizeVideoPlaceholder(id: UUID, from sourceURL: URL, originalDate: Date? = nil) {',
          '    func finalizeVideoPlaceholder(id: UUID, from sourceURL: URL, originalDate: Date? = nil) {\n        markPlaceholderFailed(id: id); return\n        /* Disabled media conversion in the text edition. */')
    for signature, filename in [
        ('    func addFileAttachment(from sourceURL: URL, originalDate: Date? = nil) {', 'sourceURL'),
        ('    func addDataAttachment(data: Data, fileName: String) {', 'URL(fileURLWithPath: fileName)')
    ]:
        guard = '\n        if ["mp4", "mov", "m4v", "webm", "mp3", "m4a", "wav", "ogg", "aac", "flac"].contains(' + filename + '.pathExtension.lowercased()) {\n            appendSystemInfo("المرفقات الصوتية والفيديو غير متاحة في النسخة النصية.", icon: "doc.badge.ellipsis"); return\n        }'
        exact(attachments, signature, signature + guard)
    output = source / "Providers/Voice/VoiceOutputPlayer.swift"
    exact(output, 'get { UserDefaults.standard.bool(forKey: key) }\n        set { UserDefaults.standard.set(newValue, forKey: key) }',
          'get { false }\n        set { UserDefaults.standard.set(false, forKey: key) }')
    speech = source / "Agent/Speech/SpeechRecognitionManager.swift"
    exact(speech, 'UserDefaults.standard.string(forKey: inputModePreferenceKey) == "voice"', 'false // Text edition always opens the keyboard.')
    markdown = source / "Views/Chat/SelectableMarkdownView.swift"
    text = markdown.read_text()
    start = text.index('        // TTS actions — read selected or read all via VoiceOutputPlayer.')
    end = text.index('        // Remove system Speak menu if present.', start)
    text = text[:start] + text[end:]
    start = text.index('        // [T-selection-menu-minis-tts] Minis-owned read-aloud entries.')
    end = text.index('        let extrasMenu =', start)
    markdown.write_text(text[:start] + text[end:])
    providers = source / "Views/Providers/ProviderInstancesView.swift"
    exact(providers, 'let shadows = store.shadowVoiceProviders()', 'let shadows: [ProviderConfigStore.ShadowVoiceProvider] = []')
    appearance = source / "Views/ContentView.swift"
    text = appearance.read_text()
    text = re.sub(r'private let supportedLanguages: \[LanguageOption\] = \[.*?\n\]',
                  'private let supportedLanguages: [LanguageOption] = [\n    LanguageOption(id: "ar", name: "العربية", flag: "🇸🇦"),\n]', text, count=1, flags=re.S)
    appearance.write_text(text)
    # Arabic resources only, while keeping source keys intact for compatibility.
    for path in source.rglob("*.xcstrings"):
        document = json.loads(path.read_text())
        for entry in document.get("strings", {}).values():
            translations = entry.get("localizations", {})
            entry["localizations"] = {"ar": translations["ar"]} if "ar" in translations else {}
        path.write_text(json.dumps(document, ensure_ascii=False, indent=2) + "\n")

