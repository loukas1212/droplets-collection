import AppKit
import Combine
import DroppyKit
import SwiftUI
import UniformTypeIdentifiers

// MARK: - Entry point

@objc(GifDropPrincipal)
public final class GifDropPrincipal: NSObject, DropletPrincipal {
    public override init() { super.init() }
    @MainActor public func makeDroplet() -> AnyObject { GifDropDroplet() }
}

// MARK: - Model

enum ConversionState: Equatable {
    case idle
    case converting(name: String, progress: Double)
    case done(output: URL, bytes: Int64)
    case failed(String)

    var isConverting: Bool {
        if case .converting = self { return true }
        return false
    }
}

// MARK: - Droplet

@MainActor
public final class GifDropDroplet: NSObject, ObservableObject, Droplet {
    public nonisolated static let id: DropletID = "gifdrop"

    @Published private(set) var state: ConversionState = .idle

    static let supportedExtensions: Set<String> = ["mp4", "m4v", "mov", "webm", "png", "jpg", "jpeg"]

    private var host: DropletHost?
    private let activitySubject = CurrentValueSubject<LiveActivityState?, Never>(nil)
    private var run: FFmpegRun?
    private var task: Task<Void, Never>?
    private var hudTask: Task<Void, Never>?
    private var lastPublishedPercent = -1

    var progress: Double {
        if case .converting(_, let value) = state { return value }
        return 0
    }

    // MARK: Lifecycle

    public func activate(host: DropletHost) throws {
        self.host = host
        if FFmpegLocator.find("ffmpeg") == nil {
            host.log.info("ffmpeg not found in the usual locations")
        }
    }

    public func deactivate() {
        run?.cancel()
        task?.cancel()
        hudTask?.cancel()
        run = nil
        task = nil
        hudTask = nil
        activitySubject.send(nil)
        host?.hud.dismiss(id: "result")
        host = nil
    }

    // MARK: Conversion

    func chooseVideo() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.mpeg4Movie, .quickTimeMovie, .png, .jpeg]
            + [UTType(filenameExtension: "webm")].compactMap { $0 }
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.begin { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            Task { @MainActor in self?.convert(url) }
        }
    }

    func convert(_ input: URL) {
        guard !state.isConverting else { return }
        guard Self.supportedExtensions.contains(input.pathExtension.lowercased()) else {
            state = .failed("Drop a video (MP4, WebM) or an image (PNG, JPG)")
            return
        }
        guard let ffmpeg = FFmpegLocator.find("ffmpeg") else {
            fail("FFmpeg not found. Run: brew install ffmpeg")
            return
        }

        let output = uniqueOutput(for: input)
        let run = FFmpegRun()
        self.run = run
        lastPublishedPercent = -1
        host?.hud.dismiss(id: "result")
        state = .converting(name: input.lastPathComponent, progress: 0)
        publishActivity(percent: 0)

        task = Task { [weak self] in
            do {
                try await run.convert(
                    ffmpeg: ffmpeg,
                    ffprobe: FFmpegLocator.find("ffprobe"),
                    input: input,
                    output: output
                ) { value in
                    Task { @MainActor in self?.progressChanged(value) }
                }
                let bytes = (try? output.resourceValues(forKeys: [.fileSizeKey]).fileSize).flatMap { $0 } ?? 0
                self?.finish(output: output, bytes: Int64(bytes))
            } catch is CancellationError {
                self?.cancelled()
            } catch {
                self?.fail(error.localizedDescription)
            }
        }
    }

    func cancel() {
        run?.cancel()
    }

    private func progressChanged(_ value: Double) {
        guard case .converting(let name, _) = state else { return }
        state = .converting(name: name, progress: value)
        let percent = Int(value * 100)
        if percent != lastPublishedPercent {
            publishActivity(percent: percent)
        }
    }

    private func finish(output: URL, bytes: Int64) {
        run = nil
        state = .done(output: output, bytes: bytes)
        activitySubject.send(nil) // release the compact seat the moment the work ends
        let size = ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
        presentResult(
            symbol: "checkmark.circle.fill",
            strip: "GIF",
            title: "Your .GIF is ready!",
            detail: "\(output.lastPathComponent) · \(size)"
        )
    }

    private func fail(_ message: String) {
        run = nil
        state = .failed(message)
        activitySubject.send(nil)
        presentResult(
            symbol: "exclamationmark.triangle.fill",
            strip: "Error",
            title: "Conversion failed",
            detail: String(message.prefix(80))
        )
    }

    private func cancelled() {
        run = nil
        state = .idle
        activitySubject.send(nil)
    }

    private func uniqueOutput(for input: URL) -> URL {
        let directory = input.deletingLastPathComponent()
        let base = input.deletingPathExtension().lastPathComponent
        var candidate = directory.appendingPathComponent("\(base).gif")
        var index = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = directory.appendingPathComponent("\(base) \(index).gif")
            index += 1
        }
        return candidate
    }

    // MARK: Live activity publishing

    private func publishActivity(percent: Int) {
        lastPublishedPercent = percent
        activitySubject.send(
            LiveActivityState(
                priority: 200,
                accessibilityTitle: "Converting to GIF, \(percent) percent",
                isInteractive: false,
                // Visible without hovering the notch while the work runs. Released on finish.
                joinsPersistentActivitySet: true
            )
        )
    }

    // MARK: Completion HUD (the notch expands)

    private func presentResult(symbol: String, strip: String, title: String, detail: String) {
        guard let hud = host?.hud else { return }

        func request(expanded: Bool) -> DropletHUDRequest {
            DropletHUDRequest(
                id: "result",
                duration: expanded ? 6 : 2,
                accessibilityLabel: "\(title). \(detail)",
                isExpanded: expanded,
                expandedContentHeight: 56,
                content: { ResultStrip(symbol: symbol, label: strip) },
                expanded: { ResultCard(symbol: symbol, title: title, detail: detail) }
            )
        }

        // Same id twice: the strip morphs into the card on the host's own spring.
        hud.present(request(expanded: false))
        hudTask?.cancel()
        hudTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(450))
            guard !Task.isCancelled else { return }
            hud.present(request(expanded: true))
        }
    }
}

