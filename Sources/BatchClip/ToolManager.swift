import Foundation
import Observation

struct ToolAvailability: Identifiable {
    let kind: ToolKind
    var path: String?
    var ready: Bool
    var detail: String
    var id: ToolKind { kind }
}

@MainActor @Observable
final class ToolManager {
    private(set) var paths: ToolPaths
    private(set) var availability: [ToolAvailability]
    private(set) var isChecking = false
    private(set) var isInstalling = false
    private(set) var isCancelling = false
    private(set) var progress = ToolInstallProgress(message: "", fraction: 0)
    private(set) var errorMessage: String?
    @ObservationIgnored let environment: ToolEnvironment
    @ObservationIgnored private var installTask: Task<Void, Never>?
    @ObservationIgnored private var operationID: UUID?

    init(paths: ToolPaths? = nil, environment: ToolEnvironment = .production) {
        self.environment = environment
        let resolved = paths ?? environment.resolve()
        self.paths = resolved
        self.availability = Self.detect(resolved)
    }

    var isBusy: Bool { isChecking || isInstalling }
    var missing: Set<ToolKind> { Set(availability.filter { !$0.ready }.map(\.kind)) }
    var hasMissingCoreTools: Bool { !missing.isDisjoint(with: [.ytDLP, .ffmpeg, .ffprobe]) }
    var needsSetup: Bool { !missing.isEmpty }
    var summary: String { availability.map { "\($0.kind.rawValue) \($0.ready ? "ready" : "needs setup")" }.joined(separator: " · ") }

    func refresh() async {
        guard !isBusy else { return }
        isChecking = true
        defer { isChecking = false }
        await checkResolvedTools()
        if !needsSetup { errorMessage = nil }
    }

    private func checkResolvedTools() async {
        paths = environment.resolve()
        availability = Self.detect(paths)
        for kind in ToolKind.allCases {
            guard let index = availability.firstIndex(where: { $0.kind == kind }), availability[index].ready,
                  let path = availability[index].path else { continue }
            do {
                availability[index].detail = "Checking…"
                let version = try await ToolValidator.validate(kind, at: URL(fileURLWithPath: path))
                availability[index].detail = version
            } catch {
                availability[index].ready = false
                availability[index].detail = "Needs repair: \(error.localizedDescription.prefix(300))"
            }
        }
        // yt-dlp must see ffprobe next to the selected ffmpeg binary.
        if let ffmpeg = availability.first(where: { $0.kind == .ffmpeg && $0.ready })?.path,
           let probeIndex = availability.firstIndex(where: { $0.kind == .ffprobe && $0.ready }),
           URL(fileURLWithPath: ffmpeg).deletingLastPathComponent() != URL(fileURLWithPath: availability[probeIndex].path!).deletingLastPathComponent() {
            availability[probeIndex].ready = false
            availability[probeIndex].detail = "Install a matching ffmpeg/ffprobe pair."
        }
    }

    func installMissingTools() {
        guard !isBusy, needsSetup else { return }
        let downloads = ToolDownloadCatalog.downloads(for: missing)
        let id = UUID()
        operationID = id
        errorMessage = nil
        isInstalling = true
        isCancelling = false
        progress = .init(message: "Preparing download…", fraction: 0)
        installTask = Task {
            defer {
                operationID = nil
                installTask = nil
                isInstalling = false
                isCancelling = false
            }
            do {
                try await ManagedToolInstaller().install(downloads, environment: environment) { [weak self] update in
                    await self?.updateProgress(update, operation: id)
                }
                await checkResolvedTools()
                if needsSetup { errorMessage = "Some tools could not be started. Check the details below or try again." }
            } catch {
                if Task.isCancelled || (error as? URLError)?.code == .cancelled {
                    progress = .init(message: "Setup cancelled. You can try again whenever you're ready.", fraction: 0)
                } else {
                    errorMessage = "Setup could not finish. \(error.localizedDescription.prefix(300))"
                }
            }
        }
    }

    func cancelInstallation() {
        guard isInstalling, !isCancelling, progress.fraction < 1 else { return }
        isCancelling = true
        installTask?.cancel()
        progress.message = "Cancelling setup…"
    }

    private func updateProgress(_ update: ToolInstallProgress, operation: UUID) {
        guard operationID == operation, !isCancelling else { return }
        // Late URLSession progress callbacks must not move the overall bar backwards.
        guard update.fraction >= progress.fraction else { return }
        progress = update
    }

    private static func detect(_ paths: ToolPaths) -> [ToolAvailability] {
        ToolKind.allCases.map { kind in
            let path = paths.path(for: kind)
            let ready = path.map { FileManager.default.isExecutableFile(atPath: $0) } ?? false
            return ToolAvailability(kind: kind, path: path, ready: ready, detail: ready ? "Installed" : "Not installed")
        }
    }
}
