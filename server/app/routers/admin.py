import uuid

from fastapi import APIRouter, Depends, HTTPException
from pydantic import BaseModel, Field
from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession

from ..auth import get_admin_user, hash_password
from ..db import get_db
from ..models import AppSetting, User
from ..schemas import AdminUserCreate, AdminUserPatch, UserOut

router = APIRouter(prefix="/api/admin", tags=["admin"])


@router.get("/server")
async def server_info(_: User = Depends(get_admin_user), db: AsyncSession = Depends(get_db)):
    """What an administrator wants to see first: where the server is and what it holds."""
    import platform
    import socket

    from sqlalchemy import func

    from .. import discovery
    from ..config import settings
    from ..models import Asset

    totals = (
        await db.execute(
            select(
                func.count(),
                func.coalesce(func.sum(Asset.file_size), 0),
                func.count().filter(Asset.thumb_status == "pending"),
                func.count().filter(Asset.ocr_status == "pending"),
            ).where(Asset.trashed_at.is_(None))
        )
    ).one()
    users = await db.scalar(select(func.count(User.id)))
    try:
        s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        s.connect(("8.8.8.8", 80))
        lan_ip = s.getsockname()[0]
        s.close()
    except OSError:
        lan_ip = "127.0.0.1"
    return {
        "hostname": socket.gethostname().split(".")[0],
        "platform": f"{platform.system()} {platform.release()}",
        "lan_url": f"http://{lan_ip}:{settings.port}",
        "storage_root": str(settings.storage_root),
        "database": "SQLite" if settings.database_url.startswith("sqlite") else "PostgreSQL",
        "mdns": discovery.status,
        "assets": totals[0],
        "bytes": totals[1],
        "thumbs_pending": totals[2],
        "ocr_pending": totals[3],
        "users": users,
    }


class FlagIn(BaseModel):
    key: str = Field(pattern=r"^[a-z_]{1,40}$")
    value: str = Field(max_length=200)


@router.get("/flags")
async def get_flags(_: User = Depends(get_admin_user), db: AsyncSession = Depends(get_db)):
    """Small key/value store for UI state such as 'setup_done'."""
    rows = (await db.scalars(select(AppSetting).where(AppSetting.key.like("flag_%")))).all()
    return {r.key[5:]: r.value for r in rows}


@router.put("/flags", status_code=204)
async def set_flag(body: FlagIn, _: User = Depends(get_admin_user), db: AsyncSession = Depends(get_db)):
    row = await db.get(AppSetting, f"flag_{body.key}")
    if row is None:
        db.add(AppSetting(key=f"flag_{body.key}", value=body.value))
    else:
        row.value = body.value
    await db.commit()


@router.get("/users", response_model=list[UserOut])
async def list_users(_: User = Depends(get_admin_user), db: AsyncSession = Depends(get_db)):
    users = await db.scalars(select(User).order_by(User.created_at))
    return users.all()


@router.post("/users", response_model=UserOut, status_code=201)
async def create_user(
    body: AdminUserCreate, _: User = Depends(get_admin_user), db: AsyncSession = Depends(get_db)
):
    email = body.email.lower()
    if await db.scalar(select(User).where(User.email == email)):
        raise HTTPException(status_code=409, detail="Email already registered")
    user = User(
        email=email,
        display_name=body.display_name,
        password_hash=hash_password(body.password),
        is_admin=body.is_admin,
    )
    db.add(user)
    await db.commit()
    await db.refresh(user)
    return user


@router.patch("/users/{user_id}", response_model=UserOut)
async def patch_user(
    user_id: uuid.UUID,
    body: AdminUserPatch,
    admin: User = Depends(get_admin_user),
    db: AsyncSession = Depends(get_db),
):
    user = await db.get(User, user_id)
    if user is None:
        raise HTTPException(status_code=404, detail="User not found")
    if user.id == admin.id and body.is_admin is False:
        raise HTTPException(status_code=400, detail="Cannot remove your own admin role")
    if user.id == admin.id and body.is_active is False:
        raise HTTPException(status_code=400, detail="Cannot deactivate yourself")
    if body.is_active is not None:
        user.is_active = body.is_active
    if body.is_admin is not None:
        user.is_admin = body.is_admin
    if body.password:
        user.password_hash = hash_password(body.password)
    await db.commit()
    await db.refresh(user)
    return user
