import hashlib
import uuid
from datetime import datetime, timezone
from pathlib import Path

from fastapi import APIRouter, Depends, Form, HTTPException, Request, UploadFile
from fastapi.responses import FileResponse, Response
from sqlalchemy import delete, func, select, update
from sqlalchemy.ext.asyncio import AsyncSession

from .. import ingest, storage
from ..auth import get_current_user
from ..config import settings
from ..db import get_db
from ..models import Asset, User
from ..schemas import (
    AssetIds,
    AssetOut,
    AssetPatch,
    AssetThin,
    ChecksumsIn,
    ChecksumsOut,
    ExistsDetail,
    TimelineBucket,
    UploadResult,
)

router = APIRouter(prefix="/api", tags=["assets"])

CACHE_FOREVER = "private, max-age=31536000, immutable"

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

    # stream to temp while hashing
    tmp = storage.tmp_path()
    sha = hashlib.sha256()
    size = 0
    try:
        with open(tmp, "wb") as out:
            while chunk := await file.read(1024 * 1024):
                sha.update(chunk)
                size += len(chunk)
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
    if not body.checksums:
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


@router.post("/assets/{asset_id}/live-video", response_model=AssetOut)
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
    bucket = func.to_char(Asset.taken_at, "YYYY-MM")
    stmt = (
        select(bucket.label("bucket"), func.count().label("count"))
        .where(Asset.owner_id == user.id, Asset.trashed_at.is_(None))
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
            func.to_char(Asset.taken_at, "YYYY-MM") == bucket,
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
    asset.trashed_at = datetime.now(timezone.utc)
    await db.commit()


@router.delete("/assets/{asset_id}/permanent", status_code=204)
async def permanent_delete(
    asset_id: uuid.UUID,
    user: User = Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
):
    asset = await _get_owned_asset(asset_id, user, db)
    storage.delete_asset_files(asset.owner_id, asset.id, asset.file_path, asset.live_video_path)
    await db.delete(asset)
    await db.commit()


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
        .where(Asset.owner_id == user.id, Asset.id.in_(body.asset_ids))
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
