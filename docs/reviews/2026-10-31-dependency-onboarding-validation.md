# Dependency onboarding validation — 2026-10-31

## Implemented

- First launch opens a native setup sheet when required download tools are absent or unusable. One **Install Download Tools** button downloads missing dependencies without Homebrew, Python setup, Terminal, or administrator privileges.
- The sheet shows per-tool status, versions, progress, cancellation, retry, download sources, and an optional Homebrew fallback. The footer wrench reopens it. **Check Again** recognizes external installations without restarting.
- Private tools live in Application Support; working system/Homebrew tools are reused and remain unchanged. Downloads are version-pinned, SHA-256 checked before execution, tested before activation, and activated with an atomic receipt. FFmpeg/ffprobe install as a pair. An exclusive installation lock prevents overlapping installers.
- Deno is included for YouTube JavaScript support and passed explicitly to yt-dlp, including paths containing spaces. Missing Deno blocks queued YouTube jobs but not other sites.
- The installer uses the official yt-dlp folder distribution with its Python runtime and EJS components. FFmpeg/ffprobe use Martin Riedl's native macOS builds. Deno uses its official release assets. Sources and hashes are in `ToolDownloadCatalog.swift`.
- Batch processing, output modes, rate-limit safeguards, bottom-right Start Batch, and Finder reveal remain intact.

## Verification

- Fresh installation from real upstream downloads succeeded in isolated directories with system-tool detection disabled. All four tools passed executable/version checks; FFmpeg's required encoders were checked. The final folder-based install took about 23 seconds on this machine; this is not a network-speed guarantee.
- The full debug suite ran against those app-managed tools using generated clips over localhost. All 45 normal checks passed (46 declarations, with the opt-in real-download test executed separately).
- The release suite also passes with warnings treated as errors. It uses the existing system tools because release builds ignore the debug-only path override.
- Installer regression coverage includes checksum mismatch with preservation of an active installation, partial-install failure, offline error, cancellation cleanup, receipt/archive path validation, runtime-folder preservation, malformed version output, hung-tool timeout, external-tool refresh, outdated Deno, and architecture-specific catalog selection.
- Native UI checks covered first-run presentation, cancellation and retry, successful completion, existing Homebrew detection, and Start Batch becoming enabled after adding a link without restarting.
- No production media was downloaded or modified. End-to-end media tests use generated local fixtures. Live YouTube bot challenges and Intel execution were not tested on this Apple Silicon machine.

## Performance finding

The initially tested single-file yt-dlp distribution took about 10 seconds per launch on this Mac. Five local output-mode cases took 64.25 seconds. Its official folder distribution extracts the runtime once during installation; a subsequent version check took 0.31 seconds, and the same five pipeline cases completed in about 4.0–4.2 seconds. The first invocation can still take longer while macOS examines newly downloaded code. Tool verification permits that initial startup time and remains cancellable.

## Distribution

Version 0.2.1 is packaged as an optimized Apple Silicon app for macOS 14+. It retains ad-hoc signing; the current release workflow does not provide Apple Developer ID notarization. Upstream tools are downloaded on demand, not embedded in the app archive. Working dependency versions are not silently auto-updated.
