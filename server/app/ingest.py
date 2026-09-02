"""Metadata extraction and background thumbnail generation."""

import asyncio
import json
import logging
import os
import shutil
import uuid
from datetime import datetime, timezone
from functools import lru_cache
from pathlib import Path

from PIL import Image, ImageOps
from sqlalchemy import select

from . import storage
from .models import Asset

log = logging.getLogger("photobank.ingest")

IMAGE_EXTS = {".jpg", ".jpeg", ".png", ".gif", ".webp", ".heic", ".heif", ".bmp", ".tiff", ".tif", ".avif"}
VIDEO_EXTS = {".mp4", ".mov", ".m4v", ".webm", ".mkv", ".avi", ".3gp"}

THUMB_SIZE = 320
PREVIEW_SIZE = 1440

@lru_cache
def ffbin(name: str) -> str:
    """Resolve ffmpeg/ffprobe even when the winget PATH entry isn't in this process."""
    found = shutil.which(name)
    if found:
        return found
    winget = Path(os.environ.get("LOCALAPPDATA", "")) / "Microsoft" / "WinGet" / "Packages"
    if winget.is_dir():
        for candidate in winget.glob(f"Gyan.FFmpeg*/*/bin/{name}.exe"):
            return str(candidate)
    return name  # let subprocess fail with a clear error


# EXIF tag ids
TAG_DATETIME_ORIGINAL = 0x9003
TAG_MAKE = 0x010F
TAG_MODEL = 0x0110
GPS_LAT_REF, GPS_LAT, GPS_LON_REF, GPS_LON = 1, 2, 3, 4
EXIF_IFD, GPS_IFD = 0x8769, 0x8825


def classify(ext: str) -> str | None:
    ext = ext.lower()
    if ext in IMAGE_EXTS:
        return "image"
    if ext in VIDEO_EXTS:
        return "video"
    return None


def _parse_exif_datetime(value: str) -> datetime | None:
    try:
        return datetime.strptime(value.strip(), "%Y:%m:%d %H:%M:%S").replace(tzinfo=timezone.utc)
    except (ValueError, AttributeError):
        return None


def _gps_to_decimal(dms, ref) -> float | None:
    try:
        deg = float(dms[0]) + float(dms[1]) / 60 + float(dms[2]) / 3600
        if ref in ("S", "W"):
            deg = -deg
        return deg
    except (TypeError, ValueError, IndexError, ZeroDivisionError):
        return None


def extract_image_metadata(path: Path) -> dict:
    """Runs in a thread. Returns dict of asset fields extracted from the image."""
    meta: dict = {}
    with Image.open(path) as im:
        # exif_transpose-aware dimensions
        orientation_swapped = False
        exif = im.getexif()
        if exif.get(0x0112) in (5, 6, 7, 8):
            orientation_swapped = True
        meta["width"], meta["height"] = (
            (im.height, im.width) if orientation_swapped else (im.width, im.height)
        )
        make = exif.get(TAG_MAKE)
        model = exif.get(TAG_MODEL)
        meta["camera_make"] = str(make).strip("\x00 ") if make else None
        meta["camera_model"] = str(model).strip("\x00 ") if model else None

        try:
            exif_ifd = exif.get_ifd(EXIF_IFD)
            dt = exif_ifd.get(TAG_DATETIME_ORIGINAL)
            if dt:
                parsed = _parse_exif_datetime(str(dt))
                if parsed:
                    meta["taken_at"] = parsed
        except Exception:
            pass

        try:
            gps = exif.get_ifd(GPS_IFD)
            if gps and GPS_LAT in gps and GPS_LON in gps:
                lat = _gps_to_decimal(gps[GPS_LAT], gps.get(GPS_LAT_REF))
                lon = _gps_to_decimal(gps[GPS_LON], gps.get(GPS_LON_REF))
                if lat is not None and lon is not None:
                    meta["gps_lat"], meta["gps_lon"] = lat, lon
        except Exception:
            pass
    return meta


