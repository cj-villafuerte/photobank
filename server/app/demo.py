"""Demo mode: a public Photobank that anyone - App Review included - can log into.

Enabled with DEMO_MODE=true. What changes:

- one shared, non-admin demo account (DEMO_EMAIL / DEMO_PASSWORD); registration
  and password changes are off, so nobody can lock the next visitor out
- a seeded, read-only sample library: generated photos with real EXIF dates,
  marked by ``Asset.taken_at_source == "demo"``; they can be browsed, favorited
  and put in albums, but not trashed, hidden or deleted
- uploads: images only, capped per file / in number / in total bytes across all
  users, and purged DEMO_UPLOAD_TTL_SECONDS after they land
- /assets/exists and /assets/match never report anything, so a phone can never be
  told "the server holds this" and free up space by deleting its own copy
- admin, backup/import/export, reveal-in-explorer and live-video endpoints are 403
- everything visitors change on the sample library resets every DEMO_RESET_MINUTES

Built for a small container (0.5 GB RAM, 1 GB disk): single worker, no video
(no ffmpeg), small seed images.
"""

from __future__ import annotations

import asyncio
import hashlib
import json
import logging
import random
import uuid
from datetime import datetime, timedelta, timezone
from pathlib import Path

from fastapi import HTTPException
from sqlalchemy import delete, func, select, true, update

from . import ingest, storage
from .auth import hash_password, verify_password
from .config import settings
from .models import Album, AlbumAsset, AppSetting, Asset, User

log = logging.getLogger("photobank.demo")

SEED_SOURCE = "demo"  # Asset.taken_at_source value that marks the sample library
SEED_ALBUMS_KEY = "demo_seed_albums"  # app_settings: {album_id: {"name", "assets": [ids]}}


# ---------------------------------------------------------------- request guards


def enabled() -> bool:
    return settings.demo_mode


def public_info() -> dict | None:
    """What clients need to adapt (served by /api/health). None when off."""
    if not enabled():
        return None
    return {
        "email": settings.demo_email,
        "password": settings.demo_password,
        "upload_ttl_seconds": settings.demo_upload_ttl_seconds,
        "max_uploads": settings.demo_max_uploads,
        "max_upload_mb": settings.demo_max_upload_mb,
    }


def _forbid(detail: str) -> None:
    raise HTTPException(status_code=403, detail=detail)


async def block_in_demo() -> None:
    """Route/router dependency: 403 for anything the demo server doesn't offer."""
    if enabled():
        _forbid("Not available on the demo server")


def is_seed(asset: Asset) -> bool:
    return asset.taken_at_source == SEED_SOURCE


def guard_seed(asset: Asset, action: str) -> None:
    if enabled() and is_seed(asset):
        _forbid(
            f"The demo library is read-only: you can't {action} the sample photos. "
            "Upload one of your own to try it."
        )


def mutable():
    """SQL filter for bulk mutations: on the demo server the seeds are excluded."""
    return (Asset.taken_at_source != SEED_SOURCE) if enabled() else true()


def check_upload_type(asset_type: str) -> None:
    if enabled() and asset_type != "image":
        raise HTTPException(status_code=415, detail="The demo server accepts images only")


def max_upload_bytes() -> int | None:
    return settings.demo_max_upload_mb * 1024 * 1024 if enabled() else None


async def check_upload_capacity(db) -> None:
    if not enabled():
        return
    count, total = (
        await db.execute(
            select(func.count(), func.coalesce(func.sum(Asset.file_size), 0)).where(
                Asset.taken_at_source != SEED_SOURCE
            )
        )
    ).one()
    ttl = settings.demo_upload_ttl_seconds
    if count >= settings.demo_max_uploads:
        raise HTTPException(
            status_code=429,
            detail=(
                f"Demo upload limit reached ({settings.demo_max_uploads} at a time). "
                f"Uploads are removed after {ttl} s - try again in a moment."
            ),
        )
    if total >= settings.demo_max_total_upload_mb * 1024 * 1024:
        raise HTTPException(
            status_code=429, detail="Demo upload storage is full for the moment - try again shortly."
        )


# ---------------------------------------------------------------- sample library

