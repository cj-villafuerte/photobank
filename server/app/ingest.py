"""Metadata extraction and background thumbnail generation."""

import asyncio
import json
import logging
import mimetypes
import os
import shutil
import subprocess
import uuid
from datetime import datetime, timezone
from functools import lru_cache
from pathlib import Path

import io

from PIL import Image, ImageCms, ImageOps
from sqlalchemy import select

from . import storage
from .models import Asset

log = logging.getLogger("photobank.ingest")

IMAGE_EXTS = {".jpg", ".jpeg", ".png", ".gif", ".webp", ".heic", ".heif", ".bmp", ".tiff", ".tif", ".avif"}
VIDEO_EXTS = {".mp4", ".mov", ".m4v", ".webm", ".mkv", ".avi", ".3gp"}

THUMB_SIZE = 320
PREVIEW_SIZE = 1440

# keep helper processes from flashing console windows when run from the desktop app
NO_WINDOW = {"creationflags": subprocess.CREATE_NO_WINDOW} if os.name == "nt" else {}


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


@lru_cache
def tessbin() -> str | None:
    """Tesseract OCR binary, or None if not installed (OCR stays pending)."""
    found = shutil.which("tesseract")
    if found:
        return found
    for candidate in (
        Path("C:/Program Files/Tesseract-OCR/tesseract.exe"),
        Path(os.environ.get("LOCALAPPDATA", "")) / "Programs" / "Tesseract-OCR" / "tesseract.exe",
    ):
        if candidate.is_file():
            return str(candidate)
    return None


def compute_dhash(image_path: Path) -> int:
    """64-bit difference hash; visually similar images differ in few bits. Thread."""
    with Image.open(image_path) as im:
        im = im.convert("L").resize((9, 8), Image.LANCZOS)
        px = list(im.getdata())
    bits = 0
    for row in range(8):
        for col in range(8):
            bits = (bits << 1) | (1 if px[row * 9 + col] > px[row * 9 + col + 1] else 0)
    return bits - (1 << 64) if bits >= (1 << 63) else bits  # signed for BIGINT


def _preview_to_png(preview: Path, png: Path) -> tuple[int, int]:
    """Thread. Tesseract input; returns dimensions for box normalization."""
    with Image.open(preview) as im:
        im.save(png, "PNG")
        return im.width, im.height


async def run_ocr(preview: Path, work_dir: Path) -> list[dict]:
    """OCR the preview; returns words with boxes normalized 0-1 to preview size."""
    tess = tessbin()
    if tess is None:
        raise RuntimeError("tesseract not installed")
    png = work_dir / f"ocr-{uuid.uuid4().hex}.png"
    try:
        width, height = await asyncio.to_thread(_preview_to_png, preview, png)
        proc = await asyncio.create_subprocess_exec(
            tess, str(png), "stdout", "tsv",
            stdout=asyncio.subprocess.PIPE,
            stderr=asyncio.subprocess.DEVNULL,
            **NO_WINDOW,
        )
        out, _ = await proc.communicate()
        if proc.returncode != 0:
            raise RuntimeError(f"tesseract exited {proc.returncode}")
        words = []
        for line in out.decode("utf-8", errors="ignore").splitlines()[1:]:
            cols = line.split("\t")
            if len(cols) < 12 or cols[0] != "5":  # level 5 = word
                continue
            text = cols[11].strip()
            try:
                conf = float(cols[10])
            except ValueError:
                continue
            if not text or conf < 60:
                continue
            left, top, w, h = (int(cols[6]), int(cols[7]), int(cols[8]), int(cols[9]))
            words.append({
                "word": text,
                "x": left / width, "y": top / height,
                "w": w / width, "h": h / height,
            })
        return words
    finally:
        png.unlink(missing_ok=True)


