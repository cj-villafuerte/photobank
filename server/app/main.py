import logging
import sys
from contextlib import asynccontextmanager
from pathlib import Path

from fastapi import Depends, FastAPI
from fastapi.responses import FileResponse
from fastapi.staticfiles import StaticFiles
from pillow_heif import register_heif_opener

from . import demo, discovery, storage
from .backup import BackupManager
from .config import settings
from .db import IS_SQLITE, SessionLocal, engine
from .ingest import ThumbnailWorker
from .models import Base
from .routers import admin, albums, assets, auth, backup

logging.basicConfig(level=logging.INFO)

if getattr(sys, "frozen", False):  # PyInstaller bundle carries the built web app
    WEB_DIST = Path(sys._MEIPASS) / "web_dist"  # type: ignore[attr-defined]
else:
    WEB_DIST = Path(__file__).resolve().parents[2] / "web" / "dist"


@asynccontextmanager
async def lifespan(app: FastAPI):
    register_heif_opener()
    storage.ensure_dirs()
    if IS_SQLITE:
        # SQLite mode bootstraps its schema directly; Alembic stays Postgres-only
        async with engine.begin() as conn:
            await conn.run_sync(Base.metadata.create_all)
    worker = ThumbnailWorker(SessionLocal)
    app.state.thumb_worker = worker
    await worker.start()
    keeper = None
    if demo.enabled():
        settings.allow_registration = False  # the shared demo account is the only account
        keeper = demo.DemoKeeper(SessionLocal, worker)
        await keeper.start()
    backups = BackupManager(SessionLocal)
    await backups.load()
    backups.start()
    app.state.backup = backups
    mdns = None
    if not settings.disable_mdns and not demo.enabled():
        mdns = await discovery.register(settings.port)
    yield
    await discovery.unregister(mdns)
    if keeper is not None:
        await keeper.stop()
    await backups.stop()
    await worker.stop()


app = FastAPI(title="Photobank", lifespan=lifespan)

app.include_router(auth.router)
app.include_router(assets.router)
app.include_router(albums.router)
# not offered on the demo server (403 there)
app.include_router(admin.router, dependencies=[Depends(demo.block_in_demo)])
app.include_router(backup.router, dependencies=[Depends(demo.block_in_demo)])


@app.get("/api/health")
async def health():
    return {"status": "ok", "mdns": discovery.status, "demo": demo.public_info()}


if WEB_DIST.is_dir():
    app.mount("/assets", StaticFiles(directory=WEB_DIST / "assets"), name="static-assets")

    @app.get("/{full_path:path}", include_in_schema=False)
    async def spa(full_path: str):
        # deep links (/albums/xyz) fall through to the SPA entry point
        candidate = WEB_DIST / full_path
        if full_path and candidate.is_file():
            return FileResponse(candidate)
        return FileResponse(WEB_DIST / "index.html")
