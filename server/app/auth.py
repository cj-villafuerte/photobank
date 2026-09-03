import uuid
from datetime import datetime, timedelta, timezone

import jwt
from argon2 import PasswordHasher
from argon2.exceptions import VerifyMismatchError
from fastapi import Depends, HTTPException, Request, Response
from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession

from .config import settings
from .db import get_db
from .models import User

COOKIE_NAME = "pb_session"
ALGORITHM = "HS256"

_hasher = PasswordHasher()


def hash_password(password: str) -> str:
    return _hasher.hash(password)


def verify_password(password_hash: str, password: str) -> bool:
    if password_hash == UNUSABLE_PASSWORD:
        return False  # local administrator: no password can ever match
    try:
        _hasher.verify(password_hash, password)
        return True
    except (VerifyMismatchError, Exception):
        return False


LOCAL_ADMIN_EMAIL = "admin@photobank.local"
UNUSABLE_PASSWORD = "!"


async def ensure_local_admin(db: AsyncSession) -> User:
    """The host computer's user is the administrator; no password exists for it."""
    user = await db.scalar(select(User).where(User.email == LOCAL_ADMIN_EMAIL))
    if user is None:
        user = User(
            email=LOCAL_ADMIN_EMAIL,
            display_name="Administrator (this computer)",
            password_hash=UNUSABLE_PASSWORD,
            is_admin=True,
        )
        db.add(user)
        await db.commit()
        await db.refresh(user)
    return user


def is_loopback(request: Request) -> bool:
    return request.client is not None and request.client.host in ("127.0.0.1", "::1")


def set_session_cookie(response: Response, user_id: uuid.UUID) -> None:
    expires = datetime.now(timezone.utc) + timedelta(days=settings.session_days)
    token = jwt.encode(
        {"sub": str(user_id), "exp": expires},
        settings.secret_key,
        algorithm=ALGORITHM,
    )
    response.set_cookie(
        COOKIE_NAME,
        token,
        max_age=settings.session_days * 86400,
        httponly=True,
        samesite="lax",
        path="/",
    )


def clear_session_cookie(response: Response) -> None:
    response.delete_cookie(COOKIE_NAME, path="/")


def make_token(user_id: uuid.UUID, days: int) -> str:
    expires = datetime.now(timezone.utc) + timedelta(days=days)
    return jwt.encode({"sub": str(user_id), "exp": expires}, settings.secret_key, algorithm=ALGORITHM)


async def get_current_user(request: Request, db: AsyncSession = Depends(get_db)) -> User:
    # web app sends the session cookie; the mobile app sends the same JWT as a Bearer header
    token = request.cookies.get(COOKIE_NAME)
    if not token:
        auth_header = request.headers.get("authorization", "")
        if auth_header.lower().startswith("bearer "):
            token = auth_header[7:].strip()
    if not token:
        raise HTTPException(status_code=401, detail="Not authenticated")
    try:
        payload = jwt.decode(token, settings.secret_key, algorithms=[ALGORITHM])
        user_id = uuid.UUID(payload["sub"])
    except (jwt.PyJWTError, KeyError, ValueError):
        raise HTTPException(status_code=401, detail="Invalid session")
    user = await db.scalar(select(User).where(User.id == user_id))
    if user is None or not user.is_active:
        raise HTTPException(status_code=401, detail="Invalid session")
    return user


async def get_admin_user(user: User = Depends(get_current_user)) -> User:
    if not user.is_admin:
        raise HTTPException(status_code=403, detail="Admin access required")
    return user
