import Combine
import DroppyKit
import SwiftUI

@objc(TranslatePrincipal)
public final class TranslatePrincipal: NSObject, DropletPrincipal {
    public override init() { super.init() }
    @MainActor public func makeDroplet() -> AnyObject { TranslateDroplet() }
}

@MainActor
public final class TranslateDroplet: NSObject, ObservableObject, Droplet {
    public nonisolated static let id: DropletID = "translate"

    private let model = TranslateModel()
    private var host: DropletHost?

    public func activate(host: DropletHost) throws {
        self.host = host
        model.attach(host: host)
    }

    public func deactivate() {
        // Stops the translation, the debounce, the language load and the voice.
        model.teardown()
        host = nil
    }
}

// MARK: - Shelf widget

extension TranslateDroplet: ShelfWidgetProviding {
    public var widgetDescriptors: [ShelfWidgetDescriptor] {
        [
            ShelfWidgetDescriptor(
                id: "translate",
                title: "Translate",
                systemImage: "translate",
                layoutTraits: ShelfWidgetLayoutTraits(
                    preferredSoloWidth: 460,
                    preferredPairedWidth: 230,
                    // Includes the 16pt of contentInsets alone under a notch.
                    contentHeight: .fixed(184)
                ),
                // The primary surface is a text field.
                focusPolicy: .keyboardFocusable,
                searchKeywords: ["translate", "translation", "language", "traduire", "traduction"]
            )
        ]
    }

    public func makeWidgetView(_ id: ShelfWidgetID, context: ShelfWidgetContext) -> AnyView {
        AnyView(
            TranslateWidget(
                model: model,
                context: context,
                openSettings: { [weak self] in self?.host?.workspace.openSettings() }
            )
        )
    }

    public func makeWidgetSettingsPopover(_ id: ShelfWidgetID) -> AnyView? { nil }
}

// MARK: - Settings pane

extension TranslateDroplet: SettingsPaneProviding {
    public func makeSettingsPane(context: SettingsPaneContext) -> AnyView {
        AnyView(TranslateSettings(model: model))
    }

    public var settingsSearchEntries: [SettingsSearchEntry] {
        [
            SettingsSearchEntry(title: "Source language", keywords: ["from", "detect", "translate"]),
            SettingsSearchEntry(title: "Target language", keywords: ["to", "translate"]),
            SettingsSearchEntry(title: "Offline languages", keywords: ["download", "translate"]),
            SettingsSearchEntry(title: "Translate while typing", keywords: ["live", "translate"]),
        ]
    }
}
