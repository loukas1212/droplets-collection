import DroppyKit
import DroppyKitHarness
import Translate

@main
struct TranslateHarness: DropletHarnessApp {
    static func makeDroplet() -> any Droplet { TranslateDroplet() }
}