# (scene caption, album it belongs to) - cycled to fill DEMO_SEED_COUNT
SCENES = [
    ("Lake morning", "Trips"),
    ("Old town", "Trips"),
    ("Birthday", "Family"),
    ("Hike", "Trips"),
    ("Beach", "Trips"),
    ("Coffee", None),
    ("Concert", None),
    ("Garden", "Family"),
    ("Snow day", "Family"),
    ("Road trip", "Trips"),
    ("Museum", None),
    ("Sunset", None),
]

# sky-ish gradient pairs (top, bottom)
PALETTES = [
    ((250, 200, 130), (140, 90, 170)),
    ((120, 170, 230), (230, 240, 250)),
    ((255, 140, 90), (60, 40, 90)),
    ((190, 220, 200), (70, 120, 110)),
    ((240, 220, 200), (120, 100, 90)),
    ((80, 110, 160), (200, 150, 140)),
    ((250, 230, 120), (220, 120, 80)),
    ((160, 200, 240), (90, 100, 140)),
]


def _mix(a, b, t: float):
    return tuple(int(a[i] + (b[i] - a[i]) * t) for i in range(3))


# Bump when the generated library should be rebuilt on existing deployments.
SEED_VERSION = "2"
SEED_VERSION_KEY = "demo_seed_version"


def _fetch_stock_photo(seed: str, w: int, h: int):
    """A real photograph from picsum.photos (Unsplash-licensed, free to use).

    Deterministic per seed. Returns a PIL image, or raises on any network problem.
    """
    import io
    import urllib.request

    from PIL import Image

    req = urllib.request.Request(f"https://picsum.photos/seed/{seed}/{w}/{h}", headers={"User-Agent": "photobank-demo"})
    with urllib.request.urlopen(req, timeout=10) as r:
        data = r.read()
    im = Image.open(io.BytesIO(data))
    im.load()
    return im.convert("RGB")


def _painted_photo(rnd: random.Random, w: int, h: int, top, bottom, caption: str):
    """Offline fallback: a minimalist landscape poster with a caption."""
    from PIL import Image, ImageDraw, ImageFont

    img = Image.new("RGB", (w, h))
    d = ImageDraw.Draw(img)
    for y in range(h):  # vertical gradient = sky
        d.line((0, y, w, y), fill=_mix(top, bottom, y / h))
    horizon = int(h * rnd.uniform(0.55, 0.75))
    d.rectangle((0, horizon, w, h), fill=_mix(bottom, (20, 24, 28), 0.55))
    r = int(min(w, h) * rnd.uniform(0.08, 0.16))
    cx = int(w * rnd.uniform(0.2, 0.8))
    cy = int(horizon - r * rnd.uniform(0.6, 1.8))
    d.ellipse((cx - r, cy - r, cx + r, cy + r), fill=_mix(top, (255, 255, 255), 0.5))
    font = ImageFont.load_default(size=int(min(w, h) * 0.05))
    d.text((int(w * 0.05), int(h * 0.88)), caption, font=font, fill=(255, 255, 255))
    return img


def generate_sample_photos(work: Path, count: int) -> list[dict]:
    """Writes `count` JPEGs with EXIF dates spread over the last 14 months.

    Real photographs when the network allows (so the demo - and App Store screenshots
    taken against it - look like a photo library), painted posters otherwise.
    Runs in a thread. Deterministic (seeded RNG + fixed picsum seeds).
    """
    from PIL import Image

    rnd = random.Random(42)
    now = datetime.now(timezone.utc)
    specs: list[dict] = []
    network_ok = True
    failures = 0
    for i in range(count):
        scene, album = SCENES[i % len(SCENES)]
        days_back = int(i * (14 * 30) / max(count, 1)) + rnd.randint(0, 6)
        when = now - timedelta(days=days_back, hours=rnd.randint(5, 18), minutes=rnd.randint(0, 59))
        portrait = i % 5 == 3
        w, h = (1200, 1600) if portrait else (1600, 1200)
        top, bottom = PALETTES[i % len(PALETTES)]
        rnd_state = rnd.getstate()  # the painted fallback consumes the RNG; keep dates stable

        img = None
        if network_ok:
            try:
                img = _fetch_stock_photo(f"photobank-{i + 1}", w, h)
                failures = 0
            except Exception as e:  # offline, rate-limited, blocked: fall back quietly
                failures += 1
                log.warning("demo: stock photo %d unavailable (%s)", i + 1, type(e).__name__)
                if failures >= 3:
                    network_ok = False
                    log.warning("demo: no network for stock photos - painting the rest")
        if img is None:
            rnd.setstate(rnd_state)
            img = _painted_photo(rnd, w, h, top, bottom, f"{scene}  -  {when.strftime('%b %Y')}")

        stamp = when.strftime("%Y:%m:%d %H:%M:%S")
        exif = Image.Exif()
        exif[0x010F] = "Photobank"
        exif[0x0110] = "Demo camera"
        exif[0x0132] = stamp
        exif.get_ifd(0x8769)[0x9003] = stamp  # DateTimeOriginal
        filename = f"demo-{i + 1:02d}-{scene.lower().replace(' ', '-')}.jpg"
        path = work / filename
        img.save(path, "JPEG", quality=82, optimize=True, exif=exif.tobytes())
        specs.append({"path": path, "filename": filename, "scene": scene, "album": album})
    return specs


