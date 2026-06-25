import AppKit
import Foundation
import Observation
import UniformTypeIdentifiers
import UserNotifications

@MainActor
@Observable
final class DownloaderStore {
    static let moderateBatchWarningCount = 10
    static let highBatchWarningCount = 25
    static let minimumCooldownSeconds: UInt64 = 8
    static let maximumCooldownSeconds: UInt64 = 18

    var pendingText = ""
    var items: [DownloadItem] = []
    var selectedFolder: URL = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first ?? URL(fileURLWithPath: NSHomeDirectory())
    var isRunning = false
    var globalMessage = "Ready"
    var isRateLimitEnabled = true
    var downloadAlert: DownloadAlert?

    private let runner = DownloadRunner()
    private var activeBatchTask: Task<Void, Never>?
    private var isCancellationRequested = false

    private var ytDLPPath: String {
        ToolLocator.executablePath(named: "yt-dlp")
    }

    private var ffmpegPath: String {
        ToolLocator.executablePath(named: "ffmpeg")
    }

    private var ffprobePath: String {
        ToolLocator.executablePath(named: "ffprobe")
    }

    var unfinishedCount: Int {
        items.filter { !$0.status.isFinished }.count
    }

    var hasFailedItems: Bool {
        items.contains { $0.status.isFailed }
    }

    var hasFinishedItems: Bool {
        items.contains { $0.status.isFinished }
    }

    var canStart: Bool {
        !isRunning && unfinishedCount > 0
    }

    var canDisableRateLimit: Bool {
        unfinishedCount < Self.moderateBatchWarningCount
    }

    var rateLimitControlMessage: String {
        canDisableRateLimit ? "Can be turned off for short batches." : "Required for batches of \(Self.moderateBatchWarningCount)+ queued links."
    }

    var dependencySummary: String {
        let ytdlp = FileManager.default.isExecutableFile(atPath: ytDLPPath) ? "yt-dlp ready" : "yt-dlp missing"
        let ffmpeg = FileManager.default.isExecutableFile(atPath: ffmpegPath) ? "ffmpeg ready" : "ffmpeg missing"
        let ffprobe = FileManager.default.isExecutableFile(atPath: ffprobePath) ? "ffprobe ready" : "ffprobe missing"
        return "\(ytdlp) · \(ffmpeg) · \(ffprobe)"
    }

    var rateLimitWarning: String? {
        guard isRateLimitEnabled else { return nil }
        let remainingCount = unfinishedCount

        if remainingCount >= Self.highBatchWarningCount {
            return "High rate-limit risk: \(remainingCount) queued links. The app downloads sequentially with cooldowns, but large batches from the same site can still be throttled."
        }

        if remainingCount >= Self.moderateBatchWarningCount {
            return "Rate-limit caution: \(remainingCount) queued links. Downloads are slowed automatically to reduce platform throttling risk."
        }

        return nil
    }

    func addLinks(kind: DownloadKind) {
        guard !isRunning else { return }

        let links = pendingText
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        guard !links.isEmpty else { return }

        let existing = Set(items.map(\.url))
        let newItems = links
            .filter { !existing.contains($0) }
            .map { DownloadItem(url: $0, kind: kind) }

        items.append(contentsOf: newItems)
        if !canDisableRateLimit {
            isRateLimitEnabled = true
        }
        pendingText = ""

        if let rateLimitWarning {
            globalMessage = rateLimitWarning
        } else {
            globalMessage = newItems.isEmpty ? "No new links added" : "Added \(newItems.count) link\(newItems.count == 1 ? "" : "s")"
        }
    }

    func removeItems(at offsets: IndexSet) {
        guard !isRunning else { return }
        items.remove(atOffsets: offsets)
    }

    func removeItem(id: DownloadItem.ID) {
        guard !isRunning else { return }
        items.removeAll { $0.id == id }
    }

    func clearFinished() {
        guard !isRunning else { return }
        items.removeAll { $0.status.isFinished }
    }

    func isStartingNext(_ item: DownloadItem) -> Bool {
        guard isRunning else { return false }
        guard !items.contains(where: { if case .running = $0.status { return true } else { return false } }) else {
            return false
        }

        let firstPending = items.first(where: { !$0.status.isFinished })
        return firstPending?.id == item.id
    }

