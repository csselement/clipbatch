import Foundation
import Darwin

/// Each command owns a process group, so Stop also reaches ffmpeg and other children.
/// Blocking pipe reads and waitpid run off the actor; cancellation remains responsive.
actor DownloadRunner {
    private var activePID: pid_t?

    func cancel() {
        guard let pid = activePID else { return }
        kill(-pid, SIGTERM)
        Task {
            try? await Task.sleep(for: .seconds(1))
            forceStopIfActive(pid)
        }
    }

    private func forceStopIfActive(_ pid: pid_t) {
        guard activePID == pid else { return }
        kill(-pid, SIGKILL)
    }

    func run(
        executablePath: String,
        arguments: [String],
        onOutput: @escaping @Sendable (String) async -> Void = { _ in }
    ) async throws -> String {
        try Task.checkCancellation()
        guard activePID == nil else { throw DownloadError.processFailed("A command is already running.") }
        let (pid, readFD) = try spawn(executablePath: executablePath, arguments: arguments)
        activePID = pid
        defer { activePID = nil }

        return try await withTaskCancellationHandler {
            let result = await Task.detached(priority: .utility) {
                await Self.collect(pid: pid, readFD: readFD, onOutput: onOutput)
            }.value
            try Task.checkCancellation()
            guard result.status == 0 else {
                throw DownloadError.processFailed(result.output.isEmpty ? "Command exited with status \(result.status)." : result.output)
            }
            return result.output
        } onCancel: {
            Task { await self.cancel() }
        }
    }

    private func spawn(executablePath: String, arguments: [String]) throws -> (pid_t, Int32) {
        var descriptors: [Int32] = [0, 0]
        guard pipe(&descriptors) == 0 else { throw POSIXError(.EIO) }
        let readFD = descriptors[0], writeFD = descriptors[1]
        // Prevent another concurrently launched command from retaining our pipe.
        _ = fcntl(readFD, F_SETFD, FD_CLOEXEC)
        _ = fcntl(writeFD, F_SETFD, FD_CLOEXEC)
        var actions: posix_spawn_file_actions_t?
        var attributes: posix_spawnattr_t?
        posix_spawn_file_actions_init(&actions)
        posix_spawnattr_init(&attributes)
        defer {
            posix_spawn_file_actions_destroy(&actions)
            posix_spawnattr_destroy(&attributes)
            close(writeFD)
        }
        posix_spawn_file_actions_adddup2(&actions, writeFD, STDOUT_FILENO)
        posix_spawn_file_actions_adddup2(&actions, writeFD, STDERR_FILENO)
        posix_spawn_file_actions_addclose(&actions, readFD)
        posix_spawn_file_actions_addclose(&actions, writeFD)
        posix_spawn_file_actions_addopen(&actions, STDIN_FILENO, "/dev/null", O_RDONLY, 0)
        posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_SETSIGMASK | POSIX_SPAWN_SETSIGDEF))
        posix_spawnattr_setpgroup(&attributes, 0)
        // Swift executor threads may block signals. Children must not inherit that mask.
        var mask = sigset_t()
        sigemptyset(&mask)
        posix_spawnattr_setsigmask(&attributes, &mask)
        var defaults = sigset_t()
        sigemptyset(&defaults)
        for signal in [SIGTERM, SIGINT, SIGHUP, SIGQUIT, SIGPIPE] { sigaddset(&defaults, signal) }
        posix_spawnattr_setsigdefault(&attributes, &defaults)

        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = ToolLocator.processSearchPath
        environment["LC_ALL"] = "en_US.UTF-8"
        var argv = ([executablePath] + arguments).map { strdup($0) } + [nil]
        var envp = environment.map { strdup("\($0.key)=\($0.value)") } + [nil]
        defer {
            argv.forEach { free($0) }
            envp.forEach { free($0) }
        }
        var pid: pid_t = 0
        let status = posix_spawn(&pid, executablePath, &actions, &attributes, &argv, &envp)
        guard status == 0 else {
            close(readFD)
            throw POSIXError(POSIXErrorCode(rawValue: status) ?? .EIO)
        }
        return (pid, readFD)
    }

    private static func collect(
        pid: pid_t, readFD: Int32,
        onOutput: @escaping @Sendable (String) async -> Void
    ) async -> (status: Int32, output: String) {
        defer { close(readFD) }
        var pending = Data()
        var output = ""
        var bytes = [UInt8](repeating: 0, count: 16_384)
        while true {
            let count = read(readFD, &bytes, bytes.count)
            if count < 0 && errno == EINTR { continue }
            guard count > 0 else { break }
            pending.append(contentsOf: bytes.prefix(count))
            // Decode only whole lines, including UTF-8 characters split across reads.
            while let end = pending.firstIndex(where: { $0 == 10 || $0 == 13 }) {
                let line = String(decoding: pending[..<end], as: UTF8.self)
                pending.removeSubrange(...end)
                if !line.isEmpty {
                    output += line + "\n"
                    await onOutput(line + "\n")
                }
            }
            if output.utf8.count > 1_048_576 { output = String(output.suffix(524_288)) }
        }
        if !pending.isEmpty {
            let line = String(decoding: pending, as: UTF8.self)
            output += line
            await onOutput(line)
        }
        var status: Int32 = 0
        while waitpid(pid, &status, 0) < 0 && errno == EINTR {}
        return (status, output)
    }
}
