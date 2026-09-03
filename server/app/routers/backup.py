import asyncio
from datetime import datetime

from fastapi import APIRouter, Depends, HTTPException, Request, UploadFile
from fastapi.responses import FileResponse
from pydantic import BaseModel

from .. import storage
from ..auth import get_admin_user
from ..export import export_json, import_json
from ..models import User

router = APIRouter(prefix="/api/backup", tags=["backup"])


@router.get("/export")
async def export_database(_: User = Depends(get_admin_user)):
    """Download the whole database as a portable JSON file."""
    storage.ensure_dirs()
    path = storage.tmp_path().with_suffix(".json")
    await asyncio.to_thread(export_json, path)
    name = f"photobank-export-{datetime.now():%Y%m%d-%H%M}.json"
    return FileResponse(path, media_type="application/json", filename=name,
                        background=None)


@router.post("/import")
async def import_database(
    file: UploadFile,
    replace: bool = False,
    _: User = Depends(get_admin_user),
):
    """Restore from a JSON export (merge by default; replace wipes first)."""
    storage.ensure_dirs()
    path = storage.tmp_path().with_suffix(".json")
    try:
        with open(path, "wb") as out:
            while chunk := await file.read(1024 * 1024):
                out.write(chunk)
        counts = await asyncio.to_thread(import_json, path, replace)
    except ValueError as e:
        raise HTTPException(status_code=400, detail=str(e))
    finally:
        path.unlink(missing_ok=True)
    return {"imported": counts, "replace": replace}


class BackupSettingsIn(BaseModel):
    dir: str | None = None
    auto: bool = False
    include_thumbs: bool = False


@router.get("")
async def backup_status(request: Request, _: User = Depends(get_admin_user)):
    return request.app.state.backup.snapshot()


@router.put("/settings")
async def backup_settings(
    body: BackupSettingsIn, request: Request, _: User = Depends(get_admin_user)
):
    try:
        await request.app.state.backup.update_config(body.dir, body.auto, body.include_thumbs)
    except ValueError as e:
        raise HTTPException(status_code=400, detail=str(e))
    return request.app.state.backup.snapshot()


@router.post("/run", status_code=202)
async def backup_run(request: Request, _: User = Depends(get_admin_user)):
    started = await request.app.state.backup.run()
    if not started:
        raise HTTPException(status_code=409, detail="Backup already running or no folder configured")
    return {"started": True}
