import Foundation

/// Finds the ffmpeg / ffprobe binaries. Droppy is not a login shell, so PATH is not reliable.
enum FFmpegLocator {
    static func find(_ tool: String) -> URL? {
        for dir in ["/opt/homebrew/bin", "/usr/local/bin", "/opt/local/bin", "/usr/bin"] {
            let path = "\(dir)/\(tool)"
            if FileManager.default.isExecutableFile(atPath: path) {
                return URL(fileURLWithPath: path)
            }
        }
        return nil
    }
}

enum GifError: LocalizedError {
    case ffmpegFailed(String)

    var errorDescription: String? {
        switch self {
        case .ffmpegFailed(let message):
            message.isEmpty ? "FFmpeg failed" : message
        }
    }
}

/// Splits a byte stream into lines.
private final class LineBuffer: @unchecked Sendable {
    private var pending = Data()

    func append(_ data: Data) -> [String] {
        pending.append(data)
        var lines: [String] = []
        while let newline = pending.firstIndex(of: 0x0A) {
            lines.append(String(decoding: pending[pending.startIndex..<newline], as: UTF8.self))
            pending.removeSubrange(pending.startIndex...newline)
        }
        return lines
    }
}

/// Keeps the tail of stderr for error messages.
private final class ErrorTail: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()

    func append(_ chunk: Data) {
        lock.lock(); defer { lock.unlock() }
        data.append(chunk)
        if data.count > 2048 { data = data.suffix(2048) }
    }

    var text: String {
        lock.lock(); defer { lock.unlock() }
        return String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// One conversion: two ffmpeg passes (palette, then GIF) so the colours are good.
final class FFmpegRun: @unchecked Sendable {
    private let lock = NSLock()
    private var process: Process?
    private var cancelled = false

    func cancel() {
        lock.lock()
        cancelled = true
        let running = process
        lock.unlock()
        running?.terminate()
    }

    private var isCancelled: Bool {
        lock.lock(); defer { lock.unlock() }
        return cancelled
    }

    private func setProcess(_ newProcess: Process) {
        lock.lock()
        process = newProcess
        lock.unlock()
    }

    func convert(
        ffmpeg: URL,
        ffprobe: URL?,
        input: URL,
        output: URL,
        fps: Int = 15,
        maxWidth: Int = 640,
        onProgress: @escaping @Sendable (Double) -> Void
    ) async throws {
        let duration = await Self.probeDuration(ffprobe: ffprobe, input: input)

        let work = FileManager.default.temporaryDirectory
            .appendingPathComponent("gifdrop-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: work) }
        let palette = work.appendingPathComponent("palette.png")

        let scale = "scale=w='min(\(maxWidth),iw)':h=-1:flags=lanczos"
        let common = ["-y", "-nostdin", "-hide_banner", "-loglevel", "error",
                      "-progress", "pipe:1", "-nostats"]

        do {
            // Pass 1: build the palette. The stream is also teed to a null muxer so
            // ffmpeg keeps reporting out_time while it reads the file.
            try await runFFmpeg(ffmpeg, common + [
                "-i", input.path,
                "-filter_complex",
                "[0:v]fps=\(fps),\(scale),split=2[a][b];[a]palettegen=stats_mode=diff[p]",
                "-map", "[p]", "-frames:v", "1", "-update", "1", palette.path,
                "-map", "[b]", "-f", "null", "-"
            ], duration: duration) { onProgress($0 * 0.3) }

            // Pass 2: encode the GIF with that palette.
            try await runFFmpeg(ffmpeg, common + [
                "-i", input.path,
                "-i", palette.path,
                "-filter_complex",
                "[0:v]fps=\(fps),\(scale)[x];[x][1:v]paletteuse=dither=bayer:bayer_scale=5",
                "-loop", "0", output.path
            ], duration: duration) { onProgress(0.3 + $0 * 0.7) }
        } catch {
            try? FileManager.default.removeItem(at: output)
            throw error
        }
        onProgress(1)
    }

    private func runFFmpeg(
        _ ffmpeg: URL,
        _ arguments: [String],
        duration: Double?,
        onProgress: @escaping @Sendable (Double) -> Void
    ) async throws {
        if isCancelled { throw CancellationError() }

        let process = Process()
        process.executableURL = ffmpeg
        process.arguments = arguments
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        process.standardInput = FileHandle.nullDevice

        let lines = LineBuffer()
        let tail = ErrorTail()

        stdout.fileHandleForReading.readabilityHandler = { handle in
            for line in lines.append(handle.availableData) {
                // out_time_us and out_time_ms are both microseconds in ffmpeg's -progress output.
                if line.hasPrefix("out_time_us=") || line.hasPrefix("out_time_ms="),
                   let raw = line.split(separator: "=").last,
                   let micros = Double(raw), let total = duration, total > 0 {
                    onProgress(min(max(micros / 1_000_000 / total, 0), 1))
                } else if line == "progress=end" {
                    onProgress(1)
                }
            }
        }
        stderr.fileHandleForReading.readabilityHandler = { handle in
            tail.append(handle.availableData)
        }

        setProcess(process)

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            process.terminationHandler = { [self] finished in
                stdout.fileHandleForReading.readabilityHandler = nil
                stderr.fileHandleForReading.readabilityHandler = nil
                if isCancelled {
                    continuation.resume(throwing: CancellationError())
                } else if finished.terminationStatus == 0 {
                    continuation.resume()
                } else {
                    continuation.resume(throwing: GifError.ffmpegFailed(tail.text))
                }
            }
            do {
                try process.run()
            } catch {
                continuation.resume(throwing: error)
            }
        }
    }

    private static func probeDuration(ffprobe: URL?, input: URL) async -> Double? {
        guard let ffprobe else { return nil }
        return await Task.detached { () -> Double? in
            let probe = Process()
            probe.executableURL = ffprobe
            probe.arguments = ["-v", "error", "-show_entries", "format=duration",
                               "-of", "default=noprint_wrappers=1:nokey=1", input.path]
            let pipe = Pipe()
            probe.standardOutput = pipe
            probe.standardError = FileHandle.nullDevice
            do { try probe.run() } catch { return nil }
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            probe.waitUntilExit()
            return Double(String(decoding: data, as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines))
        }.value
    }
}