import AppKit
import Combine
import DroppyKit
import SwiftUI

// MARK: - Entry point

@objc(DisksPrincipal)
public final class DisksPrincipal: NSObject, DropletPrincipal {
    public override init() { super.init() }
    @MainActor public func makeDroplet() -> AnyObject { DisksDroplet() }
}

// MARK: - Model

/// NSImage is not Sendable; the icon is created once in the background scan and
/// only ever read afterwards.
struct DiskIcon: @unchecked Sendable {
    let image: NSImage
}

struct MountedDisk: Identifiable, Sendable {
    let url: URL
    let name: String
    let icon: DiskIcon
    let canEject: Bool
    let totalBytes: Int64?
    let availableBytes: Int64?

    var id: String { url.path }

    var usedBytes: Int64? {
        guard let totalBytes, let availableBytes else { return nil }
        return max(0, totalBytes - availableBytes)
    }

    /// 0...1, nil when the capacity is unknown.
    var usedFraction: Double? {
        guard let totalBytes, totalBytes > 0, let usedBytes else { return nil }
        return min(1, Double(usedBytes) / Double(totalBytes))
    }

    var usageText: String {
        guard let used = usedBytes, let total = totalBytes, let fraction = usedFraction else {
            return "Capacity unavailable"
        }
        let size = { (bytes: Int64) in ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file) }
        return "\(size(used)) used of \(size(total)) · \(Int((fraction * 100).rounded()))%"
    }
}

// MARK: - Droplet

@MainActor
public final class DisksDroplet: NSObject, ObservableObject, Droplet {
    public nonisolated static let id: DropletID = "disks"
    nonisolated static var widgetID: ShelfWidgetID { "disks" }

    private var host: DropletHost?
    private var observers: [NSObjectProtocol] = []
    private var scanInFlight = false
    private var rescanRequested = false

    /// One serial queue for every volume scan, one concurrent queue for ejects. Both are
    /// plain GCD queues: a blocked network share or drive never takes a thread from
    /// Swift's shared concurrency pool, which Droppy uses for its own async work.
    private static let scanQueue = DispatchQueue(label: "app.droppy.disks.scan", qos: .utility)
    private static let ejectQueue = DispatchQueue(
        label: "app.droppy.disks.eject", qos: .userInitiated, attributes: .concurrent
    )
    private var failureTask: Task<Void, Never>?

    @Published private(set) var disks: [MountedDisk] = []
    @Published private(set) var isLoaded = false
    /// Disk shown in the detail view (nil = list).
    @Published private(set) var selectedID: String?
    /// Disks currently being ejected.
    @Published private(set) var ejecting: Set<String> = []
    /// Reason of the last failed eject, shown in the widget.
    @Published private(set) var ejectFailure: String?

    public override init() { super.init() }

    var selectedDisk: MountedDisk? {
        guard let selectedID else { return nil }
        return disks.first { $0.id == selectedID }
    }

    // MARK: Lifecycle

