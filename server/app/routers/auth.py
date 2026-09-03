from fastapi import APIRouter, Depends, HTTPException, Response
from sqlalchemy import func, select
from sqlalchemy.ext.asyncio import AsyncSession

from fastapi import Request

from ..auth import (
    clear_session_cookie,
    ensure_local_admin,
    get_current_user,
    hash_password,
    is_loopback,
    make_token,
    set_session_cookie,
    verify_password,
)
from ..config import settings
from ..db import get_db
from ..models import User
from ..schemas import LoginIn, PasswordChange, RegisterIn, UserOut

router = APIRouter(prefix="/api/auth", tags=["auth"])


@router.post("/register", response_model=UserOut, status_code=201)
async def register(body: RegisterIn, response: Response, db: AsyncSession = Depends(get_db)):
    user_count = await db.scalar(select(func.count(User.id)))
    if user_count > 0 and not settings.allow_registration:
        raise HTTPException(status_code=403, detail="Registration is disabled")
    email = body.email.lower()
    existing = await db.scalar(select(User).where(User.email == email))
    if existing:
        raise HTTPException(status_code=409, detail="Email already registered")
    user = User(
        email=email,
        display_name=body.display_name,
        password_hash=hash_password(body.password),
        is_admin=(user_count == 0),  # first user bootstraps as admin
    )
    db.add(user)
    await db.commit()
    await db.refresh(user)
    set_session_cookie(response, user.id)
    return user


@router.post("/login", response_model=UserOut)
async def login(body: LoginIn, response: Response, db: AsyncSession = Depends(get_db)):
    user = await db.scalar(select(User).where(User.email == body.email.lower()))
    if user is None or not verify_password(user.password_hash, body.password):
        raise HTTPException(status_code=401, detail="Invalid email or password")
    if not user.is_active:
        raise HTTPException(status_code=403, detail="Account is disabled")
    set_session_cookie(response, user.id)
    return user


@router.post("/local", response_model=UserOut)
async def local_admin_login(request: Request, response: Response, db: AsyncSession = Depends(get_db)):
    """Desktop app window -> passwordless administrator. Requires the secret the
    desktop app generated AND a loopback client; unavailable on plain servers."""
    token = settings.local_admin_token
    if not token or request.headers.get("x-local-admin") != token or not is_loopback(request):
        raise HTTPException(status_code=404, detail="Not available")
    user = await ensure_local_admin(db)
    set_session_cookie(response, user.id)
    return user


@router.post("/token")
async def issue_token(body: LoginIn, db: AsyncSession = Depends(get_db)):
    """Long-lived bearer token for the mobile app (survives cookie expiry)."""
    user = await db.scalar(select(User).where(User.email == body.email.lower()))
    if user is None or not verify_password(user.password_hash, body.password):
        raise HTTPException(status_code=401, detail="Invalid email or password")
    if not user.is_active:
        raise HTTPException(status_code=403, detail="Account is disabled")
    return {"token": make_token(user.id, days=365), "user_id": str(user.id)}


@router.post("/logout", status_code=204)
async def logout(response: Response):
    clear_session_cookie(response)


@router.get("/me", response_model=UserOut)
async def me(user: User = Depends(get_current_user)):
    return user


@router.post("/change-password", status_code=204)
async def change_password(
    body: PasswordChange,
    user: User = Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
):
    if not verify_password(user.password_hash, body.current_password):
        raise HTTPException(status_code=400, detail="Current password is incorrect")
    user.password_hash = hash_password(body.new_password)
    await db.commit()
