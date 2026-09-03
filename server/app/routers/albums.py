import uuid

from fastapi import APIRouter, Depends, HTTPException
from sqlalchemy import delete, func, select
from sqlalchemy.dialects.postgresql import insert as pg_insert
from sqlalchemy.ext.asyncio import AsyncSession

from ..auth import get_current_user
from ..db import get_db
from ..models import Album, AlbumAsset, Asset, User
from ..schemas import AlbumCreate, AlbumDetail, AlbumOut, AlbumPatch, AssetIds, AssetThin

router = APIRouter(prefix="/api/albums", tags=["albums"])


async def _get_owned_album(album_id: uuid.UUID, user: User, db: AsyncSession) -> Album:
    album = await db.get(Album, album_id)
    if album is None or album.owner_id != user.id:
        raise HTTPException(status_code=404, detail="Album not found")
    return album


@router.get("", response_model=list[AlbumOut])
async def list_albums(user: User = Depends(get_current_user), db: AsyncSession = Depends(get_db)):
    count_sq = (
        select(AlbumAsset.album_id, func.count().label("cnt"))
        .group_by(AlbumAsset.album_id)
        .subquery()
    )
    rows = (
        await db.execute(
            select(Album, func.coalesce(count_sq.c.cnt, 0))
            .outerjoin(count_sq, count_sq.c.album_id == Album.id)
            .where(Album.owner_id == user.id)
            .order_by(Album.created_at.desc())
        )
    ).all()
    return [
        AlbumOut(
            id=a.id, name=a.name, cover_asset_id=a.cover_asset_id,
            created_at=a.created_at, asset_count=cnt,
        )
        for a, cnt in rows
    ]


@router.post("", response_model=AlbumOut, status_code=201)
async def create_album(
    body: AlbumCreate, user: User = Depends(get_current_user), db: AsyncSession = Depends(get_db)
):
    album = Album(owner_id=user.id, name=body.name)
    db.add(album)
    await db.commit()
    await db.refresh(album)
    return AlbumOut(
        id=album.id, name=album.name, cover_asset_id=None, created_at=album.created_at, asset_count=0
    )


@router.get("/{album_id}", response_model=AlbumDetail)
async def get_album(
    album_id: uuid.UUID, user: User = Depends(get_current_user), db: AsyncSession = Depends(get_db)
):
    album = await _get_owned_album(album_id, user, db)
    assets = (
        await db.scalars(
            select(Asset)
            .join(AlbumAsset, AlbumAsset.asset_id == Asset.id)
            .where(
                AlbumAsset.album_id == album.id,
                Asset.trashed_at.is_(None),
                Asset.hidden_at.is_(None),
            )
            .order_by(Asset.taken_at.desc())
        )
    ).all()
    return AlbumDetail(
        id=album.id,
        name=album.name,
        cover_asset_id=album.cover_asset_id,
        created_at=album.created_at,
        asset_count=len(assets),
        assets=[AssetThin.model_validate(a) for a in assets],
    )


@router.patch("/{album_id}", response_model=AlbumOut)
async def patch_album(
    album_id: uuid.UUID,
    body: AlbumPatch,
    user: User = Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
):
    album = await _get_owned_album(album_id, user, db)
    if body.name is not None:
        album.name = body.name
    if body.cover_asset_id is not None:
        cover = await db.get(Asset, body.cover_asset_id)
        if cover is None or cover.owner_id != user.id:
            raise HTTPException(status_code=404, detail="Cover asset not found")
        album.cover_asset_id = cover.id
    await db.commit()
    count = await db.scalar(
        select(func.count()).select_from(AlbumAsset).where(AlbumAsset.album_id == album.id)
    )
    return AlbumOut(
        id=album.id, name=album.name, cover_asset_id=album.cover_asset_id,
        created_at=album.created_at, asset_count=count,
    )


@router.delete("/{album_id}", status_code=204)
async def delete_album(
    album_id: uuid.UUID, user: User = Depends(get_current_user), db: AsyncSession = Depends(get_db)
):
    album = await _get_owned_album(album_id, user, db)
    await db.delete(album)  # album_assets cascade; assets untouched
    await db.commit()


@router.put("/{album_id}/assets", status_code=204)
async def add_assets(
    album_id: uuid.UUID,
    body: AssetIds,
    user: User = Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
):
    album = await _get_owned_album(album_id, user, db)
    if not body.asset_ids:
        return
    owned = (
        await db.scalars(
            select(Asset.id).where(Asset.owner_id == user.id, Asset.id.in_(body.asset_ids))
        )
    ).all()
    if not owned:
        return
    await db.execute(
        pg_insert(AlbumAsset)
        .values([{"album_id": album.id, "asset_id": aid} for aid in owned])
        .on_conflict_do_nothing()
    )
    if album.cover_asset_id is None:
        album.cover_asset_id = owned[0]
    await db.commit()


@router.delete("/{album_id}/assets", status_code=204)
async def remove_assets(
    album_id: uuid.UUID,
    body: AssetIds,
    user: User = Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
):
    album = await _get_owned_album(album_id, user, db)
    await db.execute(
        delete(AlbumAsset).where(
            AlbumAsset.album_id == album.id, AlbumAsset.asset_id.in_(body.asset_ids)
        )
    )
    if album.cover_asset_id in body.asset_ids:
        album.cover_asset_id = None
    await db.commit()