    public func activate(host: DropletHost) throws {
        self.host = host
        refresh()

        let center = NSWorkspace.shared.notificationCenter
        let names: [Notification.Name] = [
            NSWorkspace.didMountNotification,
            NSWorkspace.didUnmountNotification,
            NSWorkspace.didRenameVolumeNotification
        ]
        observers = names.map { name in
            center.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
                let unmounted = name == NSWorkspace.didUnmountNotification
                    ? (note.userInfo?[NSWorkspace.volumeURLUserInfoKey] as? URL)?.path
                    : nil
                Task { @MainActor in
                    // Drop an unmounted volume right away; the scan may be slow.
                    if let unmounted { self?.remove(path: unmounted) }
                    self?.refresh()
                }
            }
        }
    }

    public func deactivate() {
        let center = NSWorkspace.shared.notificationCenter
        observers.forEach { center.removeObserver($0) }
        observers.removeAll()
        failureTask?.cancel()
        failureTask = nil
        rescanRequested = false   // a scan still in flight is dropped: host is nil when it ends
        selectedID = nil
        host = nil
    }

    // MARK: Scan (background)

    /// Reads names, capacities and icons off the main thread: a sleeping drive or an
    /// unreachable network share can block these calls for a long time.
    nonisolated private static func scanVolumes() -> [MountedDisk] {
        let keys: [URLResourceKey] = [
            .volumeNameKey, .volumeIsEjectableKey, .volumeIsRemovableKey, .volumeIsLocalKey,
            .volumeTotalCapacityKey, .volumeAvailableCapacityKey,
            .volumeAvailableCapacityForImportantUsageKey
        ]
        let urls = FileManager.default.mountedVolumeURLs(
            includingResourceValuesForKeys: keys,
            options: [.skipHiddenVolumes]
        ) ?? []

        return urls.map { url in
            let values = try? url.resourceValues(forKeys: Set(keys))
            let isBoot = url.path == "/"
            let ejectable = (values?.volumeIsEjectable ?? false)
                || (values?.volumeIsRemovable ?? false)
                || !(values?.volumeIsLocal ?? true)   // network share

            let total = values?.volumeTotalCapacity.map(Int64.init)
            let available = values?.volumeAvailableCapacityForImportantUsage
                ?? values?.volumeAvailableCapacity.map(Int64.init)

            return MountedDisk(
                url: url,
                name: values?.volumeName ?? url.lastPathComponent,
                icon: DiskIcon(image: NSWorkspace.shared.icon(forFile: url.path)),
                canEject: ejectable && !isBoot,
                totalBytes: total,
                availableBytes: available
            )
        }
    }

    /// Starts a scan unless one is already running. A request that arrives meanwhile is
    /// remembered and answered by a single fresh scan once the current one ends, so a
    /// stuck share never piles up work.
    func refresh() {
        guard host != nil else { return }
        if scanInFlight {
            rescanRequested = true
            return
        }
        scanInFlight = true
        DisksDroplet.scanQueue.async { [weak self] in
            let list = DisksDroplet.scanVolumes()
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.scanFinished(list) }
            }
        }
    }

    private func scanFinished(_ list: [MountedDisk]) {
        scanInFlight = false
        guard host != nil else { return }
        if rescanRequested {
            // The result may already be stale (a mount, unmount or tap came in): scan again.
            rescanRequested = false
            refresh()
            return
        }
        apply(list)
    }

    private func remove(path: String) {
        // A scan already running may still list this volume: make it count as stale.
        if scanInFlight { rescanRequested = true }
        apply(disks.filter { $0.id != path })
    }

    private func apply(_ list: [MountedDisk]) {
        let layoutChanged = list.count != disks.count
        disks = list
        isLoaded = true
        ejecting.formIntersection(list.map(\.id))

        // The disk shown has disappeared (ejected): back to the list.
        var selectionDropped = false
        if let selectedID, !list.contains(where: { $0.id == selectedID }) {
            self.selectedID = nil
            selectionDropped = true
        }

        if layoutChanged || selectionDropped {
            host?.shelf.invalidateLayout(for: Self.widgetID)
        }
    }

    // MARK: Selection

    func select(_ disk: MountedDisk) {
        selectedID = disk.id
        host?.shelf.invalidateLayout(for: Self.widgetID)
        refresh()   // fresh capacities, in the background
    }

    func deselect() {
        selectedID = nil
        host?.shelf.invalidateLayout(for: Self.widgetID)
    }

    // MARK: Actions

    func open(_ disk: MountedDisk) {
        NSWorkspace.shared.open(disk.url)
    }

    func eject(_ disk: MountedDisk) {
        guard disk.canEject, !ejecting.contains(disk.id) else { return }
        let url = disk.url
        let name = disk.name
        ejecting.insert(disk.id)
        clearFailure()

        DisksDroplet.ejectQueue.async { [weak self] in
            let failure: String?
            do {
                try NSWorkspace.shared.unmountAndEjectDevice(at: url)
                failure = nil
            } catch {
                let nsError = error as NSError
                failure = nsError.localizedFailureReason ?? error.localizedDescription
            }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self?.ejectFinished(id: url.path, name: name, failure: failure)
                }
            }
        }
    }

    private func ejectFinished(id: String, name: String, failure: String?) {
        ejecting.remove(id)
        guard let failure else { return }   // success: the unmount notification updates the list
        host?.log.info("eject failed for \(id): \(failure)")
        ejectFailure = "Couldn't eject “\(name)”. \(failure)"
        host?.shelf.invalidateLayout(for: Self.widgetID)

        failureTask?.cancel()
        failureTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(10))
            guard !Task.isCancelled else { return }
            self?.clearFailure()
        }
    }

    func clearFailure() {
        failureTask?.cancel()
        failureTask = nil
        guard ejectFailure != nil else { return }
        ejectFailure = nil
        host?.shelf.invalidateLayout(for: Self.widgetID)
    }
}

