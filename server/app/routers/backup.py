from fastapi import APIRouter, Depends, HTTPException, Request
from pydantic import BaseModel

from ..auth import get_admin_user
from ..models import User

router = APIRouter(prefix="/api/backup", tags=["backup"])


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
