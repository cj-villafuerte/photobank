import hashlib
import subprocess
import sys
import uuid
from datetime import datetime, timedelta, timezone
from pathlib import Path

from fastapi import APIRouter, Depends, Form, HTTPException, Request, UploadFile
from fastapi.responses import FileResponse, Response
from sqlalchemy import delete, func, select, update
from sqlalchemy.ext.asyncio import AsyncSession

from .. import demo, ingest, storage
from ..auth import get_current_user
from ..config import settings
from ..db import get_db
from ..models import Asset, AssetText, User
from ..schemas import (
    AssetIds,
    AssetOut,
    AssetPatch,
    AssetThin,
    ChecksumsIn,
    ChecksumsOut,
    DailyStat,
    DuplicateGroup,
    ExistsDetail,
    MatchIn,
    MatchOut,
    MatchResult,
    StatsOut,
    TextMatch,
    TextSearchResult,
    TimelineBucket,
    UploadResult,
)

router = APIRouter(prefix="/api", tags=["assets"])

CACHE_FOREVER = "private, max-age=31536000, immutable"


def _date_bucket(db: AsyncSession, column, pg_fmt: str, sqlite_fmt: str):
    """Date-formatting expression that works on both Postgres and SQLite."""
    if db.get_bind().dialect.name == "sqlite":
        return func.strftime(sqlite_fmt, column)
    return func.to_char(column, pg_fmt)

# 1x1 transparent PNG placeholder for assets whose thumbnails aren't ready
PLACEHOLDER_PNG = bytes.fromhex(
    "89504e470d0a1a0a0000000d494844520000000100000001080600000"
    "01f15c4890000000d4944415478da63fcffffff030005fe02fea736b1"
    "580000000049454e44ae426082"
)


async def _get_owned_asset(asset_id: uuid.UUID, user: User, db: AsyncSession) -> Asset:
    asset = await db.get(Asset, asset_id)
    if asset is None or asset.owner_id != user.id:
        raise HTTPException(status_code=404, detail="Asset not found")
    return asset


@router.post("/assets", response_model=UploadResult, status_code=201)
async def upload_asset(
    request: Request,
    file: UploadFile,
    last_modified_ms: int | None = Form(default=None),
    user: User = Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
):
    filename = file.filename or "unnamed"
    ext = Path(filename).suffix.lower()
    asset_type = ingest.classify(ext)
    if asset_type is None:
        raise HTTPException(status_code=415, detail=f"Unsupported file type: {ext or 'unknown'}")
    demo.check_upload_type(asset_type)
    await demo.check_upload_capacity(db)
    size_limit = demo.max_upload_bytes()

    # stream to temp while hashing
    tmp = storage.tmp_path()
    sha = hashlib.sha256()
    size = 0
    try:
        with open(tmp, "wb") as out:
            while chunk := await file.read(1024 * 1024):
                sha.update(chunk)
                size += len(chunk)
                if size_limit is not None and size > size_limit:
                    raise HTTPException(
                        status_code=413,
                        detail=f"The demo server takes files up to {settings.demo_max_upload_mb} MB",
                    )
                out.write(chunk)
        if size == 0:
            raise HTTPException(status_code=400, detail="Empty file")
        checksum = sha.hexdigest()

        existing = await db.scalar(
            select(Asset.id).where(Asset.owner_id == user.id, Asset.checksum == checksum)
        )
        if existing:
            tmp.unlink(missing_ok=True)
            return Response(
                content=UploadResult(duplicate=True, asset_id=existing).model_dump_json(),
                media_type="application/json",
                status_code=200,
            )

        # metadata
        meta: dict = {}
        if asset_type == "image":
            try:
                meta = await ingest_image_meta(tmp)
            except Exception:
                meta = {}
        else:
            meta = await ingest.extract_video_metadata(tmp)

        taken_at = meta.pop("taken_at", None)
        if taken_at is not None:
            taken_at_source = "exif"
        elif last_modified_ms:
            taken_at = datetime.fromtimestamp(last_modified_ms / 1000, tz=timezone.utc)
            taken_at_source = "mtime"
        else:
            taken_at = datetime.now(timezone.utc)
            taken_at_source = "upload"

        asset_id = uuid.uuid4()
        dest = storage.library_path(user.id, asset_id, taken_at, ext)
        ingest.move_into_library(tmp, dest)

        asset = Asset(
            id=asset_id,
            owner_id=user.id,
            checksum=checksum,
            original_filename=filename,
            file_path=storage.relative_to_root(dest),
            file_size=size,
            mime_type=ingest.guess_mime(ext, file.content_type),
            asset_type=asset_type,
            taken_at=taken_at,
            taken_at_source=taken_at_source,
            **{k: v for k, v in meta.items() if v is not None},
        )
        db.add(asset)
        try:
            await db.commit()
        except Exception:
            await db.rollback()
            dest.unlink(missing_ok=True)
            # unique-constraint race: same file uploaded twice concurrently
            existing = await db.scalar(
                select(Asset.id).where(Asset.owner_id == user.id, Asset.checksum == checksum)
            )
            if existing:
                return Response(
                    content=UploadResult(duplicate=True, asset_id=existing).model_dump_json(),
                    media_type="application/json",
                    status_code=200,
                )
            raise
        await db.refresh(asset)
        request.app.state.thumb_worker.enqueue(asset.id)
        return UploadResult(duplicate=False, asset=AssetOut.model_validate(asset), asset_id=asset.id)
    finally:
        tmp.unlink(missing_ok=True)