// MARK: - Storage bar

struct StorageBarView: View {
    let fraction: Double?

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule(style: .continuous)
                    .fill(AdaptiveColors.notchSurfaceCardFill)
                if let fraction {
                    Capsule(style: .continuous)
                        .fill(AdaptiveColors.notchSurfacePrimaryText)
                        .frame(width: max(DisksLayout.barHeight, proxy.size.width * fraction))
                }
            }
        }
        .frame(height: DisksLayout.barHeight)
    }
}

// MARK: - Shelf widget

extension DisksDroplet: ShelfWidgetProviding {
    public var widgetDescriptors: [ShelfWidgetDescriptor] {
        var height: CGFloat
        if selectedDisk != nil {
            height = DisksLayout.detailHeight
        } else {
            let rows = max(1, min(disks.count, DisksLayout.maxVisibleRows))
            let content = DisksLayout.headerHeight + DisksLayout.rowHeight * CGFloat(rows)
                + DisksLayout.rowSpacing * CGFloat(rows - 1)
            // 16 = content insets (8 each side), 8 = spacing under the header
            height = content + 16 + 8
        }
        if ejectFailure != nil {
            height += DisksLayout.errorHeight + 8
        }

        return [
            ShelfWidgetDescriptor(
                id: Self.widgetID,
                title: "Disks",
                systemImage: "externaldrive",
                layoutTraits: ShelfWidgetLayoutTraits(
                    preferredSoloWidth: 420,
                    preferredPairedWidth: 210,
                    contentHeight: .fixed(height)
                ),
                searchKeywords: ["disk", "volume", "eject", "usb", "drive", "storage"]
            )
        ]
    }

    public func makeWidgetView(_ id: ShelfWidgetID, context: ShelfWidgetContext) -> AnyView {
        AnyView(DisksWidget(droplet: self, context: context))
    }

    public func makeWidgetSettingsPopover(_ id: ShelfWidgetID) -> AnyView? { nil }
}

// MARK: - Widget views

enum DisksLayout {
    static let rowHeight: CGFloat = 28
    static let rowSpacing: CGFloat = 4
    static let headerHeight: CGFloat = 20
    static let maxVisibleRows = 5
    /// 16 insets + 20 header + 8 + 28 row + 8 + 8 bar + 8 + 16 text
    static let detailHeight: CGFloat = 112
    static let barHeight: CGFloat = 8
    static let errorHeight: CGFloat = 30
}

struct DisksWidget: View {
    @ObservedObject var droplet: DisksDroplet
    let context: ShelfWidgetContext

