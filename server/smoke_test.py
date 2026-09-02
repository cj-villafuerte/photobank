"""Standalone smoke test for the ingest pipeline (no DB needed). Run: python smoke_test.py"""
import asyncio
import subprocess
import tempfile
from pathlib import Path

from PIL import Image

from app import ingest

tmp = Path(tempfile.mkdtemp())

# --- image ---
src = tmp / "test.jpg"
img = Image.new("RGB", (2000, 1500), (200, 60, 60))
exif = Image.Exif()
exif[0x010F] = "TestMake"
exif[0x0110] = "TestModel"
img.save(src, exif=exif)

meta = ingest.extract_image_metadata(src)
assert meta["width"] == 2000 and meta["height"] == 1500, meta
assert meta["camera_make"] == "TestMake", meta
print("image metadata OK:", meta)

out = tmp / "thumbs"
out.mkdir()
ingest._generate_image_thumbs(src, out)
with Image.open(out / "thumb.webp") as t:
    assert max(t.size) == 320, t.size
    print("thumb.webp OK:", t.size)
with Image.open(out / "preview.webp") as p:
    assert max(p.size) == 1440, p.size
    print("preview.webp OK:", p.size)

# --- video ---
vid = tmp / "test.mp4"
subprocess.run(
    [ingest.ffbin("ffmpeg"), "-y", "-v", "quiet", "-f", "lavfi", "-i",
     "testsrc=duration=3:size=640x360:rate=10", str(vid)],
    check=True,
)
vmeta = asyncio.run(ingest.extract_video_metadata(vid))
assert vmeta.get("width") == 640 and abs(vmeta.get("duration_sec", 0) - 3) < 0.5, vmeta
print("video metadata OK:", vmeta)

vout = tmp / "vthumbs"
vout.mkdir()
asyncio.run(ingest._generate_video_thumbs(vid, vout))
with Image.open(vout / "thumb.webp") as t:
    print("video thumb OK:", t.size)

print("\nALL SMOKE TESTS PASSED")
