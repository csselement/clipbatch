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
- Tool status is available from the footer's wrench button. Missing tools show installation instructions.

## Requirements

- macOS 14 or newer
- Swift toolchain for building from source
- `yt-dlp`
- `ffmpeg`
- `ffprobe`

BatchClip checks common Homebrew and system executable locations, including `/opt/homebrew/bin`, `/usr/local/bin`, and the process `PATH`. If a required tool is missing, the app shows the shortest Terminal setup commands for that Mac and offers a copy button.

If Homebrew is already installed, run:

```bash
brew install yt-dlp ffmpeg
```

If Homebrew is not installed, run the official installer first:

```bash
/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
brew install yt-dlp ffmpeg
```

`ffprobe` is included with `ffmpeg`. If Homebrew prints PATH setup instructions after installation, follow those before reopening BatchClip.

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
./script/package_release.sh 0.2.0
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

## Limitations

- Site compatibility and network speed depend on yt-dlp and the source site.
- Some sites need cookies, login, or additional yt-dlp options not exposed in the UI.
- The app does not expose resolution, bitrate, or codec tuning beyond its output modes.
- The faster software encoding preset trades compression efficiency for speed; output size and quality vary with footage.
- Queues are held in memory and are not restored after quitting.