async def ingest_image_meta(path: Path) -> dict:
    import asyncio

    return await asyncio.to_thread(ingest.extract_image_metadata, path)


@router.post("/assets/exists", response_model=ChecksumsOut)
async def assets_exist(
    body: ChecksumsIn,
    user: User = Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
):
    """Bulk dedup check so the mobile app can skip uploading photos the server already has."""
    if not body.checksums or demo.enabled():
        # demo: never confirm holding anything - phones must not free up space against it
        return ChecksumsOut(existing=[])
    rows = (
        await db.execute(
            select(Asset.checksum, Asset.id, Asset.live_video_path).where(
                Asset.owner_id == user.id, Asset.checksum.in_(body.checksums)
            )
        )
    ).all()
    return ChecksumsOut(
        existing=[r.checksum for r in rows],
        details=[
            ExistsDetail(
                checksum=r.checksum, asset_id=r.id, has_live_video=r.live_video_path is not None
            )
            for r in rows
        ],
    )


@router.post("/assets/match", response_model=MatchOut)
async def match_assets(
    body: MatchIn,
    user: User = Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
):
    """Cheap reconciliation for the mobile app: which device items are probably
    already on the server, matched by filename + capture time + dimensions
    (no hashing). Clients must still hash-verify before deleting anything."""
    if not body.items or demo.enabled():
        return MatchOut(matches=[])
    names = {i.name for i in body.items}
    rows = (
        await db.scalars(
            select(Asset).where(Asset.owner_id == user.id, Asset.original_filename.in_(names))
        )
    ).all()
    by_name: dict[str, list[Asset]] = {}
    for a in rows:
        by_name.setdefault(a.original_filename, []).append(a)

    def dims_ok(a: Asset, item) -> bool:
        if item.width is None or a.width is None:
            return True
        return {a.width, a.height} == {item.width, item.height}  # orientation-agnostic

    def time_ok(a: Asset, item) -> bool:
        if not item.taken_at:
            return False
        try:
            t = datetime.fromisoformat(item.taken_at)
        except ValueError:
            return False
        server = a.taken_at.replace(tzinfo=None)  # EXIF wall-clock stored as naive UTC
        return abs((server - t).total_seconds()) <= 2

    matches = []
    for item in body.items:
        candidates = [a for a in by_name.get(item.name, []) if dims_ok(a, item)]
        if not candidates:
            continue
        exact = [a for a in candidates if time_ok(a, item)]
        chosen = None
        if exact:
            chosen = exact[0]
        elif len(candidates) == 1 and item.width is not None:
            chosen = candidates[0]  # unique name+dims for this user
        if chosen is not None:
            matches.append(MatchResult(
                key=item.key, asset_id=chosen.id, checksum=chosen.checksum,
                has_live_video=chosen.live_video_path is not None,
            ))
    return MatchOut(matches=matches)


SORT_ORDERS = {
    "size_desc": lambda: Asset.file_size.desc(),
    "size_asc": lambda: Asset.file_size.asc(),
    "date_desc": lambda: Asset.taken_at.desc(),
    "date_asc": lambda: Asset.taken_at.asc(),
}


