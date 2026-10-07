// Sources/DisksHarness/main.swift  (cible exécutable, générée par `droppykit new`)
import DroppyKit
import DroppyKitHarness
import Disks

@main
struct DisksHarness: DropletHarnessApp {
    static func makeDroplet() -> any Droplet { DisksDroplet() }
}