    func retryFailedItems() {
        guard !isRunning else { return }
        for index in items.indices {
            if case .failed = items[index].status {
                items[index].status = .queued
                items[index].log = ""
                items[index].activityText = ""
                items[index].progressPercent = nil
                items[index].progressText = ""
            }
        }
    }

    func chooseFolder() {
        guard !isRunning else { return }

        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = selectedFolder
        panel.prompt = "Use Folder"

        if panel.runModal() == .OK, let url = panel.url {
            selectedFolder = url
            globalMessage = "Download folder set"
        }
    }

    func openTextFile() {
        guard !isRunning else { return }

        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.plainText]
        panel.prompt = "Open"
        panel.message = "Choose a .txt file containing one link per line."

        guard panel.runModal() == .OK, let url = panel.url else { return }

        do {
            let fileText = try String(contentsOf: url, encoding: .utf8)
            pendingText = fileText.hasSuffix("\n") ? fileText : "\(fileText)\n"

            let linkCount = pendingText
                .components(separatedBy: .newlines)
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
                .count

            globalMessage = "Loaded \(linkCount) link\(linkCount == 1 ? "" : "s") from \(url.lastPathComponent)"
        } catch {
            globalMessage = "Could not open \(url.lastPathComponent): \(error.localizedDescription)"
        }
    }

    func startBatch() {
        guard !isRunning else { return }

        guard FileManager.default.isExecutableFile(atPath: ytDLPPath) else {
            globalMessage = "Install yt-dlp with Homebrew or add it to PATH"
            return
        }

        guard FileManager.default.isExecutableFile(atPath: ffmpegPath) else {
            globalMessage = "Install ffmpeg with Homebrew or add it to PATH"
            return
        }

        guard FileManager.default.isExecutableFile(atPath: ffprobePath) else {
            globalMessage = "Install ffprobe with Homebrew or add it to PATH"
            return
        }

        isRunning = true
        isCancellationRequested = false
        activeBatchTask = Task { await runQueue() }
    }

    func cancelBatch() {
        guard isRunning else { return }

        isCancellationRequested = true
        isRunning = false
        globalMessage = "Stopping batch..."
        activeBatchTask?.cancel()

        if let index = items.firstIndex(where: { $0.status == .running }) {
            items[index].status = .failed("Cancelled")
            items[index].progressPercent = nil
            items[index].activityText = "Cancelled"
        }

        Task { await runner.cancel() }
    }

    private func runQueue() async {
        defer {
            isRunning = false
            activeBatchTask = nil
            if isCancellationRequested && downloadAlert == nil {
                globalMessage = "Batch cancelled"
            }
        }

        let queueIndices = items.indices.filter { !items[$0].status.isFinished }
        guard !queueIndices.isEmpty else {
            globalMessage = "Nothing to download"
            return
        }

        var completedCount = 0
        var failedCount = 0

        for (position, index) in queueIndices.enumerated() {
            guard !Task.isCancelled, isRunning, !isCancellationRequested else { return }
            items[index].status = .running
            items[index].progressPercent = 0
            items[index].progressText = "0%"
            items[index].activityText = "Starting"
            items[index].log = ""
            globalMessage = "Downloading \(index + 1) of \(items.count)"

            do {
                let output = try await runYTDLP(for: index)
                items[index].status = .finished
                items[index].progressPercent = 100
                items[index].progressText = "100%"
                items[index].activityText = "Complete"
                items[index].log = output
                completedCount += 1
            } catch {
                guard !isCancellationRequested else { return }
                let failure = downloadFailureDetails(from: error)
                failedCount += 1
                items[index].status = .failed(failure.rowStatus)
                items[index].progressPercent = nil
                items[index].activityText = failure.title
                items[index].log = items[index].log.appendingFailureMessage(failure.message)
                globalMessage = failure.stopsBatch ? "Batch stopped" : "Download failed"

                if failure.stopsBatch {
                    isCancellationRequested = true
                    isRunning = false
                    downloadAlert = DownloadAlert(title: failure.title, message: failure.message)
                    return
                }
            }

            let hasMoreItems = position < queueIndices.count - 1
            if hasMoreItems && isRunning && !isCancellationRequested && isRateLimitEnabled {
                await cooldownBeforeNextDownload()
            }
        }

        if !isCancellationRequested {
            if failedCount > 0 {
                globalMessage = "Batch finished with \(failedCount) failure\(failedCount == 1 ? "" : "s")"
            } else {
                globalMessage = "Batch complete"
            }
            notifyBatchComplete(downloadCount: completedCount, failedCount: failedCount)
        }
    }

    private func runYTDLP(for index: Int) async throws -> String {
        try await runner.run(
            executablePath: ytDLPPath,
            arguments: arguments(for: items[index]),
            onOutput: { [weak self] output in
                guard let self else { return }
                Task { @MainActor in
                    self.items[index].log += output
                    self.updateActivity(from: output, for: index)
                    self.updateProgress(from: output, for: index)
                    self.updateMetadata(from: output, for: index)
                }
            }
        )
    }

    private func cooldownBeforeNextDownload() async {
        let seconds = UInt64.random(in: Self.minimumCooldownSeconds...Self.maximumCooldownSeconds)

        do {
            for remainingSeconds in stride(from: seconds, through: 1, by: -1) {
                guard !Task.isCancelled, isRunning, !isCancellationRequested else { return }
                globalMessage = "Cooling down for \(remainingSeconds)s to reduce rate-limit risk"
                try await Task.sleep(for: .seconds(1))
            }
        } catch {
            globalMessage = "Cooldown interrupted"
        }
    }

    private func notifyBatchComplete(downloadCount: Int, failedCount: Int) {
        let content = UNMutableNotificationContent()
        content.title = "BatchClip"
        if failedCount > 0 {
            content.body = "\(downloadCount) complete, \(failedCount) failed."
        } else {
            content.body = downloadCount == 1 ? "Download complete." : "\(downloadCount) downloads complete."
        }
        content.sound = .default

        let request = UNNotificationRequest(
            identifier: "batch-complete-\(UUID().uuidString)",
            content: content,
            trigger: nil
        )

        UNUserNotificationCenter.current().add(request)
    }
}

