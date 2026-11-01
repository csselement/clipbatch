# BatchClip performance and interface review

Historical review before the v0.2.0 implementation. See [implementation and validation](2026-10-31-implementation-validation.md) for the resulting changes.

Reviewed October 31, 2026: current working-tree source, the installed app's idle window, and the existing test suite. Existing uncommitted Finder-reveal changes were included in the review and left untouched. No application source was changed.

## Main assessment

BatchClip does substantially more work, and deliberately waits longer, than a basic `yt-dlp URL` invocation. The strongest performance opportunities are removing overlapping delays and making conversion an explicit output choice. The interface would benefit from a clear division between preparing links, reviewing the queue, and starting the batch.

This is a source-backed diagnosis, not a timed comparison against the user's actual clips or Terminal command. Neither a measured overall speedup nor a specific dominant cause for every clip is established.

## Findings, in priority order

### 1. P1 — Stop Batch cannot promptly cancel the running process

`Sources/BatchClip/DownloaderStore.swift:392–450`, with related state handling at lines 247–261 and 334–345.

`DownloadRunner.run()` calls blocking `process.waitUntilExit()` inside the actor. `cancel()` needs that same actor, so it cannot execute while the process is running. A standalone probe using the repository's runner and `/bin/sleep 3` requested cancellation after 0.203 seconds; cancellation returned after 3.010 seconds, when the process had already completed normally.

The UI nevertheless immediately sets `isRunning = false`. This enables queue edits and another start before the old process and output callbacks have finished. Because callbacks address array indices, removing an item in this interval can invalidate their indices; restarting can also let the previous task interfere with the new batch's state. These downstream races are source findings, not reproduced UI crashes.

Use asynchronous process termination notification, preserve a stopping state until cleanup finishes, and address items by stable IDs. Cancellation must cover child conversion processes as well as yt-dlp. Add integration tests for stopping a long-lived child, stopping during conversion, and preventing premature restart or queue mutation.

### 2. P2 — Two layers of intentional waiting accumulate

`Sources/BatchClip/DownloaderStore.swift:10–20`, `:318–320`, `:350–361`, and `:553–560`.

Rate limiting is enabled by default and forced on when 10 or more unfinished entries are present. The application supplies:

- 1.5 seconds between extraction requests through `--sleep-requests`.
- 8–18 seconds before downloads through `--sleep-interval` and `--max-sleep-interval`.
- Another 8–18 seconds between queue entries in its own cooldown loop.

Even counting only one yt-dlp download sleep per clip, 10 clips accumulate `10 × (8–18) + 9 × (8–18)` = **152–342 seconds** of deliberate waiting. Extraction requests, retries, transfers, and conversion add to that. Separate media streams can incur additional download sleeps.

Recommendation: make one component responsible for pacing. Offer plainly explained Standard and Cautious behavior, retain meaningful handling for actual 429/bot-check responses, and show when the app is deliberately waiting. Consider pacing by source host rather than forcing a uniform rule based on total queue rows. A playlist row can represent many downloads, so row count is not a reliable request-volume estimate.

