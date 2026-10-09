import Foundation
import NaturalLanguage
import SwiftUI
import Translation

// Everything that touches Apple's Translation framework lives in this file.
// The framework needs macOS 15, the package targets macOS 14, so every use is
// gated and the rest of the droplet never imports Translation.

enum PairStatus: Equatable, Sendable {
    case installed
    case needsDownload
    case unsupported
}

/// Language helpers that work on every supported macOS.
enum LanguageTools {
    /// Dominant language of `text` as a minimal identifier, or nil when the
    /// recognizer is not confident. Uses the on-device NaturalLanguage model.
    static func detect(_ text: String) -> String? {
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(text)
        guard let language = recognizer.dominantLanguage, language != .undetermined else { return nil }
        return Locale.Language(identifier: language.rawValue).minimalIdentifier
    }

    static func name(for id: String) -> String {
        Locale.current.localizedString(forIdentifier: id) ?? id
    }

    static func systemLanguageID() -> String {
        let preferred = Locale.preferredLanguages.first ?? "en"
        return Locale.Language(identifier: preferred).minimalIdentifier
    }

    /// True when translating between the two would be a no-op. Chinese scripts
    /// are different writing systems and stay distinct.
    static func isSameLanguage(_ a: String, _ b: String) -> Bool {
        let first = Locale.Language(identifier: a)
        let second = Locale.Language(identifier: b)
        guard let codeA = first.languageCode, let codeB = second.languageCode, codeA == codeB else {
            return false
        }
        if codeA.identifier == "zh" { return first.minimalIdentifier == second.minimalIdentifier }
        return true
    }

    /// Shown until the system answers, and when it cannot.
    static let fallback: [LanguageOption] = [
        "ar", "zh-Hans", "zh-Hant", "nl", "en", "fr", "de", "hi", "id", "it",
        "ja", "ko", "pl", "pt-BR", "ru", "es", "th", "tr", "uk", "vi",
    ]
    .map { LanguageOption(id: $0, name: name(for: $0)) }
    .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
}

@available(macOS 15.0, *)
enum TranslationBridge {
    static func supportedLanguages() async -> [LanguageOption] {
        let languages = await LanguageAvailability().supportedLanguages
        var seen = Set<String>()
        return languages
            .map(\.minimalIdentifier)
            .filter { seen.insert($0).inserted }
            .map { LanguageOption(id: $0, name: LanguageTools.name(for: $0)) }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    static func pairStatus(source: String, target: String) async -> PairStatus {
        let status = await LanguageAvailability().status(
            from: Locale.Language(identifier: source),
            to: Locale.Language(identifier: target)
        )
        switch status {
        case .installed: return .installed
        case .supported: return .needsDownload
        default: return .unsupported
        }
    }

    /// A new configuration for the pair, or the current one invalidated when
    /// the pair is unchanged. Setting a configuration is what starts a
    /// `translationTask`, and an equal one does nothing until it is invalidated.
    static func configuration(
        replacing current: TranslationSession.Configuration?,
        source: String,
        target: String
    ) -> TranslationSession.Configuration {
        let sourceLanguage = Locale.Language(identifier: source)
        let targetLanguage = Locale.Language(identifier: target)
        if var current, current.source == sourceLanguage, current.target == targetLanguage {
            current.invalidate()
            return current
        }
        return TranslationSession.Configuration(source: sourceLanguage, target: targetLanguage)
    }
}

// MARK: - Runners

// `TranslationSession` only exists inside a SwiftUI `translationTask`, so the
// model publishes a job and these invisible modifiers carry it out.

@available(macOS 15.0, *)
private struct TranslationRunner: ViewModifier {
    @ObservedObject var model: TranslateModel
    @State private var configuration: TranslationSession.Configuration?

    func body(content: Content) -> some View {
        content
            .onChange(of: model.job) { _, job in
                guard let job else { return }
                configuration = TranslationBridge.configuration(
                    replacing: configuration,
                    source: job.source,
                    target: job.target
                )
            }
            .translationTask(configuration) { session in
                // The closure runs on the main actor, `translate` does not. The
                // session never leaves this closure, so the hand-over is safe.
                nonisolated(unsafe) let session = session
                guard let job = model.currentJob() else { return }
                do {
                    let response = try await session.translate(job.text)
                    model.complete(jobID: job.id, text: response.targetText)
                } catch {
                    model.fail(jobID: job.id, message: "translate failed: \(error.localizedDescription)")
                }
            }
    }
}

@available(macOS 15.0, *)
private struct TranslationPreparer: ViewModifier {
    @ObservedObject var model: TranslateModel
    @State private var configuration: TranslationSession.Configuration?

    func body(content: Content) -> some View {
        content
            .onChange(of: model.prepare) { _, request in
                guard let request else { return }
                configuration = TranslationBridge.configuration(
                    replacing: configuration,
                    source: request.source,
                    target: request.target
                )
            }
            .translationTask(configuration) { session in
                // Shows the system download sheet. Only ever mounted in the
                // settings pane: a sheet raised from the shelf is drawn under it.
                nonisolated(unsafe) let session = session
                do {
                    try await session.prepareTranslation()
                } catch {
                    model.note("prepare failed: \(error.localizedDescription)")
                }
                await model.finishPrepare()
            }
    }
}

extension View {
    /// Carries out the model's translation jobs with the system's on-device models.
    @ViewBuilder
    func translationRunner(_ model: TranslateModel) -> some View {
        if #available(macOS 15.0, *) {
            modifier(TranslationRunner(model: model))
        } else {
            self
        }
    }

    /// Lets the model ask the system to download a language pair.
    @ViewBuilder
    func translationPreparer(_ model: TranslateModel) -> some View {
        if #available(macOS 15.0, *) {
            modifier(TranslationPreparer(model: model))
        } else {
            self
        }
    }
}