actor DownloadRunner {
    private var activeProcess: Process?

    func cancel() {
        activeProcess?.terminate()
        activeProcess = nil
    }

    func run(
        executablePath: String,
        arguments: [String],
        onOutput: @escaping @Sendable (String) -> Void = { _ in }
    ) async throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executablePath)
        process.arguments = arguments
        process.environment = [
            "PATH": ToolLocator.processSearchPath
        ]

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        activeProcess = process

        let outputCollector = OutputCollector()
        let outputHandle = pipe.fileHandleForReading
        outputHandle.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty, let chunk = String(data: data, encoding: .utf8) else { return }
            Task { await outputCollector.append(chunk) }
            onOutput(chunk)
        }

        do {
            try process.run()
        } catch {
            outputHandle.readabilityHandler = nil
            activeProcess = nil
            throw error
        }

        process.waitUntilExit()
        outputHandle.readabilityHandler = nil
        activeProcess = nil

        let remainingData = outputHandle.readDataToEndOfFile()
        let remaining = String(data: remainingData, encoding: .utf8) ?? ""
        await outputCollector.append(remaining)
        if !remaining.isEmpty {
            onOutput(remaining)
        }
        let outputText = await outputCollector.value

        if process.terminationStatus != 0 {
            throw DownloadError.processFailed(outputText.trimmedFallback("yt-dlp exited with status \(process.terminationStatus)"))
        }

        return outputText.trimmedFallback("Download completed")
    }
}

actor OutputCollector {
    private(set) var value = ""

    func append(_ chunk: String) {
        value += chunk
    }
}

struct ToolLocator {
    static let defaultSearchDirectories = [
        "/opt/homebrew/bin",
        "/usr/local/bin",
        "/usr/bin",
        "/bin",
        "/usr/sbin",
        "/sbin"
    ]

    static var processSearchPath: String {
        defaultSearchDirectories.joined(separator: ":")
    }

    static func executablePath(
        named name: String,
        searchDirectories: [String] = defaultSearchDirectories,
        environmentPath: String? = ProcessInfo.processInfo.environment["PATH"]
    ) -> String {
        let environmentDirectories = (environmentPath ?? "")
            .split(separator: ":")
            .map(String.init)

        for directory in orderedUnique(searchDirectories + environmentDirectories) {
            let candidate = URL(fileURLWithPath: directory)
                .appendingPathComponent(name)
                .path

            if FileManager.default.isExecutableFile(atPath: candidate) {
                return candidate
            }
        }

        return URL(fileURLWithPath: searchDirectories.first ?? "/usr/bin")
            .appendingPathComponent(name)
            .path
    }

