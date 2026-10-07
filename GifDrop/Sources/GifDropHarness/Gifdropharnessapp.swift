import DroppyKit
import DroppyKitHarness
import GifDrop

@main
struct GifDropHarnessApp: DropletHarnessApp {
    static func makeDroplet() -> any Droplet { GifDropDroplet() }
}