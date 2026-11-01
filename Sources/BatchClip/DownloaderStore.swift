import AppKit
import Foundation
import Observation
import UniformTypeIdentifiers
import UserNotifications

@MainActor
@Observable
final class DownloaderStore {
    static let moderateBatchWarningCount = 10

    var pendingText = ""
    var items: [DownloadItem] = []
    var selectedFolder: URL {
        didSet { preferences?.set(selectedFolder.path, forKey: "downloadFolder") }
    }
    var isRunning = false
    var globalMessage = "Ready"
    var pacing: DownloadPacing {
        didSet { preferences?.set(pacing.rawValue, forKey: "downloadPacing") }
    }
    var isStopping = false
    @ObservationIgnored private let preferences: UserDefaults?
    let dependencies: ToolManager
    var tools: ToolPaths { dependencies.paths }
    var showingToolSetup = false
    @ObservationIgnored private let notificationsEnabled: Bool

    init(preferences: UserDefaults? = .standard, tools: ToolPaths? = nil, notificationsEnabled: Bool = true) {
        self.preferences = preferences
        self.dependencies = ToolManager(paths: tools)
        self.notificationsEnabled = notificationsEnabled
        self.pacing = preferences?.string(forKey: "downloadPacing").flatMap(DownloadPacing.init(rawValue:)) ?? .cautious
        self.selectedFolder = preferences?.string(forKey: "downloadFolder").map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory())
    }
    var downloadAlert: DownloadAlert?

    private let runner = DownloadRunner()
    private var activeBatchTask: Task<Void, Never>?
    private var isCancellationRequested = false

    private var ytDLPPath: String {
        tools.ytDLP
    }

    private var ffmpegPath: String {
        tools.ffmpeg
    }

    private var ffprobePath: String {
        tools.ffprobe
    }

    private var brewPath: String {
        ToolLocator.executablePath(named: "brew")
    }

    var unfinishedCount: Int {
        items.filter { $0.status == .queued }.count
    }

    var hasFailedItems: Bool {
        items.contains { $0.status.isFailed }
    }

    var hasFinishedItems: Bool {
        items.contains { $0.status.isFinished }
    }

    var canStart: Bool {
        !isRunning && !dependencies.isBusy && unfinishedCount > 0 && !hasMissingDependencies && !needsYouTubeSetup
    }

    var dependencySummary: String { dependencies.summary }

    var missingDependencyNames: [String] {
        ToolKind.allCases.filter { $0 != .deno && dependencies.missing.contains($0) }.map(\.rawValue)
    }

    var hasMissingDependencies: Bool { dependencies.hasMissingCoreTools }

    var needsYouTubeSetup: Bool {
        dependencies.missing.contains(.deno) && items.contains { item in
            guard item.status == .queued, let host = URL(string: item.url)?.host?.lowercased() else { return false }
            return host == "youtu.be" || host == "youtube.com" || host.hasSuffix(".youtube.com")
        }
    }

    var dependencySetupMessage: String {
        hasMissingDependencies ? "Install download tools to get started." : "Add Deno for full YouTube support."
    }

    var dependencySetupCommands: String {
        DependencyInstaller.commands(
            hasHomebrew: FileManager.default.isExecutableFile(atPath: brewPath)
        )
    }

    var rateLimitWarning: String? {
        let count = items.filter { $0.status == .queued || $0.status == .running }.count
        let hasPlaylist = items.contains { $0.allowsPlaylist && !$0.status.isFinished }
        guard count >= Self.moderateBatchWarningCount || hasPlaylist else { return nil }
        return pacing == .standard
            ? "Large batches and playlists can trigger site limits. Consider Cautious pacing."
            : "Cautious pacing is enabled. Large batches and playlists can still trigger site limits."
    }

    func addLinks(kind: DownloadKind, outputMode: OutputMode = .compatible, includePlaylist: Bool = false) {
        guard !isRunning else { return }
        let links = pendingText.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        guard !links.isEmpty else { return }
        var duplicates = 0
        var rejected: [String] = []
        var added = 0
        for link in links {
            guard let url = URL(string: link), ["https", "http"].contains(url.scheme?.lowercased() ?? ""),
                  let host = url.host, !host.isEmpty else {
                rejected.append(link)
                continue
            }
            if items.contains(where: { $0.url == link && $0.kind == kind && $0.outputMode == outputMode && $0.includePlaylist == includePlaylist }) {
                duplicates += 1
                continue
            }
            items.append(DownloadItem(url: link, kind: kind, outputMode: outputMode, includePlaylist: includePlaylist))
            added += 1
        }
        pendingText = rejected.joined(separator: "\n")
        globalMessage = "Added \(added) · \(duplicates) duplicate(s) skipped" + (rejected.isEmpty ? "" : " · \(rejected.count) invalid link(s) left in editor")
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
        guard isRunning && !isStopping else { return false }
        guard !items.contains(where: { if case .running = $0.status { return true } else { return false } }) else {
            return false
        }

        let firstPending = items.first(where: { $0.status == .queued })
        return firstPending?.id == item.id
    }

    func retryFailedItems(startImmediately: Bool = true, itemID: UUID? = nil) {
        guard !isRunning else { return }
        let failedIDs = Set(items.filter { $0.status.isFailed && (itemID == nil || $0.id == itemID) }.map(\.id))
        for index in items.indices {
            if failedIDs.contains(items[index].id) {
                items[index].status = .queued
                items[index].log = ""
                items[index].activityText = ""
                items[index].progressPercent = nil
                items[index].progressText = ""
            }
        }
        if startImmediately { startBatch(itemIDs: failedIDs) }
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

    func startBatch(itemIDs: Set<UUID>? = nil) {
        guard !isRunning, unfinishedCount > 0 else { return }

        guard !dependencies.isBusy else { return }
        guard !hasMissingDependencies, !needsYouTubeSetup,
              [ytDLPPath, ffmpegPath, ffprobePath].allSatisfy({ FileManager.default.isExecutableFile(atPath: $0) }) else {
            showMissingDependencyInstructions()
            return
        }

        let queuedIDs = items.filter { $0.status == .queued && (itemIDs?.contains($0.id) ?? true) }.map(\.id)
        guard !queuedIDs.isEmpty else { return }
        isRunning = true
        isStopping = false
        downloadAlert = nil
        isCancellationRequested = false
        activeBatchTask = Task { await runQueue(queuedIDs: queuedIDs) }
    }

    func cancelBatch() {
        guard isRunning, !isStopping else { return }
        isCancellationRequested = true
        isStopping = true
        globalMessage = "Stopping batch…"
        activeBatchTask?.cancel()
        // The task cancellation handler cancels its own active process group.
        // Keep the queue locked until runQueue's cleanup has completed.
    }

    private func runQueue(queuedIDs: [UUID]) async {
        defer {
            isRunning = false
            isStopping = false
            activeBatchTask = nil
            if isCancellationRequested && downloadAlert == nil { globalMessage = "Batch cancelled" }
        }
        let folder = selectedFolder
        let batchPacing = pacing
        var completedCount = 0
        var failedCount = 0
        for (position, id) in queuedIDs.enumerated() {
            guard !Task.isCancelled, let index = items.firstIndex(where: { $0.id == id }) else { return }
            items[index].status = .running
            items[index].log = ""
            items[index].downloadedFileURLs = []
            items[index].phaseDurations = [:]
            items[index].phaseStartedAt = nil
            items[index].setPhase(.preparing)
            globalMessage = "Processing \(position + 1) of \(queuedIDs.count)"
            let item = items[index]
            do {
                _ = try await runner.run(executablePath: ytDLPPath,
                    arguments: DownloadCommand.arguments(for: item, folder: folder, pacing: batchPacing, tools: tools)) { [weak self] line in
                    await self?.receiveOutput(line, for: id)
                }
                try Task.checkCancellation()
                if item.kind == .video && item.outputMode == .compatible {
                    let paths = items[index].downloadedFileURLs
                    for path in paths {
                        items[index].setPhase(.checking)
                        let converted = try await MediaProcessor.compatibleVideo(path, tools: tools, runner: runner) { [weak self] percent in
                            await self?.receiveConversionProgress(percent, for: id)
                        }
                        if let pathIndex = items[index].downloadedFileURLs.firstIndex(of: path) {
                            items[index].downloadedFileURLs[pathIndex] = converted
                        }
                    }
                }
                if item.kind == .audio && item.outputMode == .original {
                    let paths = items[index].downloadedFileURLs
                    for path in paths {
                        items[index].setPhase(.extractingAudio)
                        let extracted = try await MediaProcessor.originalAudio(path, tools: tools, runner: runner)
                        if let pathIndex = items[index].downloadedFileURLs.firstIndex(of: path) {
                            items[index].downloadedFileURLs[pathIndex] = extracted
                        }
                    }
                }
                try Task.checkCancellation()
                guard !items[index].downloadedFileURLs.isEmpty else {
                    throw DownloadError.processFailed("No output file was reported. Open Details for the command output.")
                }
                items[index].status = .finished
                items[index].setPhase(.complete)
                items[index].progressPercent = 100
                items[index].progressText = "100%"
                completedCount += 1
            } catch {
                items[index].finishTiming()
                items[index].progressPercent = nil
                items[index].progressText = ""
                if Task.isCancelled || isCancellationRequested {
                    items[index].status = .failed("Cancelled")
                    items[index].activityText = "Cancelled"
                    return
                }
                let failure = downloadFailureDetails(from: error)
                failedCount += 1
                items[index].status = .failed(failure.rowStatus)
                items[index].activityText = failure.title
                items[index].log = items[index].log.appendingFailureMessage(failure.message)
                if failure.stopsBatch {
                    globalMessage = "Batch stopped"
                    downloadAlert = DownloadAlert(title: failure.title, message: failure.message)
                    return
                }
            }
        }
        guard !Task.isCancelled else { return }
        globalMessage = failedCount > 0 ? "Batch finished · \(completedCount) done · \(failedCount) failed" : "Batch complete"
        if notificationsEnabled { notifyBatchComplete(downloadCount: completedCount, failedCount: failedCount) }
    }

    private func receiveOutput(_ line: String, for id: UUID) {
        guard let index = items.firstIndex(where: { $0.id == id }), items[index].status == .running else { return }
        items[index].log += line
        if items[index].log.count > 200_000 { items[index].log = String(items[index].log.suffix(100_000)) }
        guard !isStopping, let event = DownloadOutputParser.event(for: line) else { return }
        switch event {
        case .title(let title): items[index].title = title
        case .thumbnail(let thumbnail): items[index].thumbnailURL = thumbnail
        case .file(let file):
            if FileManager.default.fileExists(atPath: file.path), !items[index].downloadedFileURLs.contains(file) {
                items[index].downloadedFileURLs.append(file)
            }
        case .phase(let phase): items[index].setPhase(phase)
        case .progress(let percent, let detail):
            items[index].setPhase(.downloading)
            items[index].progressPercent = percent
            items[index].progressText = detail
        }
    }

    private func receiveConversionProgress(_ percent: Double?, for id: UUID) {
        guard !isStopping, let index = items.firstIndex(where: { $0.id == id }), items[index].status == .running else { return }
        items[index].setPhase(.converting)
        items[index].progressPercent = percent
        items[index].progressText = percent.map { "\(Int($0))%" } ?? ""
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

    private func showMissingDependencyInstructions() {
        globalMessage = "Install required tools"
        showingToolSetup = true
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
        orderedUnique(defaultSearchDirectories + (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":").map(String.init)).joined(separator: ":")
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

struct DependencyInstaller {
    static let installHomebrewCommand = #"/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)""#
    static let installToolsCommand = "brew install yt-dlp ffmpeg deno"

    static func commands(hasHomebrew: Bool) -> String {
        if hasHomebrew {
            return installToolsCommand
        }

        return """
        \(installHomebrewCommand)
        \(installToolsCommand)
        """
    }
}

private extension DownloaderStore {
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
                message: "YouTube is asking to confirm this is not a bot. The batch has been stopped to avoid additional automated requests. Wait before retrying, reduce the batch size, and use Cautious pacing.",
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
                message: "The site appears to be rate-limiting requests. The batch has been stopped to avoid additional automated requests. Wait before retrying, reduce the batch size, and use Cautious pacing.",
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
