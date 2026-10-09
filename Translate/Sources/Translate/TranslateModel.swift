import AVFoundation
import AppKit
import Combine
import DroppyKit
import Foundation

struct LanguageOption: Identifiable, Hashable, Sendable {
    let id: String
    let name: String
}

struct TranslationJob: Equatable, Sendable {
    let id = UUID()
    let text: String
    let source: String
    let target: String
}

struct PrepareRequest: Equatable, Sendable {
    let id = UUID()
    let source: String
    let target: String
}

enum PairInfo: Equatable {
    case unknown
    case ready
    case needsDownload
    case unsupported
}

/// One model for the whole droplet: the shelf widget and the settings pane
/// read and write the same state, and the languages persist through
/// `host.preferences`.
@MainActor
final class TranslateModel: ObservableObject {
    static let auto = "auto"

    enum Status: Equatable {
        case idle
        case translating
        case needsDownload
        case unsupported
        case undetected
        case sameLanguage
        case failed
        case osTooOld
    }

    @Published var input = ""
    @Published private(set) var output = ""
    @Published private(set) var status: Status = .idle
    @Published private(set) var detected: String?
    @Published private(set) var languages: [LanguageOption] = LanguageTools.fallback
    @Published private(set) var job: TranslationJob?
    @Published private(set) var prepare: PrepareRequest?
    @Published private(set) var pairInfo: PairInfo = .unknown

    @Published var sourceID: String = TranslateModel.auto {
        didSet {
            persist("source", sourceID)
            languageSelectionChanged()
        }
    }

    @Published var targetID: String = LanguageTools.systemLanguageID() {
        didSet {
            persist("target", targetID)
            languageSelectionChanged()
        }
    }

    @Published var liveTranslate = false {
        didSet { persist("live", liveTranslate) }
    }

    private var host: DropletHost?
    private var translateTask: Task<Void, Never>?
    private var watchdog: Task<Void, Never>?
    private var liveTask: Task<Void, Never>?
    private var loadTask: Task<Void, Never>?
    private let synthesizer = AVSpeechSynthesizer()

    // MARK: Lifecycle

    func attach(host: DropletHost) {
        // Read first, keep the host after: assigning the published values
        // below must not write the defaults back.
        let preferences = host.preferences
        sourceID = preferences.value(forKey: "source", default: Self.auto)
        targetID = preferences.value(forKey: "target", default: LanguageTools.systemLanguageID())
        liveTranslate = preferences.value(forKey: "live", default: false)
        self.host = host
        loadLanguages()
    }

    func teardown() {
        translateTask?.cancel()
        watchdog?.cancel()
        liveTask?.cancel()
        loadTask?.cancel()
        synthesizer.stopSpeaking(at: .immediate)
        job = nil
        prepare = nil
        status = .idle
        host = nil
    }

    // MARK: Translating

