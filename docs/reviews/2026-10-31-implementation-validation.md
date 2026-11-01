# BatchClip implementation and validation

Implemented October 31, 2026, following the performance and UI review. The existing Finder-reveal work is retained and was checked in the running app. This document records implementation validation before packaging v0.2.0. The local development bundle is generated at `dist/BatchClip.app`.

## Changes

- Moved Start Batch to the bottom right of a shared footer. Destination, pacing, and status now apply visibly to the whole batch. Link entry, output choice, and Import/Add stay together on the left.
- Reduced header clutter; tool status is available from a compact footer control. Added Command-Return to start and retained Command-period to stop.
- Kept Cautious pacing as the default: yt-dlp's 8–18 second download sleeps, 1.5 second extraction-request spacing, and retry backoff remain. Removed the duplicate application cooldown. This removes 8–18 seconds for each gap between queued jobs while retaining the configured yt-dlp protection. Standard mode has no scheduled waits; it retains retry backoff and the batch-stop classifier for site limits/challenges.
- Added Original output modes that avoid re-encoding. Original audio uses explicit stream copy, avoiding yt-dlp's potential lossy fallback for uncommon codecs.
- Compatible video copies compatible streams and uses a faster software encoding preset only when conversion is needed. Temporary output is validated before replacing the source, and final extensions match the output container. Conflicting destination files are preserved.
- Replaced blocking process waits with an asynchronous runner owning a process group. Cancellation reaches subprocesses, resets inherited signal masks, and escalates for children that ignore termination. The UI stays locked until cleanup completes.
- Added complete-line UTF-8 output handling, machine-oriented progress events, separate conversion progress, and phase timings in Details. Explicit non-quiet yt-dlp output makes intentional waits visible.
- Deduplicated incoming lists, validated HTTP/HTTPS URLs, made playlists opt-in, and retained distinct jobs for different output choices. Retry Failed starts only failed/cancelled jobs; contextual retry can target one item.
- Persisted destination, pacing, and output preference. Updated README and added a reproducible local pipeline test harness.

## Validation

`python3 script/test_local_pipeline.py --scratch-path /tmp/batchclip-review-build` passed **32 tests in 10 suites**, including all original tests. The harness generates short media clips and serves them only on localhost; it needs no public site or account.

Coverage includes:

- Cancellation, process reuse, child processes ignoring SIGTERM, launch failure, and stderr errors.
- Complete UTF-8 lines across pipe boundaries and trailing partial lines.
- Queue locking while stopping, rate-limit failures stopping before the next item, and retries leaving unrelated queued items untouched.
- Cautious default, explicit Standard choice for large queues, duplicate rejection, playlist choice, and preferences.
- H.264 MP4 passthrough without changing file bytes; H.264 remuxing; VP9 conversion and conversion progress.
- Source preservation on conversion failure/cancellation and destination collisions.
- End-to-end H.264 compatible video, VP9-to-H.264 compatible video, original VP9 video, MP3 audio, and original AAC audio extraction.
- Cautious wait visibility and cancellation during that wait; final file paths suitable for Finder reveal.

`./script/build_and_run.sh --verify` succeeded for the final source. `git diff --check` passed.

The native UI check confirmed the footer placement, adding a two-item batch, Command-Return, successful H.264 and VP9 jobs, Details/timings, and Reveal in Finder selecting the expected file. The final rebuilt app was visually inspected with an empty queue. Test preferences were restored to Cautious pacing and the user's Downloads directory.

## Performance evidence and limits

A small local encoding check used a five-second synthetic 1920×1080, 30 fps source, `libx264`, CRF 18, YUV420P, and MP4 faststart. The old medium preset took **1.598 seconds**; veryfast took **0.665 seconds**. This single synthetic check is illustrative, not a guarantee of a 2.4× end-to-end speedup or equal visual quality on all footage. The change also alters compression behavior; output size and quality vary with source content.

No public-site throughput, login/cookie flow, real playlist, or long-form production-media benchmark was run. Rate-limit handling was tested with a local failure fixture, not by provoking a real site's limits. Queue persistence across quitting and hardware encoding were not added. Existing yt-dlp configuration and source-site behavior can still affect timing.

## Release validation — v0.2.0

- The full local pipeline suite also passed all 32 tests in optimized release mode with `-Xswiftc -warnings-as-errors`.
- `./script/package_release.sh 0.2.0` produced `BatchClip-0.2.0-macos-arm64.zip`.
- ZIP integrity and strict code-signature verification passed. The bundle reports version 0.2.0, arm64 architecture, and a macOS 14.0 minimum deployment target.
- Signing remains ad-hoc; the app is not Developer ID notarized.
- SHA-256: `7efcab9082db4f518e01844f5fdb547d01f966e734e91482165a9bdd79bfa75b`.
