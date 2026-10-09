import Foundation

/// this code runs in Droppy's process and `Bundle.main` is Droppy.
enum L10n {
    static func tr(_ key: String) -> String {
        let language = Bundle.main.preferredLocalizations.first ?? "en"
        if language.hasPrefix("fr"), let value = fr[key] { return value }
        return en[key] ?? key
    }

    private static let en: [String: String] = [
        "title": "Translate",
        "auto": "Detect language",
        "detected": "%@ (detected)",
        "placeholder": "Type or paste text",
        "output.placeholder": "Translation appears here",
        "a11y.translate": "Translate",
        "a11y.swap": "Swap languages",
        "a11y.paste": "Paste",
        "a11y.copy": "Copy translation",
        "a11y.speak": "Speak translation",
        "status.needsDownload": "These languages aren't downloaded yet.",
        "status.download": "Download languages",
        "status.unsupported": "This language pair isn't supported.",
        "status.undetected": "Couldn't detect the language. Pick one.",
        "status.same": "The text is already in this language.",
        "status.failed": "The translation failed. Try again.",
        "status.old": "Translation needs macOS 15 or later.",
        "settings.languages": "Languages",
        "settings.source": "From",
        "settings.target": "To",
        "settings.live": "Translate while typing",
        "settings.live.sub": "Translates when you pause typing.",
        "settings.offline": "Offline languages",
        "settings.pair": "Language pair",
        "settings.pair.installed": "Ready",
        "settings.pair.needsDownload": "Not downloaded",
        "settings.pair.unsupported": "Unsupported",
        "settings.pair.unknown": "Checking",
        "settings.download": "Download languages",
        "settings.search.source": "Source language",
        "settings.search.target": "Target language",
    ]

    private static let fr: [String: String] = [
        "title": "Traduire",
        "auto": "Détecter la langue",
        "detected": "%@ (détectée)",
        "placeholder": "Saisissez ou collez du texte",
        "output.placeholder": "La traduction apparaît ici",
        "a11y.translate": "Traduire",
        "a11y.swap": "Inverser les langues",
        "a11y.paste": "Coller",
        "a11y.copy": "Copier la traduction",
        "a11y.speak": "Lire la traduction",
        "status.needsDownload": "Ces langues ne sont pas encore téléchargées.",
        "status.download": "Télécharger les langues",
        "status.unsupported": "Cette paire de langues n'est pas prise en charge.",
        "status.undetected": "Langue non détectée. Choisissez-en une.",
        "status.same": "Le texte est déjà dans cette langue.",
        "status.failed": "La traduction a échoué. Réessayez.",
        "status.old": "La traduction nécessite macOS 15 ou ultérieur.",
        "settings.languages": "Langues",
        "settings.source": "De",
        "settings.target": "Vers",
        "settings.live": "Traduire pendant la saisie",
        "settings.live.sub": "Traduit dès que vous faites une pause.",
        "settings.offline": "Langues hors ligne",
        "settings.pair": "Paire de langues",
        "settings.pair.installed": "Prête",
        "settings.pair.needsDownload": "Non téléchargée",
        "settings.pair.unsupported": "Non prise en charge",
        "settings.pair.unknown": "Vérification",
        "settings.download": "Télécharger les langues",
        "settings.search.source": "Langue source",
        "settings.search.target": "Langue cible",
    ]
}