// MARK: - HUD views

/// Strip: content at the two outer edges, nothing in the middle (that is the camera housing).
private struct ResultStrip: View {
    let symbol: String
    let label: String

    var body: some View {
        HStack {
            Image(systemName: symbol)
                .font(.system(size: DroppyLiveActivityMetrics.iconSize, weight: .medium))
            Spacer(minLength: 0)
            Text(label)
                .font(.system(size: DroppyLiveActivityMetrics.labelFontSize, weight: .medium, design: .rounded))
        }
        .foregroundStyle(AdaptiveColors.notchSurfacePrimaryText)
    }
}

private struct ResultCard: View {
    let symbol: String
    let title: String
    let detail: String

    var body: some View {
        HStack(spacing: DroppySpacing.smd) {
            Image(systemName: symbol)
                .font(.system(size: 24, weight: .medium))
                .foregroundStyle(AdaptiveColors.notchSurfacePrimaryText)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(AdaptiveColors.notchSurfacePrimaryText)
                Text(detail)
                    .font(.system(size: 12))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .foregroundStyle(AdaptiveColors.notchSurfaceSecondaryText)
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Live activity

extension GifDropDroplet: LiveActivityProviding {

    @MainActor
    public func makeExpanded(context: LiveActivityContext) -> AnyView {
        AnyView(EmptyView())
    }

    public var liveActivityState: AnyPublisher<LiveActivityState?, Never> {
        activitySubject.eraseToAnyPublisher()
    }

    public func makeCompactLeading() -> AnyView {
        AnyView(CompactLeading(droplet: self))
    }

    public func makeCompactTrailing() -> AnyView {
        AnyView(CompactTrailing(droplet: self))
    }
}

private struct CompactLeading: View {
    @ObservedObject var droplet: GifDropDroplet

    var body: some View {
        ZStack {
            Circle().stroke(AdaptiveColors.notchSurfaceTertiaryText, lineWidth: 2)
            Circle()
                .trim(from: 0, to: droplet.progress)
                .stroke(AdaptiveColors.notchSurfacePrimaryText,
                        style: StrokeStyle(lineWidth: 2, lineCap: .round))
                .rotationEffect(.degrees(-90))
        }
        .frame(width: DroppyLiveActivityMetrics.iconSize, height: DroppyLiveActivityMetrics.iconSize)
        .padding(.trailing, DroppySpacing.sm)
    }
}

private struct CompactTrailing: View {
    @ObservedObject var droplet: GifDropDroplet

    var body: some View {
        Text("\(Int(droplet.progress * 100))%")
            .font(.system(size: DroppyLiveActivityMetrics.labelFontSize, weight: .medium, design: .rounded))
            .monospacedDigit()
            .foregroundStyle(AdaptiveColors.notchSurfacePrimaryText)
            .padding(.leading, DroppySpacing.sm)
    }
}

// MARK: - Shelf widget

extension GifDropDroplet: ShelfWidgetProviding {
    public var widgetDescriptors: [ShelfWidgetDescriptor] {
        [
            ShelfWidgetDescriptor(
                id: "converter",
                title: "Video to GIF",
                systemImage: "film",
                layoutTraits: ShelfWidgetLayoutTraits(
                    preferredSoloWidth: 420,
                    preferredPairedWidth: 210,
                    contentHeight: .fixed(110)
                ),
                searchKeywords: ["gif", "mp4", "video", "ffmpeg", "convert"]
            )
        ]
    }

    public func makeWidgetView(_ id: ShelfWidgetID, context: ShelfWidgetContext) -> AnyView {
        AnyView(ConverterWidget(droplet: self, context: context))
    }

    public func makeWidgetSettingsPopover(_ id: ShelfWidgetID) -> AnyView? { nil }
}

extension GifDropDroplet: HUDPresenting {}

private struct ConverterWidget: View {
    @ObservedObject var droplet: GifDropDroplet
    let context: ShelfWidgetContext

    var body: some View {
        VStack(alignment: .leading, spacing: DroppySpacing.sm) {
            header
            if context.isCompact { compactBody } else { fullBody }
            Spacer(minLength: 0)
        }
        .padding(context.contentInsets)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .dropDestination(for: URL.self) { urls, _ in
            guard let url = urls.first else { return false }
            droplet.convert(url)
            return true
        }
    }

    private var header: some View {
        HStack(spacing: DroppySpacing.xsm) {
            Image(systemName: "film").font(.system(size: 12, weight: .medium))
            Text("Video to GIF").font(.system(size: 12, weight: .semibold))
            Spacer(minLength: 0)
            if droplet.state.isConverting {
                Button { droplet.cancel() } label: { Image(systemName: "xmark") }
                    .buttonStyle(DroppyCircleButtonStyle(size: 20))
            }
        }
        .foregroundStyle(AdaptiveColors.notchSurfaceSecondaryText)
    }

    @ViewBuilder private var fullBody: some View {
        switch droplet.state {
        case .idle:
            VStack(alignment: .leading, spacing: DroppySpacing.sm) {
                Text("Please select a Video or Image")
                    .font(.system(size: 13))
                    .foregroundStyle(AdaptiveColors.notchSurfacePrimaryText)
                Button("Choose video…") { droplet.chooseVideo() }
                    .buttonStyle(DroppyQuietButtonStyle())
            }
        case .converting(let name, let progress):
            VStack(alignment: .leading, spacing: DroppySpacing.sm) {
                HStack {
                    Text(name)
                        .lineLimit(1).truncationMode(.middle)
                        .foregroundStyle(AdaptiveColors.notchSurfaceSecondaryText)
                    Spacer(minLength: DroppySpacing.md)
                    Text("\(Int(progress * 100))%")
                        .monospacedDigit()
                        .foregroundStyle(AdaptiveColors.notchSurfacePrimaryText)
                }
                .font(.system(size: 12))
                ProgressBar(value: progress)
            }
        case .done(let output, let bytes):
            VStack(alignment: .leading, spacing: DroppySpacing.sm) {
                Text("\(output.lastPathComponent) · \(ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file))")
                    .font(.system(size: 12))
                    .lineLimit(1).truncationMode(.middle)
                    .foregroundStyle(AdaptiveColors.notchSurfacePrimaryText)
                HStack(spacing: DroppySpacing.sm) {
                    Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([output]) }
                        .buttonStyle(DroppyQuietButtonStyle())
                    Button("Convert another") { droplet.chooseVideo() }
                        .buttonStyle(DroppyQuietButtonStyle())
                }
            }
        case .failed(let message):
            VStack(alignment: .leading, spacing: DroppySpacing.sm) {
                Text(message)
                    .font(.system(size: 12))
                    .lineLimit(3)
                    .foregroundStyle(AdaptiveColors.notchSurfacePrimaryText)
                Button("Choose video…") { droplet.chooseVideo() }
                    .buttonStyle(DroppyQuietButtonStyle())
            }
        }
    }

    /// Paired slot: room for one number, not a shorter list.
    @ViewBuilder private var compactBody: some View {
        switch droplet.state {
        case .converting(_, let progress):
            Text("\(Int(progress * 100))%")
                .font(.system(size: 28, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(AdaptiveColors.notchSurfacePrimaryText)
        case .done:
            Text("Your .GIF is ready!").font(.system(size: 13))
                .foregroundStyle(AdaptiveColors.notchSurfacePrimaryText)
        case .failed:
            Text("Failed").font(.system(size: 13))
                .foregroundStyle(AdaptiveColors.notchSurfacePrimaryText)
        case .idle:
            Text("Please select a Video or Image").font(.system(size: 13))
                .foregroundStyle(AdaptiveColors.notchSurfaceSecondaryText)
        }
    }
}

/// Flat bar: solid fills, no outline, no gradient.
private struct ProgressBar: View {
    let value: Double

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(AdaptiveColors.notchSurfaceCardFill)
                Capsule()
                    .fill(AdaptiveColors.notchSurfacePrimaryText)
                    .frame(width: max(4, proxy.size.width * value))
            }
        }
        .frame(height: 6)
    }
}