async def extract_video_metadata(path: Path) -> dict:
    meta: dict = {}
    proc = await asyncio.create_subprocess_exec(
        ffbin("ffprobe"), "-v", "quiet", "-print_format", "json", "-show_format", "-show_streams",
        str(path),
        stdout=asyncio.subprocess.PIPE,
        stderr=asyncio.subprocess.DEVNULL,
    )
    out, _ = await proc.communicate()
    if proc.returncode != 0 or not out:
        return meta
    try:
        info = json.loads(out)
    except json.JSONDecodeError:
        return meta

    fmt = info.get("format", {})
    if fmt.get("duration"):
        try:
            meta["duration_sec"] = float(fmt["duration"])
        except ValueError:
            pass
    creation = (fmt.get("tags") or {}).get("creation_time")
    if creation:
        try:
            meta["taken_at"] = datetime.fromisoformat(creation.replace("Z", "+00:00"))
        except ValueError:
            pass
    for stream in info.get("streams", []):
        if stream.get("codec_type") == "video":
            meta["width"] = stream.get("width")
            meta["height"] = stream.get("height")
            # rotation side data can swap dimensions
            rotation = 0
            for sd in stream.get("side_data_list", []) or []:
                if "rotation" in sd:
                    rotation = abs(int(sd["rotation"]))
            if rotation in (90, 270) and meta.get("width") and meta.get("height"):
                meta["width"], meta["height"] = meta["height"], meta["width"]
            break
    return meta


def _generate_image_thumbs(original: Path, out_dir: Path) -> None:
    """Runs in a thread."""
    with Image.open(original) as im:
        im = ImageOps.exif_transpose(im)
        if im.mode not in ("RGB", "RGBA"):
            im = im.convert("RGB")
        preview = im.copy()
        preview.thumbnail((PREVIEW_SIZE, PREVIEW_SIZE))
        preview.save(out_dir / "preview.webp", "WEBP", quality=80)
        thumb = im.copy()
        thumb.thumbnail((THUMB_SIZE, THUMB_SIZE))
        thumb.save(out_dir / "thumb.webp", "WEBP", quality=70)


async def _generate_video_thumbs(original: Path, out_dir: Path) -> None:
    frame = out_dir / "frame.jpg"
    for seek in ("1", "0"):  # very short videos have no frame at t=1s
        proc = await asyncio.create_subprocess_exec(
            ffbin("ffmpeg"), "-y", "-v", "quiet", "-ss", seek, "-i", str(original),
            "-frames:v", "1", str(frame),
            stdout=asyncio.subprocess.DEVNULL,
            stderr=asyncio.subprocess.DEVNULL,
        )
        await proc.communicate()
        if proc.returncode == 0 and frame.exists() and frame.stat().st_size > 0:
            break
    if not frame.exists() or frame.stat().st_size == 0:
        raise RuntimeError("ffmpeg could not extract a frame")
    try:
        await asyncio.to_thread(_generate_image_thumbs, frame, out_dir)
    finally:
        frame.unlink(missing_ok=True)


class ThumbnailWorker:
    """Single-consumer queue so bulk uploads don't fork 200 concurrent ffmpeg/Pillow jobs."""

    def __init__(self, sessionmaker):
        self.sessionmaker = sessionmaker
        self.queue: asyncio.Queue[uuid.UUID] = asyncio.Queue()
        self._task: asyncio.Task | None = None

    def enqueue(self, asset_id: uuid.UUID) -> None:
        self.queue.put_nowait(asset_id)

    async def start(self) -> None:
        async with self.sessionmaker() as db:
            pending = await db.scalars(select(Asset.id).where(Asset.thumb_status == "pending"))
            for asset_id in pending:
                self.enqueue(asset_id)
        self._task = asyncio.create_task(self._run())

    async def stop(self) -> None:
        if self._task:
            self._task.cancel()
            try:
                await self._task
            except asyncio.CancelledError:
                pass

    async def _run(self) -> None:
        while True:
            asset_id = await self.queue.get()
            try:
                await self._process(asset_id)
            except asyncio.CancelledError:
                raise
            except Exception:
                log.exception("thumbnail generation failed for %s", asset_id)
            finally:
                self.queue.task_done()

    async def _process(self, asset_id: uuid.UUID) -> None:
        async with self.sessionmaker() as db:
            asset = await db.get(Asset, asset_id)
            if asset is None or asset.thumb_status == "done":
                return
            original = storage.absolute_from_root(asset.file_path)
            out_dir = storage.thumb_dir(asset.owner_id, asset.id)
            try:
                if asset.asset_type == "image":
                    await asyncio.to_thread(_generate_image_thumbs, original, out_dir)
                else:
                    await _generate_video_thumbs(original, out_dir)
                asset.thumb_status = "done"
            except Exception:
                log.exception("thumb failed: %s (%s)", asset.id, asset.original_filename)
                asset.thumb_status = "failed"
            await db.commit()


def move_into_library(tmp: Path, dest: Path) -> None:
    """Atomic when same volume; falls back to copy+delete across volumes."""
    try:
        tmp.replace(dest)
    except OSError:
        shutil.copy2(tmp, dest)
        tmp.unlink(missing_ok=True)
