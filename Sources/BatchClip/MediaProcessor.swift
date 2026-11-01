import Foundation

struct MediaInfo: Decodable, Sendable {
    struct Stream: Decodable, Sendable {
        var codec_name: String?
        var codec_type: String?
    }
    struct Format: Decodable, Sendable {
        var duration: String?
        var format_name: String?
    }
    var streams: [Stream]
    var format: Format?
    var duration: Double? { format?.duration.flatMap(Double.init) }
    var hasH264Video: Bool { streams.first { $0.codec_type == "video" }?.codec_name == "h264" }
    var hasCompatibleAudio: Bool { streams.filter { $0.codec_type == "audio" }.allSatisfy { $0.codec_name == "aac" } }
}

struct MediaProcessor {
    static func inspect(_ file: URL, tools: ToolPaths, runner: DownloadRunner) async throws -> MediaInfo {
        let output = try await runner.run(executablePath: tools.ffprobe, arguments: [
            "-v", "error", "-show_entries", "stream=codec_name,codec_type:format=duration,format_name", "-of", "json", file.path
        ])
        return try JSONDecoder().decode(MediaInfo.self, from: Data(output.utf8))
    }

    static func originalAudio(_ file: URL, tools: ToolPaths, runner: DownloadRunner) async throws -> URL {
        let info = try await inspect(file, tools: tools, runner: runner)
        guard let audio = info.streams.first(where: { $0.codec_type == "audio" }) else {
            throw DownloadError.processFailed("The downloaded file contains no audio stream.")
        }
        guard info.streams.contains(where: { $0.codec_type == "video" }) else { return file }
        let extensions = ["aac": "m4a", "alac": "m4a", "mp3": "mp3", "opus": "opus", "vorbis": "ogg", "flac": "flac"]
        let ext = extensions[audio.codec_name ?? ""] ?? "mka"
        let destination = file.deletingPathExtension().appendingPathExtension(ext)
        guard !FileManager.default.fileExists(atPath: destination.path) else {
            throw DownloadError.processFailed("An audio file with this name already exists; the original download was kept.")
        }
        let temporary = file.deletingLastPathComponent().appendingPathComponent(".batchclip-\(UUID().uuidString).\(ext)")
        defer { try? FileManager.default.removeItem(at: temporary) }
        _ = try await runner.run(executablePath: tools.ffmpeg, arguments: [
            "-hide_banner", "-loglevel", "error", "-nostdin", "-y", "-i", file.path, "-map", "0:a:0", "-vn", "-c:a", "copy", temporary.path
        ])
        try Task.checkCancellation()
        let verified = try await inspect(temporary, tools: tools, runner: runner)
        guard verified.streams.contains(where: { $0.codec_type == "audio" && $0.codec_name == audio.codec_name }) else {
            throw DownloadError.processFailed("Audio extraction failed validation; the original download was kept.")
        }
        try Task.checkCancellation()
        try FileManager.default.moveItem(at: temporary, to: destination)
        try FileManager.default.removeItem(at: file)
        return destination
    }

    static func compatibleVideo(
        _ file: URL, tools: ToolPaths, runner: DownloadRunner,
        onProgress: @escaping @Sendable (Double?) async -> Void
    ) async throws -> URL {
        let info = try await inspect(file, tools: tools, runner: runner)
        guard info.streams.contains(where: { $0.codec_type == "video" }) else {
            throw DownloadError.processFailed("The downloaded file contains no video stream.")
        }
        if info.hasH264Video && info.hasCompatibleAudio && file.pathExtension.lowercased() == "mp4" && (info.format?.format_name?.contains("mp4") ?? false) {
            return file
        }
        let destination = file.deletingPathExtension().appendingPathExtension("mp4")
        let temporary = file.deletingLastPathComponent().appendingPathComponent(".batchclip-\(UUID().uuidString).mp4")
        defer { try? FileManager.default.removeItem(at: temporary) }
        var arguments = ["-hide_banner", "-loglevel", "error", "-nostdin", "-y", "-i", file.path, "-map", "0:v:0", "-map", "0:a?"]
        if info.hasH264Video {
            arguments += ["-c:v", "copy"]
        } else {
            arguments += ["-c:v", "libx264", "-preset", "veryfast", "-crf", "18", "-pix_fmt", "yuv420p"]
        }
        arguments += info.hasCompatibleAudio ? ["-c:a", "copy"] : ["-c:a", "aac", "-b:a", "192k"]
        arguments += ["-movflags", "+faststart", "-progress", "pipe:1", "-nostats", temporary.path]
        await onProgress(nil)
        _ = try await runner.run(executablePath: tools.ffmpeg, arguments: arguments) { line in
            if line.hasPrefix("out_time_us="), let duration = info.duration, duration > 0,
               let micros = Double(line.dropFirst("out_time_us=".count).trimmingCharacters(in: .whitespacesAndNewlines)) {
                await onProgress(min(99, max(0, micros / 1_000_000 / duration * 100)))
            }
        }
        try Task.checkCancellation()
        let verified = try await inspect(temporary, tools: tools, runner: runner)
        guard verified.hasH264Video && verified.hasCompatibleAudio else {
            throw DownloadError.processFailed("Converted output failed validation; the original download was kept.")
        }
        try Task.checkCancellation()
        if destination != file && FileManager.default.fileExists(atPath: destination.path) {
            // Never overwrite a different pre-existing file merely because its stem matches.
            throw DownloadError.processFailed("An MP4 with this name already exists. The original download was kept: \(destination.lastPathComponent)")
        }
        if destination == file {
            // Atomic rename within the same directory; preserve the source on failure.
            guard rename(temporary.path, destination.path) == 0 else { throw POSIXError(.EIO) }
        } else {
            try FileManager.default.moveItem(at: temporary, to: destination)
            try FileManager.default.removeItem(at: file)
        }
        return destination
    }
}