@router.get("/assets/list", response_model=list[AssetThin])
async def list_assets(
    sort: str = "size_desc",
    offset: int = 0,
    limit: int = 200,
    favorites: bool = False,
    user: User = Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
):
    """Flat, sortable listing (used by the by-size views)."""
    order = SORT_ORDERS.get(sort)
    if order is None:
        raise HTTPException(status_code=400, detail=f"Unknown sort: {sort}")
    stmt = (
        select(Asset)
        .where(Asset.owner_id == user.id, Asset.trashed_at.is_(None), Asset.hidden_at.is_(None))
        .order_by(order(), Asset.id)
        .offset(max(offset, 0))
        .limit(min(max(limit, 1), 500))
    )
    if favorites:
        stmt = stmt.where(Asset.is_favorite)
    return (await db.scalars(stmt)).all()


@router.post("/assets/{asset_id}/reveal", status_code=204, dependencies=[Depends(demo.block_in_demo)])
async def reveal_in_explorer(
    asset_id: uuid.UUID,
    user: User = Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
):
    """Opens the file manager on the SERVER machine with the original selected."""
    asset = await _get_owned_asset(asset_id, user, db)
    path = storage.absolute_from_root(asset.file_path)
    if not path.is_file():
        raise HTTPException(status_code=404, detail="File missing from storage")
    if sys.platform == "win32":
        subprocess.Popen(["explorer", f"/select,{path}"])
    elif sys.platform == "darwin":
        subprocess.Popen(["open", "-R", str(path)])  # Finder, file selected
    else:
        subprocess.Popen(["xdg-open", str(path.parent)])


@router.post("/assets/{asset_id}/live-video", response_model=AssetOut, dependencies=[Depends(demo.block_in_demo)])
async def attach_live_video(
    asset_id: uuid.UUID,
    file: UploadFile,
    user: User = Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
):
    """Store the ~3s video component of an iPhone Live Photo next to its still."""
    asset = await _get_owned_asset(asset_id, user, db)
    if asset.asset_type != "image":
        raise HTTPException(status_code=400, detail="Live video attaches to images only")
    if asset.live_video_path:
        return asset  # already attached - idempotent for re-syncs
    original = storage.absolute_from_root(asset.file_path)
    dest = original.parent / f"{original.stem}.live.mov"
    tmp = storage.tmp_path()
    size = 0
    try:
        with open(tmp, "wb") as out:
            while chunk := await file.read(1024 * 1024):
                size += len(chunk)
                out.write(chunk)
        if size == 0:
            raise HTTPException(status_code=400, detail="Empty file")
        ingest.move_into_library(tmp, dest)
        asset.live_video_path = storage.relative_to_root(dest)
        await db.commit()
        await db.refresh(asset)
        return asset
    finally:
        tmp.unlink(missing_ok=True)


@router.get("/assets/{asset_id}/live-video")
async def get_live_video(
    asset_id: uuid.UUID,
    user: User = Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
):
    asset = await _get_owned_asset(asset_id, user, db)
    if not asset.live_video_path:
        raise HTTPException(status_code=404, detail="No live video for this asset")
    path = storage.absolute_from_root(asset.live_video_path)
    if not path.is_file():
        raise HTTPException(status_code=404, detail="Live video missing from storage")
    return FileResponse(path, media_type="video/quicktime", headers={"Cache-Control": CACHE_FOREVER})


@router.get("/timeline/buckets", response_model=list[TimelineBucket])
async def timeline_buckets(
    favorites: bool = False,
    user: User = Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
):
    bucket = _date_bucket(db, Asset.taken_at, "YYYY-MM", "%Y-%m")
    stmt = (
        select(bucket.label("bucket"), func.count().label("count"))
        .where(Asset.owner_id == user.id, Asset.trashed_at.is_(None), Asset.hidden_at.is_(None))
        .group_by(bucket)
        .order_by(bucket.desc())
    )
    if favorites:
        stmt = stmt.where(Asset.is_favorite)
    rows = (await db.execute(stmt)).all()
    return [TimelineBucket(bucket=r.bucket, count=r.count) for r in rows]


@router.get("/timeline/bucket/{bucket}", response_model=list[AssetThin])
async def timeline_bucket(
    bucket: str,
    favorites: bool = False,
    user: User = Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
):
    try:
        datetime.strptime(bucket, "%Y-%m")
    except ValueError:
        raise HTTPException(status_code=400, detail="Bucket must be YYYY-MM")
    stmt = (
        select(Asset)
        .where(
            Asset.owner_id == user.id,
            Asset.trashed_at.is_(None),
            Asset.hidden_at.is_(None),
            _date_bucket(db, Asset.taken_at, "YYYY-MM", "%Y-%m") == bucket,
        )
        .order_by(Asset.taken_at.desc())
    )
    if favorites:
        stmt = stmt.where(Asset.is_favorite)
    assets = (await db.scalars(stmt)).all()
    return assets