The meanings of these options are documented in the [yt-dlp options reference](https://github.com/yt-dlp/yt-dlp#workarounds).

### 3. P2 — Output conversion can dominate processing time

`Sources/BatchClip/DownloaderStore.swift:563–580`.

The app prefers H.264 sources, but falls back to other codecs. For a non-H.264 file it re-encodes the entire video using `libx264 -preset medium -crf 18`, and also converts audio to AAC. Audio jobs request MP3 at 320 kbps. A basic yt-dlp download does not request these same conversions, so the two workflows are not equivalent.

Recommendation: offer **Original / fastest** and **Compatible MP4** output choices. Preserve the current compatible output behavior as an available option. For compatibility mode, copy already compatible streams and benchmark hardware H.264 encoding against a faster software preset on representative footage. The installed ffmpeg lists `h264_videotoolbox`; its availability alone does not establish actual throughput or an equivalent quality setting.

Add phase timings for extraction, intentional waiting, transfer, merge, and encoding. Compare the same executable, selected streams, output destination, and arguments when benchmarking against Terminal. The runner replaces its environment with a fixed PATH, so Terminal settings and helper discovery should also be compared (`DownloaderStore.swift:408–410`).

### 4. P2 — Progress can look finished while substantial work remains

`Sources/BatchClip/DownloaderStore.swift:587–678` and `Sources/BatchClip/ContentView.swift:364–366`, `:413–419`.

The app scrapes percentages and activity labels from arbitrary chunks of human-readable process output. A download reaching 100% is not the end of merging or encoding. The custom encoder is introduced as “Checking final file,” and its ffmpeg output has no dedicated progress parser. A long encode can therefore appear as a stalled 100% download. Titles and metadata can also be split across reads, which the parser does not buffer into complete lines.

Use a line-buffered event parser and yt-dlp's structured `--progress-template` output. Give downloading, merging, converting, and waiting distinct states; use indeterminate progress when a phase cannot be measured. Parse ffmpeg progress separately if conversion remains. Show speed and ETA only for the stage they actually describe. yt-dlp explicitly recommends machine-oriented output rather than parsing normal stdout in its [embedding guidance](https://github.com/yt-dlp/yt-dlp#embedding-yt-dlp).

### 5. P2 — Duplicate links within one paste are not removed

`Sources/BatchClip/DownloaderStore.swift:123–126`.

Deduplication checks only links already in `items`. Repeating a URL in one pasted list creates multiple new entries, leading to redundant extraction, waiting, and potentially post-processing. Deduplicate incrementally while preserving input order. Define whether a URL requested once as video and once as audio should count as two intentional jobs; the current URL-only check prevents that across separate additions.

### 6. P2 — The MP4 promise is not guaranteed for every fallback

`Sources/BatchClip/DownloaderStore.swift:565–573`.

`--merge-output-format mp4` controls merge output, not every precombined input. The custom script exits immediately for H.264 regardless of container. For other codecs it creates MP4 data, then moves that file back onto the original filename, which may have a different extension. Explicitly remux compatible video when needed, and ensure final filename, container, and Finder-reveal path agree. Test progressive inputs as well as separate video/audio streams.

## Proposed interface arrangement

Keep the two-pane structure, but make the left pane solely about preparing new entries. Place controls that affect the entire batch below both panes.

```text
┌──────────────────────────────────────────────────────────────────────┐
│ BatchClip                                          Tools / Settings │
├────────────────────────┬─────────────────────────────────────────────┤
│ Add links              │ Batch · 6 queued          Retry   Clear Done │
│                        │                                             │
│ Paste one URL per line │ Clip title                                  │
│ [link editor]          │ Source · Output · Status                    │
│                        │                                             │
│ Video / Audio          │ Clip title                                  │
│ Output format          │ Source · Output · Status                    │
│                        │                                             │
│ Import…   Add to Batch  │                                             │
├────────────────────────┴─────────────────────────────────────────────┤
│ Save to: Downloads  Choose…          Pacing: Standard / Cautious      │
│ 6 queued · Ready                                    [ Start Batch ] │
└──────────────────────────────────────────────────────────────────────┘
```

This is a layout proposal, not a running prototype.

- **Put Start Batch at the bottom right.** It operates on the queue, so its current location at the bottom of the link-entry pane is misleading. This placement is a recommendation for this workflow, not a universal macOS rule.
- **Use one emphasized action.** Make Add to Batch a regular bordered button near the editor. Start Batch should be the prominent action when the queue is ready. While running, use the same footer area for Stop Batch and progress; preserve a disabled “Stopping…” state until cleanup completes.
- **Move destination and pacing into the shared footer.** They affect all queued entries, unlike Video/Audio, which applies when adding links. Put any new output choice beside Video/Audio and store that choice per job.
- **Reduce the large header.** The title bar already names the app. Move format guidance next to output selection, routine dependency information into Settings or a compact tool-status control, and transient batch status into the footer. Keep missing-tool guidance discoverable when needed.
- **Make importing visible.** Add Import… beside the composer while retaining Command-O. Add a Start Batch menu command with Command-Return; retain Command-period to stop. Plain Return should continue to insert lines in the editor.
- **Make queue rows easier to scan.** Use title/source, output type, then phase/progress. Keep Reveal in Finder. Offer details/logs and retry per failed item. Avoid a full error paragraph inside the status field.
- **Clarify retry and playlist behavior.** Retry Failed currently only requeues items, whereas Start Batch already includes failed items. Choose one clear behavior and label it accurately. Offer an explicit single-video versus playlist choice when a URL contains `list=` instead of silently treating it as the whole playlist.
- **Remember useful preferences.** Destination and pacing currently reset with a new store. Persist those preferences; consider recovery of unfinished queues separately. Validate HTTP/HTTPS links before adding them and report rejected/duplicate counts.

## Suggested implementation sequence

1. Fix process cancellation and batch-state ownership, with targeted lifecycle tests.
2. Consolidate pacing and add phase timings; establish an equivalent CLI baseline.
3. Introduce explicit output choices and correct final container/path handling.
4. Add the shared footer, right-aligned primary action, quieter header, and nearby import/add controls.
5. Improve progress events, deduplication, playlist choices, and preference persistence.

## Validation completed

- `swift test --scratch-path /tmp/batchclip-review-build`: build succeeded; all **8 tests in 4 suites passed**. A sandboxed attempt first failed because compiler caches were inaccessible; the approved retry succeeded.
- Cancellation probe compiled from the current runner: confirmed delayed cancellation as described above. Probe files are in `/tmp`, not the repository.
- Installed BatchClip's empty window inspected through its accessibility tree and screenshot. Its visible structure matches the reviewed layout. The installed binary was not assumed to include every uncommitted source change.
- Local yt-dlp reports version `2026.08.19`. Local ffmpeg lists both `libx264` and `h264_videotoolbox`.
- No real media downloads, throughput benchmark, conversion-quality comparison, or populated-queue interaction test was performed.
- No source changes, commits, dependency updates, or releases were made. This report is the sole repository addition from the review.