    func inputChanged() {
        liveTask?.cancel()
        guard liveTranslate, !trimmedInput.isEmpty else { return }
        liveTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(800))
            guard !Task.isCancelled else { return }
            self?.translate()
        }
    }

    func translate() {
        let text = trimmedInput
        guard !text.isEmpty else {
            output = ""
            detected = nil
            status = .idle
            return
        }
        guard #available(macOS 15.0, *) else {
            status = .osTooOld
            return
        }

        translateTask?.cancel()
        status = .translating
        let selectedSource = sourceID
        let target = targetID

        translateTask = Task { [weak self] in
            guard let self else { return }

            // Auto-detect on device, then hand the framework an explicit pair
            // so it never has to ask the user anything.
            let source: String
            if selectedSource == Self.auto {
                guard let guess = LanguageTools.detect(text) else {
                    detected = nil
                    status = .undetected
                    return
                }
                detected = guess
                source = guess
            } else {
                detected = nil
                source = selectedSource
            }

            if LanguageTools.isSameLanguage(source, target) {
                output = text
                status = .sameLanguage
                return
            }

            switch await TranslationBridge.pairStatus(source: source, target: target) {
            case .installed:
                guard !Task.isCancelled else { return }
                let newJob = TranslationJob(text: text, source: source, target: target)
                job = newJob
                startWatchdog(for: newJob.id)
            case .needsDownload:
                status = .needsDownload
            case .unsupported:
                status = .unsupported
            }
        }
    }

    func currentJob() -> TranslationJob? { job }

    func complete(jobID: UUID, text: String) {
        guard job?.id == jobID else { return }
        watchdog?.cancel()
        output = text
        status = .idle
        job = nil
    }

    func fail(jobID: UUID, message: String) {
        guard job?.id == jobID else { return }
        watchdog?.cancel()
        note(message)
        status = .failed
        job = nil
    }

    /// The shelf closing cancels the view's task; do not leave a spinner behind.
    func shelfDidDisappear() {
        guard status == .translating else { return }
        translateTask?.cancel()
        watchdog?.cancel()
        job = nil
        status = .idle
    }

    private func startWatchdog(for id: UUID) {
        watchdog?.cancel()
        watchdog = Task { [weak self] in
            try? await Task.sleep(for: .seconds(20))
            guard !Task.isCancelled else { return }
            self?.fail(jobID: id, message: "translation timed out")
        }
    }

    private func languageSelectionChanged() {
        status = .idle
        if !output.isEmpty { translate() }
    }

    private var trimmedInput: String {
        input.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: Languages

    func name(for id: String) -> String {
        languages.first { $0.id == id }?.name ?? LanguageTools.name(for: id)
    }

    var canSwap: Bool {
        sourceID != Self.auto || detected != nil
    }

    /// Source becomes target and the translation becomes the new text.
    func swapLanguages() {
        guard let newTarget = sourceID == Self.auto ? detected : sourceID else { return }
        let newSource = targetID
        let translated = output

        // Empty output first: the language observers re-translate only when
        // there is a translation on screen, and the swap does that once below.
        output = ""
        sourceID = newSource
        targetID = newTarget
        if !translated.isEmpty {
            input = translated
            translate()
        }
    }

    private func loadLanguages() {
        guard #available(macOS 15.0, *) else { return }
        loadTask?.cancel()
        loadTask = Task { [weak self] in
            let supported = await TranslationBridge.supportedLanguages()
            guard !Task.isCancelled, !supported.isEmpty else { return }
            self?.languages = supported
        }
    }

    // MARK: Offline languages (settings pane)

    /// The pair the settings pane downloads: the chosen source, or the
    /// system language when the source is automatic.
    private var preparedSource: String {
        sourceID == Self.auto ? LanguageTools.systemLanguageID() : sourceID
    }

    func refreshPairInfo() async {
        guard #available(macOS 15.0, *) else {
            pairInfo = .unsupported
            return
        }
        let source = preparedSource
        if LanguageTools.isSameLanguage(source, targetID) {
            pairInfo = .ready
            return
        }
        switch await TranslationBridge.pairStatus(source: source, target: targetID) {
        case .installed: pairInfo = .ready
        case .needsDownload: pairInfo = .needsDownload
        case .unsupported: pairInfo = .unsupported
        }
    }

    func requestDownload() {
        prepare = PrepareRequest(source: preparedSource, target: targetID)
    }

    func finishPrepare() async {
        prepare = nil
        await refreshPairInfo()
    }

    // MARK: Pasteboard and speech

    func pasteInput() {
        guard let text = NSPasteboard.general.string(forType: .string), !text.isEmpty else { return }
        input = text
        translate()
    }

    func copyOutput() {
        guard !output.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(output, forType: .string)
    }

    /// Reads the translation aloud with the system voice for the target language.
    func toggleSpeech() {
        if synthesizer.isSpeaking {
            synthesizer.stopSpeaking(at: .immediate)
            return
        }
        guard !output.isEmpty else { return }
        let utterance = AVSpeechUtterance(string: output)
        utterance.voice = AVSpeechSynthesisVoice(language: targetID)
        synthesizer.speak(utterance)
    }

    // MARK: Helpers

    func note(_ message: String) {
        host?.log.info(message)
    }

    private func persist<Value: Codable>(_ key: String, _ value: Value) {
        host?.preferences.setValue(value, forKey: key)
    }
}
