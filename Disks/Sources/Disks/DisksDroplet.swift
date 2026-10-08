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

struct PartitionInfo: Identifiable, Sendable {
    let id: String
    let name: String
    let bytes: Int64
    /// The partition that holds the disk shown in the widget.
    let isCurrent: Bool
}

struct PartitionLayout: Sendable {
    let totalBytes: Int64
    let partitions: [PartitionInfo]
}

enum PartitionResult: Sendable {
    case loaded(PartitionLayout)
    case unavailable
}

struct MountedDisk: Identifiable, Sendable {
    let url: URL
    let name: String
    let icon: DiskIcon
    let canEject: Bool
    let isLocal: Bool
    let isInternal: Bool?
    let isReadOnly: Bool?
    let formatDescription: String?
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

    /// "APFS · Internal · Writable"
    var factsText: String {
        let location = !isLocal ? "Network" : (isInternal.map { $0 ? "Internal" : "External" } ?? "Unknown")
        let access = isReadOnly.map { $0 ? "Read-only" : "Writable" } ?? "Unknown access"
        return [formatDescription, location, access].compactMap { $0 }.joined(separator: " · ")
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
    private static let infoQueue = DispatchQueue(label: "app.droppy.disks.info", qos: .utility)
    private static let ejectQueue = DispatchQueue(
        label: "app.droppy.disks.eject", qos: .userInitiated, attributes: .concurrent
    )
    private var failureTask: Task<Void, Never>?

    @Published private(set) var disks: [MountedDisk] = []
    @Published private(set) var isLoaded = false
    /// Disk shown in the detail view (nil = list).
    @Published private(set) var selectedID: String?
    /// The detail view shows disk information and partitions instead of the usage bar.
    @Published private(set) var showInfo = false
    /// Partition layouts already read, by disk id.
    @Published private(set) var layouts: [String: PartitionResult] = [:]
    private var layoutLoading: Set<String> = []
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
            .volumeAvailableCapacityForImportantUsageKey,
            .volumeLocalizedFormatDescriptionKey, .volumeIsInternalKey, .volumeIsReadOnlyKey
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
                isLocal: values?.volumeIsLocal ?? true,
                isInternal: values?.volumeIsInternal,
                isReadOnly: values?.volumeIsReadOnly,
                formatDescription: values?.volumeLocalizedFormatDescription,
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
        let liveIDs = Set(list.map(\.id))
        layouts = layouts.filter { liveIDs.contains($0.key) }

        // The disk shown has disappeared (ejected): back to the list.
        var selectionDropped = false
        if let selectedID, !list.contains(where: { $0.id == selectedID }) {
            self.selectedID = nil
            self.showInfo = false
            selectionDropped = true
        }

        if layoutChanged || selectionDropped {
            host?.shelf.invalidateLayout(for: Self.widgetID)
        }
    }

    // MARK: Selection

    func select(_ disk: MountedDisk) {
        selectedID = disk.id
        showInfo = false
        host?.shelf.invalidateLayout(for: Self.widgetID)
        refresh()   // fresh capacities, in the background
    }

    func deselect() {
        selectedID = nil
        showInfo = false
        host?.shelf.invalidateLayout(for: Self.widgetID)
    }

    /// Back: from the info view to the usage view, then to the list.
    func back() {
        if showInfo {
            showInfo = false
            host?.shelf.invalidateLayout(for: Self.widgetID)
        } else {
            deselect()
        }
    }

    func toggleInfo() {
        guard let disk = selectedDisk else { return }
        showInfo.toggle()
        host?.shelf.invalidateLayout(for: Self.widgetID)
        if showInfo { loadLayout(for: disk) }
    }

    // MARK: Actions

    func open(_ disk: MountedDisk) {
        NSWorkspace.shared.open(disk.url)
    }

    // MARK: Partitions (on their own serial queue, with a timeout)