@router.get("/assets/{asset_id}", response_model=AssetOut)
async def get_asset(
    asset_id: uuid.UUID,
    user: User = Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
):
    return await _get_owned_asset(asset_id, user, db)


def _thumb_response(path: Path) -> Response:
    if path.is_file():
        return FileResponse(path, media_type="image/webp", headers={"Cache-Control": CACHE_FOREVER})
    return Response(content=PLACEHOLDER_PNG, media_type="image/png", headers={"Cache-Control": "no-store"})


@router.get("/assets/{asset_id}/thumbnail")
async def get_thumbnail(
    asset_id: uuid.UUID,
    user: User = Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
):
    asset = await _get_owned_asset(asset_id, user, db)
    return _thumb_response(settings.thumbs_dir / str(asset.owner_id) / str(asset.id) / "thumb.webp")


@router.get("/assets/{asset_id}/preview")
async def get_preview(
    asset_id: uuid.UUID,
    user: User = Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
):
    asset = await _get_owned_asset(asset_id, user, db)
    return _thumb_response(settings.thumbs_dir / str(asset.owner_id) / str(asset.id) / "preview.webp")


@router.get("/assets/{asset_id}/original")
async def get_original(
    asset_id: uuid.UUID,
    download: bool = False,
    user: User = Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
):
    asset = await _get_owned_asset(asset_id, user, db)
    path = storage.absolute_from_root(asset.file_path)
    if not path.is_file():
        raise HTTPException(status_code=404, detail="File missing from storage")
    headers = {"Cache-Control": CACHE_FOREVER}
    if download:
        return FileResponse(
            path, media_type=asset.mime_type, headers=headers, filename=asset.original_filename
        )
    return FileResponse(path, media_type=asset.mime_type, headers=headers)


@router.patch("/assets/{asset_id}", response_model=AssetOut)
async def patch_asset(
    asset_id: uuid.UUID,
    body: AssetPatch,
    user: User = Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
):
    asset = await _get_owned_asset(asset_id, user, db)
    if body.is_favorite is not None:
        asset.is_favorite = body.is_favorite
    await db.commit()
    await db.refresh(asset)
    return asset


@router.delete("/assets/{asset_id}", status_code=204)
async def trash_asset(
    asset_id: uuid.UUID,
    user: User = Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
):
    asset = await _get_owned_asset(asset_id, user, db)
    demo.guard_seed(asset, "delete")
    asset.trashed_at = datetime.now(timezone.utc)
    await db.commit()


@router.delete("/assets/{asset_id}/permanent", status_code=204)
async def permanent_delete(
    asset_id: uuid.UUID,
    user: User = Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
):
    asset = await _get_owned_asset(asset_id, user, db)
    demo.guard_seed(asset, "delete")
    storage.delete_asset_files(asset.owner_id, asset.id, asset.file_path, asset.live_video_path)
    await db.delete(asset)
    await db.commit()


@router.post("/assets/hide", status_code=204)
async def hide_assets(
    body: AssetIds,
    user: User = Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
):
    await db.execute(
        update(Asset)
        .where(Asset.owner_id == user.id, Asset.id.in_(body.asset_ids), demo.mutable())
        .values(hidden_at=datetime.now(timezone.utc))
    )
    await db.commit()


@router.post("/assets/unhide", status_code=204)
async def unhide_assets(
    body: AssetIds,
    user: User = Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
):
    await db.execute(
        update(Asset)
        .where(Asset.owner_id == user.id, Asset.id.in_(body.asset_ids), demo.mutable())
        .values(hidden_at=None)
    )
    await db.commit()


@router.get("/hidden", response_model=list[AssetThin])
async def list_hidden(
    user: User = Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
):
    assets = await db.scalars(
        select(Asset)
        .where(
            Asset.owner_id == user.id,
            Asset.hidden_at.is_not(None),
            Asset.trashed_at.is_(None),
        )
        .order_by(Asset.taken_at.desc())
    )
    return assets.all()