    var body: some View {
        VStack(alignment: .leading, spacing: DroppySpacing.sm) {
            header
            if !droplet.isLoaded {
                Text("Looking for disks…")
                    .font(.system(size: 12))
                    .foregroundStyle(AdaptiveColors.notchSurfaceTertiaryText)
            } else if droplet.disks.isEmpty {
                Text("No disks mounted")
                    .font(.system(size: 12))
                    .foregroundStyle(AdaptiveColors.notchSurfaceTertiaryText)
            } else if context.isCompact {
                compactBody
            } else if let disk = droplet.selectedDisk {
                detailBody(disk)
            } else {
                listBody
            }
            if !context.isCompact, let failure = droplet.ejectFailure {
                failureBanner(failure)
            }
            Spacer(minLength: 0)
        }
        .padding(context.contentInsets)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: DroppySpacing.xsm) {
            if !context.isCompact, droplet.selectedDisk != nil {
                Button { droplet.deselect() } label: {
                    Image(systemName: "chevron.left")
                }
                .buttonStyle(DroppyCircleButtonStyle(size: 20))
                .help("Back to all disks")
            } else {
                Image(systemName: "externaldrive").font(.system(size: 12, weight: .medium))
            }
            Text("Disks").font(.system(size: 12, weight: .semibold))
            Spacer(minLength: 0)
        }
        .foregroundStyle(AdaptiveColors.notchSurfaceSecondaryText)
        .frame(height: DisksLayout.headerHeight)
    }

    // MARK: Paired view: the disks, by name

    private var compactBody: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .leading, spacing: DisksLayout.rowSpacing) {
                ForEach(droplet.disks) { disk in
                    HStack(spacing: DroppySpacing.sm) {
                        Image(nsImage: disk.icon.image)
                            .resizable()
                            .frame(width: 18, height: 18)
                        Text(disk.name)
                            .font(.system(size: 12, weight: .medium))
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .foregroundStyle(AdaptiveColors.notchSurfacePrimaryText)
                        Spacer(minLength: 0)
                    }
                    .frame(height: DisksLayout.rowHeight)
                }
            }
        }
    }

    // MARK: Solo list: icon and name first, buttons at the end

    private var listBody: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(spacing: DisksLayout.rowSpacing) {
                ForEach(droplet.disks) { disk in
                    row(disk)
                }
            }
        }
        .droppyFlatGlassControls()
    }

    private func row(_ disk: MountedDisk) -> some View {
        HStack(spacing: DroppySpacing.sm) {
            // A tap on the icon / name opens the storage detail.
            Button { droplet.select(disk) } label: {
                HStack(spacing: DroppySpacing.sm) {
                    diskLabel(disk)
                    Spacer(minLength: DroppySpacing.md)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Show storage")

            actionButtons(disk)
        }
        .frame(height: DisksLayout.rowHeight)
    }

    // MARK: Detail

    private func detailBody(_ disk: MountedDisk) -> some View {
        VStack(alignment: .leading, spacing: DroppySpacing.sm) {
            HStack(spacing: DroppySpacing.sm) {
                diskLabel(disk)
                Spacer(minLength: DroppySpacing.md)
                actionButtons(disk)
            }
            .frame(height: DisksLayout.rowHeight)
            .droppyFlatGlassControls()

            StorageBarView(fraction: disk.usedFraction)

            Text(disk.usageText)
                .font(.system(size: 12, weight: .medium))
                .monospacedDigit()
                .lineLimit(1)
                .foregroundStyle(AdaptiveColors.notchSurfacePrimaryText)
                .frame(height: 16, alignment: .leading)
        }
    }

    // MARK: Pieces

    private func diskLabel(_ disk: MountedDisk) -> some View {
        HStack(spacing: DroppySpacing.sm) {
            Image(nsImage: disk.icon.image)
                .resizable()
                .frame(width: 20, height: 20)
            Text(disk.name)
                .font(.system(size: 12, weight: .medium))
                .lineLimit(1)
                .truncationMode(.middle)
                .foregroundStyle(AdaptiveColors.notchSurfacePrimaryText)
        }
    }

    private func actionButtons(_ disk: MountedDisk) -> some View {
        let isEjecting = droplet.ejecting.contains(disk.id)
        return HStack(spacing: DroppySpacing.sm) {
            Button { droplet.open(disk) } label: {
                Image(systemName: "folder")
            }
            .buttonStyle(DroppyCircleButtonStyle(size: 24))
            .help("Open")

            Button { droplet.eject(disk) } label: {
                if isEjecting {
                    ProgressView().controlSize(.mini)
                } else {
                    Image(systemName: "eject.fill")
                }
            }
            .buttonStyle(DroppyCircleButtonStyle(size: 24))
            .disabled(!disk.canEject || isEjecting)
            .help(isEjecting ? "Ejecting…" : (disk.canEject ? "Eject" : "This disk cannot be ejected"))
        }
    }

    private func failureBanner(_ message: String) -> some View {
        HStack(spacing: DroppySpacing.sm) {
            Text(message)
                .font(.system(size: 11))
                .lineLimit(2)
                .foregroundStyle(AdaptiveColors.notchSurfaceSecondaryText)
            Spacer(minLength: 0)
            Button { droplet.clearFailure() } label: {
                Image(systemName: "xmark")
            }
            .buttonStyle(DroppyCircleButtonStyle(size: 20))
            .help("Dismiss")
        }
        .frame(height: DisksLayout.errorHeight)
    }
}