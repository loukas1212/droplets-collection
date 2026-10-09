import DroppyKit
import SwiftUI

struct TranslateWidget: View {
    @ObservedObject var model: TranslateModel
    let context: ShelfWidgetContext
    let openSettings: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: DroppySpacing.sm) {
            header
            languageRow
            if context.isCompact { compactTiles } else { fullTiles }
        }
        .padding(context.contentInsets)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .translationRunner(model)
        .onChange(of: model.input) { model.inputChanged() }
        .onDisappear { model.shelfDidDisappear() }
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: DroppySpacing.xsm) {
            title
            Spacer(minLength: DroppySpacing.md)
            translateButton(diameter: context.isCompact ? 28 : 34)
        }
    }

    private var title: some View {
        HStack(spacing: DroppySpacing.xsm) {
            Image(systemName: "translate").font(.system(size: 12, weight: .medium))
            Text(L10n.tr("title")).font(.system(size: 12, weight: .semibold))
        }
        .foregroundStyle(AdaptiveColors.notchSurfaceSecondaryText)
    }

    private func translateButton(diameter: CGFloat) -> some View {
        Button { model.translate() } label: {
            if model.status == .translating {
                ProgressView().controlSize(.small)
            } else {
                Image(systemName: "arrow.right")
            }
        }
        .buttonStyle(TranslateCircleStyle(
            diameter: diameter,
            accent: .blue,
            usesAdaptiveForegrounds: context.usesAdaptiveForegrounds
        ))
        .help(L10n.tr("a11y.translate"))
        .accessibilityLabel(L10n.tr("a11y.translate"))
    }

    // MARK: Languages

    private var languageRow: some View {
        HStack(spacing: DroppySpacing.xsm) {
            languageMenu(selection: $model.sourceID, includesAuto: true, label: sourceLabel)
            iconButton("arrow.left.arrow.right", label: "a11y.swap", diameter: 24) { model.swapLanguages() }
                .disabled(!model.canSwap)
            languageMenu(selection: $model.targetID, includesAuto: false, label: model.name(for: model.targetID))
            if !context.isCompact {
                Spacer(minLength: DroppySpacing.md)
                iconButton("doc.on.clipboard", label: "a11y.paste", diameter: 24) { model.pasteInput() }
                iconButton("doc.on.doc", label: "a11y.copy", diameter: 24) { model.copyOutput() }
                    .disabled(model.output.isEmpty)
                iconButton("speaker.wave.2", label: "a11y.speak", diameter: 24) { model.toggleSpeech() }
                    .disabled(model.output.isEmpty)
            }
        }
        .frame(height: 28)
    }

    private var sourceLabel: String {
        guard model.sourceID == TranslateModel.auto else { return model.name(for: model.sourceID) }
        guard let detected = model.detected else { return L10n.tr("auto") }
        return String(format: L10n.tr("detected"), model.name(for: detected))
    }

    private func languageMenu(selection: Binding<String>, includesAuto: Bool, label: String) -> some View {
        Menu {
            if includesAuto {
                Button(L10n.tr("auto")) { selection.wrappedValue = TranslateModel.auto }
                Divider()
            }
            ForEach(model.languages) { language in
                Button(language.name) { selection.wrappedValue = language.id }
            }
        } label: {
            Text(label)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .menuStyle(.button)
        .menuIndicator(.hidden)
        .buttonStyle(TranslatePillStyle(
            height: 28,
            usesAdaptiveForegrounds: context.usesAdaptiveForegrounds
        ))
    }

    private func iconButton(
        _ symbol: String,
        label: String,
        diameter: CGFloat,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) { Image(systemName: symbol) }
            .buttonStyle(TranslateCircleStyle(
                diameter: diameter,
                usesAdaptiveForegrounds: context.usesAdaptiveForegrounds
            ))
            .help(L10n.tr(label))
            .accessibilityLabel(L10n.tr(label))
    }

    // MARK: Text

    /// Solo: the text and its translation side by side.
    private var fullTiles: some View {
        HStack(spacing: DroppySpacing.sm) {
            inputTile
            outputTile
        }
        .frame(maxHeight: .infinity)
    }

    /// Paired: the room has space for one short exchange, stacked.
    private var compactTiles: some View {
        VStack(spacing: DroppySpacing.xsm) {
            inputTile
            outputTile
        }
        .frame(maxHeight: .infinity)
    }

    private var inputTile: some View {
        ZStack(alignment: .topLeading) {
            TextEditor(text: $model.input)
                .font(.system(size: 13))
                .scrollContentBackground(.hidden)
                .foregroundStyle(AdaptiveColors.notchSurfacePrimaryText)
                // Return translates, Shift-Return adds a line.
                .onKeyPress(.return, phases: .down) { press in
                    guard !press.modifiers.contains(.shift) else { return .ignored }
                    model.translate()
                    return .handled
                }
            if model.input.isEmpty {
                Text(L10n.tr("placeholder"))
                    .font(.system(size: 13))
                    .foregroundStyle(AdaptiveColors.notchSurfaceTertiaryText)
                    .padding(.leading, 5)
                    .padding(.top, 8)
                    .allowsHitTesting(false)
            }
        }
        .padding(DroppySpacing.xsm)
        .tile()
    }

    private var outputTile: some View {
        VStack(alignment: .leading, spacing: DroppySpacing.xsm) {
            if let message = statusMessage {
                Text(message)
                    .font(.system(size: 12))
                    .foregroundStyle(AdaptiveColors.notchSurfaceSecondaryText)
                if model.status == .needsDownload {
                    Button(L10n.tr("status.download")) { openSettings() }
                        .buttonStyle(TranslatePillStyle(
                            height: 24,
                            usesAdaptiveForegrounds: context.usesAdaptiveForegrounds
                        ))
                }
            } else if model.output.isEmpty {
                Text(L10n.tr("output.placeholder"))
                    .font(.system(size: 13))
                    .foregroundStyle(AdaptiveColors.notchSurfaceTertiaryText)
            } else {
                ScrollView {
                    Text(model.output)
                        .font(.system(size: 13))
                        .foregroundStyle(AdaptiveColors.notchSurfacePrimaryText)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .topLeading)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(DroppySpacing.sm)
        .tile()
    }

    /// Messages shown in place of the translation. `.sameLanguage` keeps the
    /// text in the output, so it is a note, not a replacement.
    private var statusMessage: String? {
        switch model.status {
        case .needsDownload: L10n.tr("status.needsDownload")
        case .unsupported: L10n.tr("status.unsupported")
        case .undetected: L10n.tr("status.undetected")
        case .failed: L10n.tr("status.failed")
        case .osTooOld: L10n.tr("status.old")
        case .sameLanguage: L10n.tr("status.same")
        case .idle, .translating: nil
        }
    }
}

private extension View {
    /// A raised surface inside the widget. Not a frame around it: the root
    /// of the widget stays bare on the shelf's black.
    func tile() -> some View {
        frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(
                RoundedRectangle(cornerRadius: DroppyRadius.medium, style: .continuous)
                    .fill(AdaptiveColors.notchSurfaceCardFill)
            )
    }
}