# ---------------------------------------------------------------- keeper task


class DemoKeeper:
    """Seeds the demo account/library on start, then purges expired uploads every
    second and resets the sample library every DEMO_RESET_MINUTES."""

    def __init__(self, sessionmaker, worker):
        self.sessionmaker = sessionmaker
        self.worker = worker
        self._task: asyncio.Task | None = None

    async def start(self) -> None:
        async with self.sessionmaker() as db:
            user = await self._ensure_user(db)
            await self._ensure_seed(db, user)
            await self.reset(db)
        self._task = asyncio.create_task(self._loop())
        log.info(
            "demo mode: account %s, uploads live %ss (max %s / %s MB), reset every %s min",
            settings.demo_email, settings.demo_upload_ttl_seconds, settings.demo_max_uploads,
            settings.demo_max_total_upload_mb, settings.demo_reset_minutes,
        )

    async def stop(self) -> None:
        if self._task:
            self._task.cancel()
            try:
                await self._task
            except asyncio.CancelledError:
                pass

    async def _loop(self) -> None:
        last_reset = datetime.now(timezone.utc)
        while True:
            await asyncio.sleep(1)
            try:
                async with self.sessionmaker() as db:
                    await self.purge_expired(db)
                    if datetime.now(timezone.utc) - last_reset >= timedelta(minutes=settings.demo_reset_minutes):
                        await self.reset(db)
                        last_reset = datetime.now(timezone.utc)
            except asyncio.CancelledError:
                raise
            except Exception:
                log.exception("demo keeper tick failed")

    async def _ensure_user(self, db) -> User:
        email = settings.demo_email.lower()
        user = await db.scalar(select(User).where(User.email == email))
        if user is None:
            user = User(
                email=email, display_name="Demo", is_admin=False,
                password_hash=hash_password(settings.demo_password),
            )
            db.add(user)
            await db.commit()
            await db.refresh(user)
        elif (
            user.is_admin or not user.is_active
            or not verify_password(user.password_hash, settings.demo_password)
        ):
            # env changed or someone got creative: put the account back the way it should be
            user.is_admin = False
            user.is_active = True
            user.password_hash = hash_password(settings.demo_password)
            await db.commit()
        return user

    async def _ensure_seed(self, db, user: User) -> None:
        have = await db.scalar(
            select(func.count()).select_from(Asset).where(
                Asset.owner_id == user.id, Asset.taken_at_source == SEED_SOURCE
            )
        )
        version = await db.get(AppSetting, SEED_VERSION_KEY)
        if have and version is not None and version.value == SEED_VERSION:
            return
        if have:
            # the generator changed: rebuild the sample library from scratch
            log.info("demo: sample library is v%s, rebuilding as v%s", version.value if version else "?", SEED_VERSION)
            for asset in (await db.scalars(select(Asset).where(Asset.taken_at_source == SEED_SOURCE))).all():
                storage.delete_asset_files(asset.owner_id, asset.id, asset.file_path, asset.live_video_path)
                await db.delete(asset)
            for album in (await db.scalars(select(Album))).all():
                await db.delete(album)
            albums_setting = await db.get(AppSetting, SEED_ALBUMS_KEY)
            if albums_setting is not None:
                await db.delete(albums_setting)
            await db.commit()
        log.info("demo: generating %d sample photos", settings.demo_seed_count)
        work = settings.tmp_dir / "demo-seed"
        work.mkdir(parents=True, exist_ok=True)
        specs = await asyncio.to_thread(generate_sample_photos, work, settings.demo_seed_count)

        by_album: dict[str, list[str]] = {}
        for spec in specs:
            asset = await self._ingest(db, user, spec)
            if spec["album"]:
                by_album.setdefault(spec["album"], []).append(str(asset.id))

        albums_spec: dict[str, dict] = {}
        for name, ids in by_album.items():
            album = Album(owner_id=user.id, name=name, cover_asset_id=uuid.UUID(ids[0]))
            db.add(album)
            await db.flush()
            for aid in ids:
                db.add(AlbumAsset(album_id=album.id, asset_id=uuid.UUID(aid)))
            albums_spec[str(album.id)] = {"name": name, "assets": ids}
        db.add(AppSetting(key=SEED_ALBUMS_KEY, value=json.dumps(albums_spec)))
        version = await db.get(AppSetting, SEED_VERSION_KEY)
        if version is None:
            db.add(AppSetting(key=SEED_VERSION_KEY, value=SEED_VERSION))
        else:
            version.value = SEED_VERSION
        await db.commit()

    async def _ingest(self, db, user: User, spec: dict) -> Asset:
        path: Path = spec["path"]
        checksum = hashlib.sha256(path.read_bytes()).hexdigest()
        meta = await asyncio.to_thread(ingest.extract_image_metadata, path)
        taken_at = meta.pop("taken_at", None) or datetime.now(timezone.utc)
        asset_id = uuid.uuid4()
        dest = storage.library_path(user.id, asset_id, taken_at, path.suffix.lower())
        ingest.move_into_library(path, dest)
        asset = Asset(
            id=asset_id,
            owner_id=user.id,
            checksum=checksum,
            original_filename=spec["filename"],
            file_path=storage.relative_to_root(dest),
            file_size=dest.stat().st_size,
            mime_type="image/jpeg",
            asset_type="image",
            taken_at=taken_at,
            taken_at_source=SEED_SOURCE,
            **{k: v for k, v in meta.items() if v is not None},
        )
        db.add(asset)
        await db.commit()
        await db.refresh(asset)
        self.worker.enqueue(asset.id)
        return asset

    async def purge_expired(self, db) -> None:
        cutoff = datetime.now(timezone.utc) - timedelta(seconds=settings.demo_upload_ttl_seconds)
        expired = (
            await db.scalars(
                select(Asset).where(Asset.taken_at_source != SEED_SOURCE, Asset.created_at < cutoff)
            )
        ).all()
        for asset in expired:
            storage.delete_asset_files(asset.owner_id, asset.id, asset.file_path, asset.live_video_path)
            await db.delete(asset)
        if expired:
            await db.commit()

    async def reset(self, db) -> None:
        """Uploads go, the sample library returns to its pristine state."""
        uploads = (await db.scalars(select(Asset).where(Asset.taken_at_source != SEED_SOURCE))).all()
        for asset in uploads:
            storage.delete_asset_files(asset.owner_id, asset.id, asset.file_path, asset.live_video_path)
            await db.delete(asset)
        await db.execute(
            update(Asset)
            .where(Asset.taken_at_source == SEED_SOURCE)
            .values(is_favorite=False, hidden_at=None, trashed_at=None)
        )
        setting = await db.get(AppSetting, SEED_ALBUMS_KEY)
        spec: dict[str, dict] = json.loads(setting.value) if setting else {}
        for album in (await db.scalars(select(Album))).all():
            if str(album.id) not in spec:
                await db.delete(album)  # album_assets cascade at the DB
        for album_id, info in spec.items():
            album = await db.get(Album, uuid.UUID(album_id))
            if album is None:
                continue
            album.name = info["name"]
            await db.execute(delete(AlbumAsset).where(AlbumAsset.album_id == album.id))
            for aid in info["assets"]:
                db.add(AlbumAsset(album_id=album.id, asset_id=uuid.UUID(aid)))
            album.cover_asset_id = uuid.UUID(info["assets"][0]) if info["assets"] else None
        await db.commit()
        if uploads:
            log.info("demo reset: removed %d uploads, restored the sample library", len(uploads))
