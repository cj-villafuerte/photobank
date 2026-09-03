"""Redundancy backup: mirror the media library (and a database snapshot) to a
user-chosen folder. Copies only new/changed files; never deletes at the target."""

import asyncio
import json
import logging
import os
import shutil
import sqlite3
import time
from datetime import datetime, timezone
from pathlib import Path

from sqlalchemy import select

from .config import settings
from .models import AppSetting

log = logging.getLogger("photobank.backup")

SETTINGS_KEY = "backup"
STATUS_KEY = "backup_status"
DAILY = 24 * 3600


class BackupManager:
    def __init__(self, sessionmaker):
        self.sessionmaker = sessionmaker
        self.config: dict = {"dir": None, "auto": False, "include_thumbs": False}
        self.status: dict = {"running": False, "last_run": None, "last_result": None}
        self.progress: dict = {}
        self._task: asyncio.Task | None = None
        self._scheduler: asyncio.Task | None = None

    # ---- persistence -------------------------------------------------------
    async def load(self) -> None:
        async with self.sessionmaker() as db:
            for key, target in ((SETTINGS_KEY, self.config), (STATUS_KEY, self.status)):
                row = await db.get(AppSetting, key)
                if row:
                    try:
                        target.update(json.loads(row.value))
                    except json.JSONDecodeError:
                        pass

    async def _save(self, key: str, data: dict) -> None:
        async with self.sessionmaker() as db:
            row = await db.get(AppSetting, key)
            if row is None:
                db.add(AppSetting(key=key, value=json.dumps(data)))
            else:
                row.value = json.dumps(data)
            await db.commit()

    async def update_config(self, directory: str | None, auto: bool, include_thumbs: bool) -> None:
        if directory:
            d = Path(directory)
            if not d.is_absolute():
                raise ValueError("Backup folder must be an absolute path")
            try:
                d.mkdir(parents=True, exist_ok=True)
                probe = d / ".photobank-write-test"
                probe.write_text("ok")
                probe.unlink()
            except OSError as e:
                raise ValueError(f"Backup folder is not writable: {e}")
            root = settings.storage_root.resolve()
            if d.resolve() == root or root in d.resolve().parents:
                raise ValueError("Backup folder must be outside the photo library")
            directory = str(d.resolve())
        self.config = {"dir": directory, "auto": bool(auto), "include_thumbs": bool(include_thumbs)}
        await self._save(SETTINGS_KEY, self.config)
        self._reschedule()

    # ---- scheduling ----------------------------------------------------------
    def start(self) -> None:
        self._reschedule()

    def _reschedule(self) -> None:
        if self._scheduler:
            self._scheduler.cancel()
            self._scheduler = None
        if self.config.get("auto") and self.config.get("dir"):
            self._scheduler = asyncio.create_task(self._daily_loop())

    async def _daily_loop(self) -> None:
        while True:
            last = self.status.get("last_run")
            due_in = DAILY
            if last:
                try:
                    elapsed = time.time() - datetime.fromisoformat(last).timestamp()
                    due_in = max(60, DAILY - elapsed)
                except ValueError:
                    pass
            await asyncio.sleep(due_in)
            await self.run()

    async def stop(self) -> None:
        for t in (self._scheduler, self._task):
            if t:
                t.cancel()

    # ---- running -------------------------------------------------------------
    async def run(self) -> bool:
        """Starts a backup if one is not already running. Returns False if busy/unconfigured."""
        if self.status.get("running") or not self.config.get("dir"):
            return False
        self._task = asyncio.create_task(self._run_task())
        return True

    async def _run_task(self) -> None:
        dest = Path(self.config["dir"])
        self.status["running"] = True
        self.progress = {"phase": "scanning", "scanned": 0, "copied": 0, "bytes": 0, "errors": 0, "started": _now()}
        try:
            result = await asyncio.to_thread(self._mirror, dest)
            self.status["last_result"] = result
        except Exception as e:  # pragma: no cover - defensive
            log.exception("backup failed")
            self.status["last_result"] = {"ok": False, "error": str(e)}
        finally:
            self.status["running"] = False
            self.status["last_run"] = _now()
            self.progress["phase"] = "done"
            await self._save(STATUS_KEY, self.status)

    def _mirror(self, dest: Path) -> dict:
        subdirs = ["library"] + (["thumbs"] if self.config.get("include_thumbs") else [])
        copied = scanned = errors = 0
        total_bytes = 0
        for sub in subdirs:
            src_root = settings.storage_root / sub
            if not src_root.is_dir():
                continue
            self.progress["phase"] = f"copying {sub}"
            for dirpath, _dirs, files in os.walk(src_root):
                for name in files:
                    src = Path(dirpath) / name
                    rel = src.relative_to(settings.storage_root)
                    dst = dest / rel
                    scanned += 1
                    self.progress["scanned"] = scanned
                    try:
                        st = src.stat()
                        if dst.exists():
                            ds = dst.stat()
                            if ds.st_size == st.st_size and ds.st_mtime >= st.st_mtime - 1:
                                continue
                        dst.parent.mkdir(parents=True, exist_ok=True)
                        tmp = dst.with_name(dst.name + ".part")
                        shutil.copy2(src, tmp)
                        os.replace(tmp, dst)
                        copied += 1
                        total_bytes += st.st_size
                        self.progress["copied"] = copied
                        self.progress["bytes"] = total_bytes
                    except OSError:
                        errors += 1
                        self.progress["errors"] = errors
                        log.warning("backup copy failed: %s", src)

        db_note = self._snapshot_database(dest)
        return {
            "ok": errors == 0,
            "scanned": scanned,
            "copied": copied,
            "bytes": total_bytes,
            "errors": errors,
            "database": db_note,
            "finished": _now(),
        }

    def _snapshot_database(self, dest: Path) -> str:
        url = settings.database_url_sync
        if not url.startswith("sqlite"):
            return "postgres - use scripts\\export-to-postgres.ps1 / pg_dump"
        src_path = url.split("sqlite:///", 1)[1]
        target = dest / "photobank-db-snapshot.db"
        self.progress["phase"] = "database snapshot"
        try:
            src = sqlite3.connect(src_path)
            dst = sqlite3.connect(str(target))
            with dst:
                src.backup(dst)  # consistent even while the app is writing
            src.close()
            dst.close()
            return f"snapshot written ({target.name})"
        except sqlite3.Error as e:
            return f"snapshot failed: {e}"

    def snapshot(self) -> dict:
        return {"config": self.config, "status": self.status, "progress": self.progress}


def _now() -> str:
    return datetime.now(timezone.utc).isoformat()