    private static func orderedUnique(_ values: [String]) -> [String] {
        var seen = Set<String>()
        var result: [String] = []

        for value in values where !value.isEmpty && !seen.contains(value) {
            seen.insert(value)
            result.append(value)
        }

        return result
    }
}

private extension DownloaderStore {
    func arguments(for item: DownloadItem) -> [String] {
        let outputTemplate = selectedFolder
            .appendingPathComponent("%(title).180B [%(id)s].%(ext)s")
            .path

        var args = [
            "--ffmpeg-location", ffmpegPath,
            "--print", "title:%(title)s",
            "--print", "thumbnail:%(thumbnail)s",
            "--no-simulate",
            "--newline",
            "--progress",
            "--restrict-filenames",
            "-o", outputTemplate
        ]

        if item.allowsPlaylist {
            args.append("--yes-playlist")
        } else {
            args.append("--no-playlist")
        }

        if isRateLimitEnabled {
            args += [
                "--sleep-requests", "1.5",
                "--sleep-interval", "8",
                "--max-sleep-interval", "18",
                "--retry-sleep", "http:exp=5:60",
                "--retry-sleep", "fragment:exp=2:20",
            ]
        }

        switch item.kind {
        case .video:
            let transcodeCommand = """
            after_move:/bin/sh -c 'file="$1"; codec="$("\(ffprobePath)" -v error -select_streams v:0 -show_entries stream=codec_name -of default=nw=1:nk=1 "$file")"; if [ "$codec" = "h264" ]; then exit 0; fi; tmp="${file%.*}.h264.mp4"; "\(ffmpegPath)" -y -i "$file" -map 0:v:0 -map 0:a? -c:v libx264 -preset medium -crf 18 -c:a aac -b:a 192k -movflags +faststart "$tmp" && mv "$tmp" "$file"' sh {}
            """.trimmingCharacters(in: .whitespacesAndNewlines)

            args += [
                "-f", "bv*[vcodec^=avc1][ext=mp4]+ba[ext=m4a]/b[vcodec^=avc1][ext=mp4]/bv*+ba/b",
                "-S", "vcodec:h264,ext:mp4:m4a",
                "--merge-output-format", "mp4",
                "--exec", transcodeCommand
            ]
        case .audio:
            args += [
                "-x",
                "--audio-format", "mp3",
                "--audio-quality", "320K"
            ]
        }

        args.append(item.url)
        return args
    }

    func updateProgress(from output: String, for index: Int) {
        guard case .running = items[index].status else { return }

        let components = output
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { $0.hasSuffix("%") }

        for part in components.reversed() {
            let candidate = String(part.dropLast())
            let normalized = candidate.replacingOccurrences(of: ",", with: ".")
            if let progress = Double(normalized), (0...100).contains(progress) {
                items[index].progressPercent = progress
                items[index].progressText = "\(Int(progress.rounded()))%"
                return
            }
        }
    }

    func updateActivity(from output: String, for index: Int) {
        guard case .running = items[index].status else { return }

        for line in output.components(separatedBy: .newlines).reversed() {
            let activity = activityDescription(for: line)
            if !activity.isEmpty {
                items[index].activityText = activity
                return
            }
        }
    }

    func activityDescription(for line: String) -> String {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        let lowercased = trimmed.lowercased()

        if trimmed.hasPrefix("title:") || trimmed.hasPrefix("thumbnail:") {
            return "Reading metadata"
        }

        if lowercased.contains("extracting url") ||
            lowercased.contains("downloading webpage") ||
            lowercased.contains("downloading api json") ||
            lowercased.contains("downloading player") ||
            lowercased.contains("downloading ios player api json") ||
            lowercased.contains("downloading android player api json") {
            return "Grabbing metadata"
        }

        if lowercased.hasPrefix("[info]") {
            return "Selecting format"
        }

        if lowercased.hasPrefix("[download]") {
            if lowercased.contains("destination:") {
                return "Starting download"
            }

            if lowercased.contains("has already been downloaded") ||
                lowercased.contains("100%") {
                return "Download complete"
            }

            return "Downloading"
        }

        if lowercased.hasPrefix("[merger]") {
            return "Merging audio and video"
        }

        if lowercased.hasPrefix("[ffmpeg]") ||
            lowercased.hasPrefix("[videoconvertor]") {
            return "Converting video"
        }

        if lowercased.hasPrefix("[extractaudio]") {
            return "Extracting audio"
        }

        if lowercased.hasPrefix("[movefiles]") {
            return "Moving file"
        }

        if lowercased.hasPrefix("[exec]") {
            return "Checking final file"
        }

        if lowercased.contains("deleting original file") {
            return "Cleaning up"
        }

        return ""
    }