@router.get("/duplicates", response_model=list[DuplicateGroup])
async def find_duplicates(
    user: User = Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
):
    """Groups of visually near-identical images (dHash hamming distance <= 6)."""
    assets = (
        await db.scalars(
            select(Asset).where(
                Asset.owner_id == user.id,
                Asset.asset_type == "image",
                Asset.phash.is_not(None),
                Asset.trashed_at.is_(None),
                Asset.hidden_at.is_(None),
            )
        )
    ).all()
    n = len(assets)
    parent = list(range(n))

    def find(i: int) -> int:
        while parent[i] != i:
            parent[i] = parent[parent[i]]
            i = parent[i]
        return i

    hashes = [a.phash & ((1 << 64) - 1) for a in assets]
    for i in range(n):
        for j in range(i + 1, n):
            if (hashes[i] ^ hashes[j]).bit_count() <= 6:
                parent[find(i)] = find(j)

    groups: dict[int, list[Asset]] = {}
    for i, a in enumerate(assets):
        groups.setdefault(find(i), []).append(a)

    result = []
    for members in groups.values():
        if len(members) < 2:
            continue
        members.sort(key=lambda a: a.file_size, reverse=True)
        wasted = sum(a.file_size for a in members[1:])
        result.append(
            DuplicateGroup(
                assets=[AssetThin.model_validate(a) for a in members], wasted_bytes=wasted
            )
        )
    result.sort(key=lambda g: g.wasted_bytes, reverse=True)
    return result


@router.get("/search/text", response_model=list[TextSearchResult])
async def search_text(
    q: str,
    user: User = Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
):
    """Assets containing OCR'd text matching q, with the matching word boxes."""
    q = q.strip()
    if len(q) < 2:
        return []
    rows = (
        await db.execute(
            select(Asset, AssetText)
            .join(AssetText, AssetText.asset_id == Asset.id)
            .where(
                Asset.owner_id == user.id,
                Asset.trashed_at.is_(None),
                Asset.hidden_at.is_(None),
                AssetText.word.ilike(f"%{q}%"),
            )
            .order_by(Asset.taken_at.desc())
            .limit(2000)
        )
    ).all()
    by_asset: dict = {}
    for asset, text in rows:
        entry = by_asset.setdefault(
            asset.id,
            TextSearchResult(asset=AssetThin.model_validate(asset), matches=[]),
        )
        if len(entry.matches) < 50:
            entry.matches.append(TextMatch(word=text.word, x=text.x, y=text.y, w=text.w, h=text.h))
    return list(by_asset.values())[:200]


@router.get("/stats", response_model=StatsOut)
async def stats(
    days: int = 365,
    user: User = Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
):
    base = [Asset.owner_id == user.id, Asset.trashed_at.is_(None), Asset.hidden_at.is_(None)]
    totals = (
        await db.execute(
            select(
                func.count(),
                func.coalesce(func.sum(Asset.file_size), 0),
                func.count().filter(Asset.asset_type == "image"),
                func.count().filter(Asset.asset_type == "video"),
            ).where(*base)
        )
    ).one()
    day = _date_bucket(db, Asset.taken_at, "YYYY-MM-DD", "%Y-%m-%d")
    cutoff = datetime.now(timezone.utc) - timedelta(days=max(1, min(days, 3650)))
    daily_rows = (
        await db.execute(
            select(day.label("d"), func.count(), func.coalesce(func.sum(Asset.file_size), 0))
            .where(*base, Asset.taken_at >= cutoff)
            .group_by(day)
            .order_by(day)
        )
    ).all()
    return StatsOut(
        total_count=totals[0],
        total_bytes=totals[1],
        image_count=totals[2],
        video_count=totals[3],
        daily=[DailyStat(date=r[0], count=r[1], bytes=r[2]) for r in daily_rows],
    )


@router.get("/trash", response_model=list[AssetThin])
async def list_trash(
    user: User = Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
):
    assets = await db.scalars(
        select(Asset)
        .where(Asset.owner_id == user.id, Asset.trashed_at.is_not(None))
        .order_by(Asset.trashed_at.desc())
    )
    return assets.all()


@router.post("/trash/restore", status_code=204)
async def restore_from_trash(
    body: AssetIds,
    user: User = Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
):
    await db.execute(
        update(Asset)
        .where(Asset.owner_id == user.id, Asset.id.in_(body.asset_ids), demo.mutable())
        .values(trashed_at=None)
    )
    await db.commit()


@router.post("/trash/empty", status_code=204)
async def empty_trash(
    user: User = Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
):
    trashed = (
        await db.scalars(
            select(Asset).where(Asset.owner_id == user.id, Asset.trashed_at.is_not(None))
        )
    ).all()
    for asset in trashed:
        storage.delete_asset_files(asset.owner_id, asset.id, asset.file_path, asset.live_video_path)
    await db.execute(
        delete(Asset).where(Asset.owner_id == user.id, Asset.trashed_at.is_not(None))
    )
    await db.commit()