    private func loadLayout(for disk: MountedDisk) {
        guard layouts[disk.id] == nil, !layoutLoading.contains(disk.id) else { return }
        layoutLoading.insert(disk.id)
        let id = disk.id
        let path = disk.url.path
        let name = disk.name
        let isLocal = disk.isLocal
        DisksDroplet.infoQueue.async { [weak self] in
            let result = DisksDroplet.readLayout(path: path, volumeName: name, isLocal: isLocal)
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.layoutLoaded(id: id, result: result) }
            }
        }
    }

    private func layoutLoaded(id: String, result: PartitionResult) {
        layoutLoading.remove(id)
        guard host != nil else { return }
        layouts[id] = result
    }

    /// `statfs` gives the BSD device of a mounted volume ("disk3s1s1").
    nonisolated private static func bsdName(forMountPoint path: String) -> String? {
        var st = statfs()
        guard statfs(path, &st) == 0 else { return nil }
        let from = withUnsafePointer(to: &st.f_mntfromname) {
            $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXPATHLEN)) { String(cString: $0) }
        }
        guard from.hasPrefix("/dev/") else { return nil }
        return String(from.dropFirst(5))
    }

    /// Runs `diskutil … -plist` and gives up after 8 seconds.
    nonisolated private static func runDiskutil(_ arguments: [String]) -> [String: Any]? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/diskutil")
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        let finished = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in finished.signal() }
        do { try process.run() } catch { return nil }
        if finished.wait(timeout: .now() + 8) == .timedOut {
            process.terminate()
            return nil
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        return (try? PropertyListSerialization.propertyList(from: data, format: nil)) as? [String: Any]
    }

    nonisolated private static func partitionLabel(
        content: String, volumeName: String?, isCurrent: Bool, currentVolume: String
    ) -> String {
        if let volumeName, !volumeName.isEmpty { return volumeName }
        switch content {
        case "Apple_APFS": return isCurrent ? "APFS Container (\(currentVolume))" : "APFS Container"
        case "Apple_APFS_Recovery": return "Recovery"
        case "Apple_APFS_ISC": return "System Boot"
        case "EFI": return "EFI"
        default: return content.isEmpty ? "Partition" : content
        }
    }

    /// Partitions of the physical disk that holds `path`. For an APFS volume this is the
    /// disk under the APFS container (iBoot, container, Recovery…), not the container itself.
    nonisolated private static func readLayout(path: String, volumeName: String, isLocal: Bool) -> PartitionResult {
        guard isLocal,
              let bsd = bsdName(forMountPoint: path),
              let info = runDiskutil(["info", "-plist", bsd]) else { return .unavailable }

        let stores = info["APFSPhysicalStores"] as? [[String: Any]]
        let storeID = stores?.first?["APFSPhysicalStore"] as? String
        let currentID = storeID ?? bsd

        let digits = currentID.dropFirst(4).prefix { $0.isNumber }
        guard currentID.hasPrefix("disk"), !digits.isEmpty else { return .unavailable }
        let whole = "disk" + digits

        guard let list = runDiskutil(["list", "-plist", whole]),
              let entries = list["AllDisksAndPartitions"] as? [[String: Any]],
              let entry = entries.first(where: { ($0["DeviceIdentifier"] as? String) == whole }) ?? entries.first,
              let total = (entry["Size"] as? NSNumber)?.int64Value else { return .unavailable }

        let raw = entry["Partitions"] as? [[String: Any]] ?? []
        var partitions: [PartitionInfo] = raw.compactMap { partition in
            guard let id = partition["DeviceIdentifier"] as? String,
                  let size = (partition["Size"] as? NSNumber)?.int64Value else { return nil }
            let isCurrent = id == currentID
            return PartitionInfo(
                id: id,
                name: partitionLabel(
                    content: partition["Content"] as? String ?? "",
                    volumeName: partition["VolumeName"] as? String,
                    isCurrent: isCurrent,
                    currentVolume: volumeName
                ),
                bytes: size,
                isCurrent: isCurrent
            )
        }
        if partitions.isEmpty {
            partitions = [PartitionInfo(id: whole, name: volumeName, bytes: total, isCurrent: true)]
        }
        return .loaded(PartitionLayout(totalBytes: total, partitions: partitions))
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
    var height: CGFloat = DisksLayout.barHeight
    var emphasized = true

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule(style: .continuous)
                    .fill(AdaptiveColors.notchSurfaceCardFill)
                if let fraction {
                    Capsule(style: .continuous)
                        .fill(emphasized
                              ? AdaptiveColors.notchSurfacePrimaryText
                              : AdaptiveColors.notchSurfaceTertiaryText)
                        .frame(width: max(height, proxy.size.width * fraction))
                }
            }
        }
        .frame(height: height)
    }
}

