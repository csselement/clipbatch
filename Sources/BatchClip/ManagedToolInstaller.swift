import CryptoKit
import Foundation
import Darwin

struct ToolInstallProgress: Sendable {
    var message: String
    var fraction: Double
}

actor ManagedToolInstaller {
    typealias Validator = @Sendable (ToolKind, URL) async throws -> String
    private let fetcher: any ToolFetching
    private let validate: Validator
    init(fetcher: any ToolFetching = ToolDownloadClient(),
         validate: @escaping Validator = { try await ToolValidator.validate($0, at: $1, timeout: .seconds(60)) }) {
        self.fetcher = fetcher
        self.validate = validate
    }

    func install(_ downloads: [ToolDownload], environment: ToolEnvironment,
                 progress: @escaping @Sendable (ToolInstallProgress) async -> Void) async throws {
        guard !downloads.isEmpty else { return }
        let fm = FileManager.default
        try fm.createDirectory(at: environment.root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let lockFD = open(environment.root.appendingPathComponent(".install-lock").path, O_CREAT | O_RDWR | O_CLOEXEC, 0o600)
        guard lockFD >= 0 else { throw ToolSetupError.message("Cannot write to BatchClip's tools folder.") }
        defer { close(lockFD) }
        guard flock(lockFD, LOCK_EX | LOCK_NB) == 0 else {
            throw ToolSetupError.message("Another BatchClip window is installing tools. Wait for it to finish, then Check Again.")
        }
        defer { flock(lockFD, LOCK_UN) }
        let id = UUID().uuidString
        let stage = environment.root.appendingPathComponent(".staging-\(id)")
        let ready = stage.appendingPathComponent("ready")
        try fm.createDirectory(at: ready, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: stage) }
        let runner = DownloadRunner()
        for (index, download) in downloads.enumerated() {
            try Task.checkCancellation()
            let base = Double(index) / Double(downloads.count)
            await progress(.init(message: "Downloading \(download.kind.rawValue) (\(index + 1) of \(downloads.count))…", fraction: base))
            let archive = stage.appendingPathComponent("\(download.kind.rawValue).download")
            try await fetcher.fetch(download.url, to: archive) { fraction in
                Task { await progress(.init(message: "Downloading \(download.kind.rawValue)… \(Int(fraction * 100))%", fraction: base + fraction * 0.8 / Double(downloads.count))) }
            }
            try Task.checkCancellation()
            await progress(.init(message: "Verifying \(download.kind.rawValue)…", fraction: base + 0.8 / Double(downloads.count)))
            guard try Self.sha256(archive) == download.sha256.lowercased() else {
                throw ToolSetupError.message("The \(download.kind.rawValue) download failed its integrity check. Nothing was installed. Please retry.")
            }
            let source: URL
            if download.isZip {
                let listing = try await runner.run(executablePath: "/usr/bin/unzip", arguments: ["-Z1", archive.path])
                try Self.validateArchiveListing(listing)
                let extracted = stage.appendingPathComponent("unpacked-\(download.kind.rawValue)")
                _ = try await runner.run(executablePath: "/usr/bin/ditto", arguments: ["-xk", archive.path, extracted.path])
                source = extracted.appendingPathComponent(download.executableName ?? download.kind.rawValue)
                if let support = download.supportDirectory {
                    try fm.copyItem(at: extracted.appendingPathComponent(support), to: ready.appendingPathComponent(support))
                }
            } else {
                source = archive
            }
            let values = try source.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            guard values.isRegularFile == true, values.isSymbolicLink != true else {
                throw ToolSetupError.message("The download did not contain the expected \(download.kind.rawValue) executable.")
            }
            let executable = ready.appendingPathComponent(download.kind.rawValue)
            try fm.copyItem(at: source, to: executable)
            try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
            await progress(.init(message: "Checking \(download.kind.rawValue)…", fraction: base + 0.9 / Double(downloads.count)))
            do {
                _ = try await validate(download.kind, executable)
            } catch {
                try Task.checkCancellation()
                throw ToolSetupError.message("\(download.kind.rawValue) could not be verified. \(error.localizedDescription.prefix(300))")
            }
        }
        try Task.checkCancellation()
        let versions = environment.root.appendingPathComponent("versions")
        try fm.createDirectory(at: versions, withIntermediateDirectories: true)
        let installed = versions.appendingPathComponent(id)
        try fm.moveItem(at: ready, to: installed)
        do {
            var receipt = environment.receipt()
            for download in downloads { receipt[download.kind.rawValue] = "versions/\(id)/\(download.kind.rawValue)" }
            // This is the commit point. Until the atomic receipt write, old tools stay active.
            try JSONEncoder().encode(receipt).write(to: environment.receiptURL, options: .atomic)
        } catch {
            try? fm.removeItem(at: installed)
            throw error
        }
        await progress(.init(message: "Download tools are ready.", fraction: 1))
    }

    static func sha256(_ url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hash = SHA256()
        while let data = try handle.read(upToCount: 1_048_576), !data.isEmpty {
            try Task.checkCancellation()
            hash.update(data: data)
        }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }

    static func validateArchiveListing(_ listing: String) throws {
        let paths = listing.split(whereSeparator: \.isNewline)
        guard !paths.isEmpty, paths.count < 1000,
              paths.allSatisfy({ path in
                  !path.hasPrefix("/") && !path.contains("\\") && !path.split(separator: "/").contains("..")
              }) else {
            throw ToolSetupError.message("The downloaded archive has an unexpected layout.")
        }
    }
}