    func updateMetadata(from output: String, for index: Int) {
        applyMetadata(parseMetadata(from: output), to: index)
    }

    func applyMetadata(_ metadata: (title: String?, thumbnailURL: String?), to index: Int) {
        if let title = metadata.title, !title.isEmpty {
            items[index].title = title
        }

        if let thumbnailURL = metadata.thumbnailURL, !thumbnailURL.isEmpty {
            items[index].thumbnailURL = thumbnailURL
        }
    }

    func parseMetadata(from output: String) -> (title: String?, thumbnailURL: String?) {
        var title: String?
        var thumbnailURL: String?
        let lines = output.components(separatedBy: .newlines)

        for line in lines {
            if line.hasPrefix("title:") {
                let value = String(line.dropFirst("title:".count))
                if !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    title = value.trimmingCharacters(in: .whitespacesAndNewlines)
                }
            } else if line.hasPrefix("thumbnail:") {
                let value = String(line.dropFirst("thumbnail:".count))
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if !value.isEmpty {
                    thumbnailURL = value
                }
            }
        }

        return (title, thumbnailURL)
    }

    func downloadFailureDetails(from error: Error) -> DownloadFailureDetails {
        DownloadFailureClassifier.details(from: error.localizedDescription)
    }
}

struct DownloadFailureClassifier {
    static func details(from message: String) -> DownloadFailureDetails {
        let normalized = message.lowercased()

        if normalized.contains("sign in to confirm") ||
            normalized.contains("not a bot") ||
            normalized.contains("confirm you're not a bot") ||
            normalized.contains("confirm you’re not a bot") ||
            normalized.contains("use --cookies-from-browser") ||
            normalized.contains("use --cookies") {
            return DownloadFailureDetails(
                title: "YouTube Bot Check",
                message: "YouTube is asking to confirm this is not a bot. The batch has been stopped to avoid additional automated requests. Wait before retrying, reduce the batch size, and keep rate-limiting enabled.",
                rowStatus: "Bot check",
                stopsBatch: true
            )
        }

        if normalized.contains("too many requests") ||
            normalized.contains("http error 429") ||
            normalized.contains("rate-limit") ||
            normalized.contains("rate limit") ||
            normalized.contains("throttled") {
            return DownloadFailureDetails(
                title: "Rate Limit Detected",
                message: "The site appears to be rate-limiting requests. The batch has been stopped to avoid additional automated requests. Wait before retrying, reduce the batch size, and keep rate-limiting enabled.",
                rowStatus: "Rate limited",
                stopsBatch: true
            )
        }

        if normalized.contains("[twitter]") &&
            (normalized.contains("no video could be found") ||
                normalized.contains("video #") && normalized.contains("is unavailable")) {
            return DownloadFailureDetails(
                title: "No X Video Found",
                message: "X/Twitter did not expose a downloadable video for this post. The post may be private, removed, restricted, or not publicly serving video media.",
                rowStatus: "No video found",
                stopsBatch: false
            )
        }

        return DownloadFailureDetails(
            title: "Download Failed",
            message: message,
            rowStatus: "Failed",
            stopsBatch: false
        )
    }
}

struct DownloadAlert: Identifiable, Equatable {
    let id = UUID()
    var title: String
    var message: String
}

struct DownloadFailureDetails {
    var title: String
    var message: String
    var rowStatus: String
    var stopsBatch: Bool
}

enum DownloadError: LocalizedError {
    case processFailed(String)

    var errorDescription: String? {
        switch self {
        case .processFailed(let message): message
        }
    }
}

private extension String {
    func trimmedFallback(_ fallback: String) -> String {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? fallback : trimmed
    }

    func appendingFailureMessage(_ message: String) -> String {
        let trimmedLog = trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedMessage = message.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !trimmedMessage.isEmpty else { return self }
        guard !trimmedLog.isEmpty else { return trimmedMessage }
        return "\(trimmedLog)\n\n\(trimmedMessage)"
    }
}