// MARK: - Shelf widget

extension DisksDroplet: ShelfWidgetProviding {
    public var widgetDescriptors: [ShelfWidgetDescriptor] {
        var height: CGFloat
        if selectedDisk != nil {
            height = showInfo ? DisksLayout.infoHeight : DisksLayout.detailHeight
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
    /// 16 insets + 20 header + 8 + 28 row + 8 + 16 facts + 8 + 112 partitions
    static let infoHeight: CGFloat = 216
    static let partitionsAreaHeight: CGFloat = 112
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
                Button { droplet.back() } label: {
                    Image(systemName: "chevron.left")
                }
                .buttonStyle(DroppyCircleButtonStyle(size: 20))
                .help(droplet.showInfo ? "Back to storage" : "Back to all disks")
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
                actionButtons(disk, showInfo: true)
            }
            .frame(height: DisksLayout.rowHeight)
            .droppyFlatGlassControls()

            if droplet.showInfo {
                infoBody(disk)
            } else {
                StorageBarView(fraction: disk.usedFraction)

                Text(disk.usageText)
                    .font(.system(size: 12, weight: .medium))
                    .monospacedDigit()
                    .lineLimit(1)
                    .foregroundStyle(AdaptiveColors.notchSurfacePrimaryText)
                    .frame(height: 16, alignment: .leading)
            }
        }
    }

    // MARK: Info: format, location, access, then the partitions with a bar each

    @ViewBuilder private func infoBody(_ disk: MountedDisk) -> some View {
        Text(disk.factsText)
            .font(.system(size: 12, weight: .medium))
            .lineLimit(1)
            .foregroundStyle(AdaptiveColors.notchSurfacePrimaryText)
            .frame(height: 16, alignment: .leading)

        Group {
            switch droplet.layouts[disk.id] {
            case .none:
                Text("Reading partitions…")
                    .foregroundStyle(AdaptiveColors.notchSurfaceTertiaryText)
            case .some(.unavailable):
                Text("Partitions aren't available for this disk")
                    .foregroundStyle(AdaptiveColors.notchSurfaceTertiaryText)
            case .some(.loaded(let layout)):
                partitionList(layout)
            }
        }
        .font(.system(size: 12))
        .frame(maxWidth: .infinity, minHeight: 0,
               maxHeight: DisksLayout.partitionsAreaHeight, alignment: .topLeading)
    }

    private func partitionList(_ layout: PartitionLayout) -> some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(spacing: DroppySpacing.sm) {
                ForEach(layout.partitions) { partition in
                    VStack(alignment: .leading, spacing: 3) {
                        HStack {
                            Text(partition.name)
                                .font(.system(size: 11, weight: .semibold))
                                .lineLimit(1)
                                .truncationMode(.middle)
                                .foregroundStyle(partition.isCurrent
                                                 ? AdaptiveColors.notchSurfacePrimaryText
                                                 : AdaptiveColors.notchSurfaceSecondaryText)
                            Spacer(minLength: DroppySpacing.md)
                            Text(ByteCountFormatter.string(fromByteCount: partition.bytes, countStyle: .file))
                                .font(.system(size: 11))
                                .monospacedDigit()
                                .foregroundStyle(AdaptiveColors.notchSurfaceSecondaryText)
                        }
                        StorageBarView(
                            fraction: layout.totalBytes > 0
                                ? Double(partition.bytes) / Double(layout.totalBytes)
                                : 0,
                            height: 6,
                            emphasized: partition.isCurrent
                        )
                    }
                }
            }
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

    private func actionButtons(_ disk: MountedDisk, showInfo: Bool = false) -> some View {
        let isEjecting = droplet.ejecting.contains(disk.id)
        return HStack(spacing: DroppySpacing.sm) {
            if showInfo {
                Button { droplet.toggleInfo() } label: {
                    Image(systemName: droplet.showInfo ? "info.circle.fill" : "info.circle")
                }
                .buttonStyle(DroppyCircleButtonStyle(size: 24))
                .help("Disk information and partitions")
            }

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