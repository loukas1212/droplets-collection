# Translate

A shelf widget for [Droppy](https://getdroppy.app) that translates text between
two languages you choose, entirely on your Mac.

## What it does

- Type or paste text on the shelf, press Return, read the translation.
- Pick the source language, or let it detect the language.
- Swap the two languages in one click. The translation becomes the new text.
- Paste, copy and listen to the translation.
- Solo and paired layouts,.

## Built on the system

| Need | What it uses |
| --- | --- |
| Translation | Apple's Translation framework, on-device models |
| Language detection | NaturalLanguage |
| Reading aloud | AVSpeechSynthesizer |
| Copy and paste | NSPasteboard |
| Language names | Foundation locale APIs |

No network access, no accounts, no API keys. Nothing leaves the Mac, and the
droplet declares no capabilities.

## Requirements

- Droppy 16.0.1 or later
- macOS 15 or later for translation (the droplet loads on macOS 14 and says so)
- The language pair downloaded once. Open the droplet's page in Droppy's
  Settings and choose **Download languages**.

## Credits

Translation, language detection and speech are Apple system frameworks.
Everything else is original.