# EXIF tag ids
TAG_DATETIME_ORIGINAL = 0x9003
TAG_MAKE = 0x010F
TAG_MODEL = 0x0110
GPS_LAT_REF, GPS_LAT, GPS_LON_REF, GPS_LON = 1, 2, 3, 4
EXIF_IFD, GPS_IFD = 0x8769, 0x8825


EXTRA_MIME = {
    ".heic": "image/heic", ".heif": "image/heif", ".avif": "image/avif",
    ".mov": "video/quicktime", ".m4v": "video/x-m4v", ".3gp": "video/3gpp",
}


def guess_mime(ext: str, declared: str | None) -> str:
    """Trust the client's type unless it's missing/generic, then go by extension."""
    if declared and declared != "application/octet-stream":
        return declared
    ext = ext.lower()
    if ext in EXTRA_MIME:
        return EXTRA_MIME[ext]
    guessed, _ = mimetypes.guess_type(f"f{ext}")
    return guessed or "application/octet-stream"


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
        **NO_WINDOW,
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


def _to_srgb(im: Image.Image) -> Image.Image:
    """Convert wide-gamut images (e.g. iPhone Display-P3 HEIC) to sRGB.

    Without this, dropping the ICC profile leaves colors looking washed out.
    """
    icc = im.info.get("icc_profile")
    if not icc or im.mode != "RGB":
        return im
    try:
        src = ImageCms.ImageCmsProfile(io.BytesIO(icc))
        dst = ImageCms.createProfile("sRGB")
        converted = ImageCms.profileToProfile(im, src, dst, outputMode="RGB")
        return converted if converted is not None else im
    except Exception:
        return im


def _generate_image_thumbs(original: Path, out_dir: Path) -> None:
    """Runs in a thread."""
    with Image.open(original) as im:
        im = ImageOps.exif_transpose(im)
        if im.mode not in ("RGB", "RGBA"):
            im = im.convert("RGB")
        im = _to_srgb(im)
        preview = im.copy()
        preview.thumbnail((PREVIEW_SIZE, PREVIEW_SIZE))
        preview.save(out_dir / "preview.webp", "WEBP", quality=80)
        thumb = im.copy()
        thumb.thumbnail((THUMB_SIZE, THUMB_SIZE))
        thumb.save(out_dir / "thumb.webp", "WEBP", quality=70)


async def _is_hdr_video(path: Path) -> bool:
    """HDR transfer functions (PQ/HLG) need tone mapping or frame grabs look washed out."""
    proc = await asyncio.create_subprocess_exec(
        ffbin("ffprobe"), "-v", "quiet", "-select_streams", "v:0",
        "-show_entries", "stream=color_transfer", "-of", "csv=p=0", str(path),
        stdout=asyncio.subprocess.PIPE,
        stderr=asyncio.subprocess.DEVNULL,
        **NO_WINDOW,
    )
    out, _ = await proc.communicate()
    return out.decode(errors="ignore").strip() in ("smpte2084", "arib-std-b67")


# zscale (libzimg, included in the Gyan full build) does linearize -> tonemap -> bt709
HDR_TONEMAP = "zscale=t=linear:npl=100,tonemap=hable:desat=0,zscale=p=bt709:t=bt709:m=bt709:r=tv,format=yuv420p"


