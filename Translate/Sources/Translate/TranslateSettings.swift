import DroppyKit
import SwiftUI

struct TranslateSettings: View {
    @ObservedObject var model: TranslateModel

    var body: some View {
        DropletSettingsPane {
            DropletSettingsSection {
                settingsSectionHeader(LocalizedStringKey(L10n.tr("settings.languages")))
            } content: {
                DropletSettingsCard {
                    DropletControlRow(title: L10n.tr("settings.source")) {
                        Picker("", selection: $model.sourceID) {
                            Text(L10n.tr("auto")).tag(TranslateModel.auto)
                            Divider()
                            ForEach(model.languages) { language in
                                Text(language.name).tag(language.id)
                            }
                        }
                        .labelsHidden()
                        .pickerStyle(.menu)
                    }
                    DropletControlRow(title: L10n.tr("settings.target")) {
                        Picker("", selection: $model.targetID) {
                            ForEach(model.languages) { language in
                                Text(language.name).tag(language.id)
                            }
                        }
                        .labelsHidden()
                        .pickerStyle(.menu)
                    }
                    DropletToggleRow(
                        title: L10n.tr("settings.live"),
                        subtitle: L10n.tr("settings.live.sub"),
                        isOn: $model.liveTranslate
                    )
                }
            }

            DropletSettingsSection {
                settingsSectionHeader(LocalizedStringKey(L10n.tr("settings.offline")))
            } content: {
                DropletSettingsCard {
                    DropletControlRow(title: L10n.tr("settings.pair")) {
                        DropletValuePill(text: pairText)
                            .task(id: "\(model.sourceID)>\(model.targetID)") {
                                await model.refreshPairInfo()
                            }
                    }
                    DropletControlRow(title: L10n.tr("settings.download")) {
                        Button(L10n.tr("settings.download")) { model.requestDownload() }
                            .buttonStyle(.bordered)
                            .disabled(model.pairInfo == .ready || model.pairInfo == .unsupported)
                            .translationPreparer(model)
                    }
                }
            }
        }
    }

    private var pairText: String {
        switch model.pairInfo {
        case .unknown: L10n.tr("settings.pair.unknown")
        case .ready: L10n.tr("settings.pair.installed")
        case .needsDownload: L10n.tr("settings.pair.needsDownload")
        case .unsupported: L10n.tr("settings.pair.unsupported")
        }
    }
}
