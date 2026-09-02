"""Verify HDR detection + tonemapped frame grab works with this ffmpeg build."""
import asyncio
import subprocess
import tempfile
from pathlib import Path

from app import ingest

tmp = Path(tempfile.mkdtemp())
vid = tmp / "hdr.mp4"
# tag a test clip as HLG (arib-std-b67) to exercise the HDR path
subprocess.run(
    [ingest.ffbin("ffmpeg"), "-y", "-v", "quiet", "-f", "lavfi",
     "-i", "testsrc=duration=2:size=640x360:rate=10",
     "-c:v", "libx264",
     "-x264-params", "colorprim=bt2020:transfer=arib-std-b67:colormatrix=bt2020nc",
     str(vid)],
    check=True,
)
assert asyncio.run(ingest._is_hdr_video(vid)), "HDR not detected"
print("HDR detected OK")
out = tmp / "thumbs"
out.mkdir()
asyncio.run(ingest._generate_video_thumbs(vid, out))
assert (out / "thumb.webp").exists() and (out / "thumb.webp").stat().st_size > 0
print("tonemapped thumb OK:", (out / "thumb.webp").stat().st_size, "bytes")
