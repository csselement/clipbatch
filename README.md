# BatchClip

BatchClip is a minimal native macOS app for batch downloading social media video and audio with `yt-dlp` and `ffmpeg`.

## Download

Download the latest zipped macOS app from [GitHub Releases](https://github.com/csselement/clipbatch/releases/latest).

The release asset is a zipped macOS app. Unzip it, move `BatchClip.app` to Applications if desired, and launch it.

Current binaries are ad-hoc signed but not Apple Developer ID notarized. macOS may show a Gatekeeper warning the first time the app is opened.

## Workflow

1. Paste HTTP/HTTPS links, one per line, or use **Import…** / **Command-O**.
2. Choose Video or Audio, then an output mode, and **Add to Batch**.
3. Choose the destination and pacing in the shared footer.
4. Click **Start Batch** at the bottom right, or press **Command-Return**.

Links are deduplicated within pasted lists and against jobs with the same media type, output mode, and playlist choice. Invalid links remain in the editor for correction. A video and an audio download of the same URL can be queued independently.

## Output Modes

- **Compatible video:** prefers H.264 MP4 sources. Compatible video/audio streams are copied; other video is converted to H.264 using `libx264 -preset veryfast -crf 18`, and incompatible audio to AAC. Final output uses the correct `.mp4` extension.
- **Compatible audio:** MP3 at 320 kbps.
- **Original video:** keeps the downloaded codecs and lets yt-dlp choose a suitable container; no additional video re-encoding.
- **Original audio:** keeps the source audio codec, extracting it with stream copy when the source also contains video. It never silently falls back to lossy conversion.

Conversion writes to a temporary file, validates the result, and only then replaces the downloaded source. Failed or cancelled conversion keeps the source. A conflicting destination file is preserved and reported as an error instead of overwritten.

## Pacing and Site Limits

**Cautious** is the default. yt-dlp waits 8–18 seconds before downloads and spaces extraction requests by 1.5 seconds. BatchClip does not add a second cooldown between queue entries. **Standard** adds no scheduled waits. Both modes download sequentially, use retry backoff, and stop the batch when a terminal bot-check or rate-limit error is detected. Existing yt-dlp configuration can also affect behavior.

Large queues and playlist jobs show a reminder to consider Cautious pacing. Pacing remains a user choice; no setting can guarantee that a site will not throttle or challenge downloads. The selected pacing and destination persist between launches.

## Batch Controls

- Playlist downloads require the explicit **Download entire playlists** option; it is off by default.
- Queue rows show metadata, the current processing stage, and transfer speed/ETA when available. Conversion progress is separate from download progress.
- **Details** exposes the command log and timings for each stage.
- **Stop Batch** / **Command-period** cancels the command and its child processes. The queue remains locked while stopping.
- **Retry Failed** starts failed/cancelled jobs again, leaving unrelated queued jobs for Start Batch. A failed row's contextual menu can retry just that job.
- Completed rows retain **Show downloaded file in Finder**.
- **Clear Done** removes completed entries from the queue, not their files.
- Tool status and setup are available from the footer's wrench button. Missing tools can be installed directly in the app.

## Requirements and First Launch

- macOS 14 or newer
- Internet access for setup and downloads
- Swift toolchain only when building from source

When download tools are missing, BatchClip opens a setup screen. Click **Install Download Tools** to download and verify private copies of `yt-dlp`, `ffmpeg`, `ffprobe`, and Deno. No Terminal, Homebrew, Python installation, or administrator password is needed. Progress, cancellation, and retry are available; installed tools become usable immediately without restarting the app.

Deno provides the JavaScript runtime needed for full YouTube support. Missing Deno blocks queued YouTube jobs while other supported sites remain usable. A broken or outdated executable is offered for repair. BatchClip checks versions and the H.264/MP3 encoders it uses.

Working tools in Homebrew/system locations and the process `PATH` are reused. App-managed copies live in `~/Library/Application Support/BatchClip/Tools` and take precedence when present. FFmpeg and ffprobe are installed as a matching pair. Setup does not modify system tools, run package-manager scripts, or change Gatekeeper settings.

Downloads use HTTPS, pinned releases, and SHA-256 verification before execution. All requested tools are validated before an atomic activation; failed or cancelled setup leaves previously installed tools active. The downloads come from:

- [yt-dlp's official standalone macOS release](https://github.com/yt-dlp/yt-dlp/releases/tag/2026.10.26), including Python and the JavaScript challenge components. BatchClip uses the folder-based package, extracted once during setup, to avoid the single-file package's repeated runtime-extraction delay.
- [Martin Riedl's FFmpeg macOS builds](https://ffmpeg.martin-riedl.de/), a third-party distributor providing native Apple Silicon and Intel builds (9.0.2).
- [Deno's official macOS release](https://github.com/denoland/deno/releases/tag/v2.9.8).

The pinned versions and hashes are maintained in `ToolDownloadCatalog.swift`. Setup installs missing or broken tools; it does not silently update working tools. Future upstream changes may require a BatchClip update or updating tools with Homebrew.

### Optional Homebrew setup

For users who prefer managing dependencies themselves:

```bash
brew install yt-dlp ffmpeg deno
```

`ffprobe` is included with `ffmpeg`. If needed, install Homebrew from [brew.sh](https://brew.sh/) first. Use **Check Again** in BatchClip's tools screen after installation; no app restart is needed. The setup screen retains copyable Homebrew commands as a fallback.

## Build And Run

Use the project script:

```bash
./script/build_and_run.sh
```

To build, launch, and verify the running process:

```bash
./script/build_and_run.sh --verify
```

The script stages a native app bundle at:

```text
dist/BatchClip.app
```

## Package A Release

To create a release zip locally, pass the version without a leading `v`:

```bash
./script/package_release.sh 0.2.1
```

## Tests

Run the unit and local process/media tests:

```bash
swift test
```

Run the full suite, including end-to-end yt-dlp downloads and conversion of generated clips served only on localhost:

```bash
python3 script/test_local_pipeline.py
```

The latter requires Python 3 plus the app's tools. It creates and cleans up its own fixtures and HTTP server. Without that harness, the two HTTP pipeline tests are skipped. Media conversion tests also require ffmpeg.

Fresh dependency installation can be exercised without touching system tools (use a new, empty directory):

```bash
BATCHCLIP_TEST_MANAGED_INSTALL=/tmp/batchclip-fresh-tools swift test --filter realManagedInstallation
BATCHCLIP_TEST_TOOLS_DIRECTORY=/tmp/batchclip-fresh-tools python3 script/test_local_pipeline.py
```

The first command makes real upstream downloads. The second uses those tools for the app pipeline. `BATCHCLIP_TEST_TOOLS_DIRECTORY` is a debug-only override that disables system-tool detection; release builds ignore it. Installer unit tests cover integrity failures, cancellation, offline errors, partial-install rollback, receipt validation, and detecting externally installed tools without restarting.

## Limitations

- Site compatibility and network speed depend on yt-dlp and the source site.
- Some sites need cookies, login, or additional yt-dlp options not exposed in the UI.
- The app does not expose resolution, bitrate, or codec tuning beyond its output modes.
- The faster software encoding preset trades compression efficiency for speed; output size and quality vary with footage.
- Queues are held in memory and are not restored after quitting.
