import uuid
from datetime import datetime
from pathlib import Path

from .config import settings


def ensure_dirs() -> None:
    for d in (settings.library_dir, settings.thumbs_dir, settings.tmp_dir):
        d.mkdir(parents=True, exist_ok=True)


def library_path(owner_id: uuid.UUID, asset_id: uuid.UUID, taken_at: datetime, ext: str) -> Path:
    """Final resting place of an original, relative dir created on demand."""
    d = settings.library_dir / str(owner_id) / f"{taken_at.year:04d}" / f"{taken_at.month:02d}"
    d.mkdir(parents=True, exist_ok=True)
    return d / f"{asset_id}{ext}"


def thumb_dir(owner_id: uuid.UUID, asset_id: uuid.UUID) -> Path:
    d = settings.thumbs_dir / str(owner_id) / str(asset_id)
    d.mkdir(parents=True, exist_ok=True)
    return d


def relative_to_root(path: Path) -> str:
    return str(path.relative_to(settings.storage_root))


def absolute_from_root(rel: str) -> Path:
    return settings.storage_root / rel


def tmp_path() -> Path:
    return settings.tmp_dir / f"upload-{uuid.uuid4().hex}"


def delete_asset_files(
    owner_id: uuid.UUID, asset_id: uuid.UUID, file_path: str, live_video_path: str | None = None
) -> None:
    """Remove original + live video + thumbnail directory; missing files are not an error."""
    for rel in (file_path, live_video_path):
        if rel is None:
            continue
        try:
            absolute_from_root(rel).unlink(missing_ok=True)
        except OSError:
            pass
    tdir = settings.thumbs_dir / str(owner_id) / str(asset_id)
    if tdir.is_dir():
        for f in tdir.iterdir():
            try:
                f.unlink()
            except OSError:
                pass
        try:
            tdir.rmdir()
        except OSError:
            pass
