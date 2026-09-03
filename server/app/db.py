from collections.abc import AsyncGenerator

from sqlalchemy import event
from sqlalchemy.ext.asyncio import AsyncSession, async_sessionmaker, create_async_engine

from .config import settings

IS_SQLITE = settings.database_url.startswith("sqlite")

if IS_SQLITE:
    engine = create_async_engine(settings.database_url)

    @event.listens_for(engine.sync_engine, "connect")
    def _sqlite_pragmas(dbapi_conn, _record):
        cur = dbapi_conn.cursor()
        cur.execute("PRAGMA foreign_keys=ON")  # OFF by default in SQLite!
        cur.execute("PRAGMA journal_mode=WAL")
        cur.execute("PRAGMA synchronous=NORMAL")
        cur.close()
else:
    engine = create_async_engine(settings.database_url, pool_size=10, max_overflow=5)

SessionLocal = async_sessionmaker(engine, expire_on_commit=False)


async def get_db() -> AsyncGenerator[AsyncSession, None]:
    async with SessionLocal() as session:
        yield session
