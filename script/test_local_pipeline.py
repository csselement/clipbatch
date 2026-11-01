#!/usr/bin/env python3
"""Run Swift tests with generated media over localhost; no public downloads."""
import functools
import http.server
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import threading

root = Path(__file__).resolve().parent.parent
ffmpeg = shutil.which("ffmpeg")
if not ffmpeg:
    sys.exit("ffmpeg is required for the local pipeline checks.")

class Handler(http.server.SimpleHTTPRequestHandler):
    def log_message(self, *args):
        pass

with tempfile.TemporaryDirectory(prefix="batchclip-fixtures-") as temporary:
    folder = Path(temporary)
    subprocess.run([
        ffmpeg, "-hide_banner", "-loglevel", "error", "-f", "lavfi", "-i", "testsrc2=size=320x180:rate=24",
        "-f", "lavfi", "-i", "sine=frequency=440:sample_rate=48000", "-t", "1",
        "-c:v", "libx264", "-preset", "fast", "-c:a", "aac", str(folder / "sample.mp4")
    ], check=True)
    subprocess.run([
        ffmpeg, "-hide_banner", "-loglevel", "error", "-i", str(folder / "sample.mp4"),
        "-c:v", "libvpx-vp9", "-deadline", "realtime", "-cpu-used", "6", "-c:a", "libopus", str(folder / "vp9.webm")
    ], check=True)
    server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), functools.partial(Handler, directory=temporary))
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    try:
        environment = dict(os.environ, BATCHCLIP_TEST_BASE_URL=f"http://127.0.0.1:{server.server_port}")
        result = subprocess.run(["swift", "test", *sys.argv[1:]], cwd=root, env=environment)
    finally:
        server.shutdown()
        server.server_close()
        thread.join()
sys.exit(result.returncode)