async def _generate_video_thumbs(original: Path, out_dir: Path) -> None:
    frame = out_dir / "frame.jpg"
    tonemap = ["-vf", HDR_TONEMAP] if await _is_hdr_video(original) else []
    for seek in ("1", "0"):  # very short videos have no frame at t=1s
        proc = await asyncio.create_subprocess_exec(
            ffbin("ffmpeg"), "-y", "-v", "quiet", "-ss", seek, "-i", str(original),
            *tonemap, "-frames:v", "1", str(frame),
            stdout=asyncio.subprocess.DEVNULL,
            stderr=asyncio.subprocess.DEVNULL,
            **NO_WINDOW,
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


THUMB, ANALYZE = 0, 1  # queue priorities: thumbnails always before fingerprint/OCR


class ThumbnailWorker:
    """Single consumer so bulk uploads don't fork 200 concurrent ffmpeg/Pillow jobs.

    Two priorities: 'thumb' jobs (what the user sees) always run before
    'analyze' jobs (dHash + OCR), so fresh uploads never wait behind a long
    text-indexing backlog.
    """

    def __init__(self, sessionmaker):
        self.sessionmaker = sessionmaker
        self.queue: asyncio.PriorityQueue = asyncio.PriorityQueue()
        self._seq = 0
        self._task: asyncio.Task | None = None

    def enqueue(self, asset_id: uuid.UUID, priority: int = THUMB) -> None:
        self._seq += 1
        self.queue.put_nowait((priority, self._seq, asset_id))

    async def start(self) -> None:
        from sqlalchemy import and_, or_

        async with self.sessionmaker() as db:
            thumbs = await db.scalars(
                select(Asset.id).where(Asset.thumb_status == "pending").order_by(Asset.created_at.desc())
            )
            for asset_id in thumbs:
                self.enqueue(asset_id, THUMB)
            analyze = await db.scalars(
                select(Asset.id).where(
                    Asset.thumb_status == "done",
                    Asset.asset_type == "image",
                    or_(Asset.phash.is_(None), Asset.ocr_status == "pending"),
                ).order_by(Asset.created_at.desc())
            )
            for asset_id in analyze:
                self.enqueue(asset_id, ANALYZE)
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
            priority, _seq, asset_id = await self.queue.get()
            try:
                if priority == THUMB:
                    await self._process_thumb(asset_id)
                else:
                    await self._process_analyze(asset_id)
            except asyncio.CancelledError:
                raise
            except Exception:
                log.exception("worker job failed for %s", asset_id)
            finally:
                self.queue.task_done()

    async def _process_thumb(self, asset_id: uuid.UUID) -> None:
        async with self.sessionmaker() as db:
            asset = await db.get(Asset, asset_id)
            if asset is None:
                return
            if asset.thumb_status != "done":
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
            if asset.asset_type == "image" and asset.thumb_status == "done":
                self.enqueue(asset.id, ANALYZE)  # fingerprint + OCR later, behind all thumbs
            elif asset.asset_type != "image" and asset.ocr_status == "pending":
                asset.ocr_status = "skipped"
                await db.commit()

    async def _process_analyze(self, asset_id: uuid.UUID) -> None:
        from .config import settings
        from .models import AssetText

        async with self.sessionmaker() as db:
            asset = await db.get(Asset, asset_id)
            if asset is None or asset.asset_type != "image":
                return
            out_dir = storage.thumb_dir(asset.owner_id, asset.id)
            preview = out_dir / "preview.webp"
            if preview.is_file():
                if asset.phash is None:
                    try:
                        asset.phash = await asyncio.to_thread(compute_dhash, preview)
                    except Exception:
                        log.exception("dhash failed: %s", asset.id)
                if asset.ocr_status == "pending":
                    if tessbin() is None:
                        pass  # stays pending; retried after tesseract is installed
                    else:
                        try:
                            words = await run_ocr(preview, settings.tmp_dir)
                            db.add_all(
                                AssetText(asset_id=asset.id, **word) for word in words
                            )
                            await db.flush()  # surface insert errors here, not at commit
                            asset.ocr_status = "done"
                        except Exception:
                            log.exception("ocr failed: %s", asset.id)
                            await db.rollback()
                            asset = await db.get(Asset, asset_id)
                            if asset is not None:
                                asset.ocr_status = "failed"
            await db.commit()


def move_into_library(tmp: Path, dest: Path) -> None:
    """Atomic when same volume; falls back to copy+delete across volumes."""
    try:
        tmp.replace(dest)
    except OSError:
        shutil.copy2(tmp, dest)
        tmp.unlink(missing_ok=True)
