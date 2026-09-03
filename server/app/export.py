"""Portable JSON export/import of the whole database (users, assets, albums,
OCR text, settings). Database-agnostic: written from SQLite or Postgres,
importable into either - the "move to a new computer" format.

The media files are NOT in the JSON; asset rows reference them by path
relative to STORAGE_ROOT, so restore the library/ folder alongside."""

import json
import uuid
from datetime import datetime
from pathlib import Path

from sqlalchemy import Uuid, create_engine, insert, select, text
from sqlalchemy.dialects.postgresql import insert as pg_insert
from sqlalchemy.dialects.sqlite import insert as sqlite_insert

from .config import settings
from .models import Album, AlbumAsset, AppSetting, Asset, AssetText, Base, TZDateTime, User

FORMAT_VERSION = 1
TABLES = [User, Asset, Album, AlbumAsset, AssetText, AppSetting]  # FK order


def _to_json_value(v):
    if isinstance(v, uuid.UUID):
        return str(v)
    if isinstance(v, datetime):
        return v.isoformat()
    return v


def export_json(dest: Path) -> dict:
    """Writes the export file; returns per-table row counts."""
    engine = create_engine(settings.database_url_sync)
    counts: dict[str, int] = {}
    payload = {
        "format": "photobank-export",
        "version": FORMAT_VERSION,
        "exported_at": datetime.now().astimezone().isoformat(),
        "tables": {},
    }
    with engine.connect() as conn:
        for model in TABLES:
            table = model.__table__
            rows = [
                {k: _to_json_value(v) for k, v in r._mapping.items()}
                for r in conn.execute(select(table))
            ]
            payload["tables"][table.name] = rows
            counts[table.name] = len(rows)
    tmp = dest.with_name(dest.name + ".part")
    tmp.write_text(json.dumps(payload, ensure_ascii=False), encoding="utf-8")
    tmp.replace(dest)
    return counts


def _from_json_row(table, row: dict) -> dict:
    out = {}
    for col in table.columns:
        if col.name not in row:
            continue
        v = row[col.name]
        if v is not None:
            if isinstance(col.type, Uuid):
                v = uuid.UUID(v)
            elif isinstance(col.type, TZDateTime):
                v = datetime.fromisoformat(v)
        out[col.name] = v
    return out


def import_json(src: Path, replace: bool = False) -> dict:
    """Loads an export into the configured database.

    replace=False merges (rows whose primary key already exists are skipped);
    replace=True wipes every table first and restores an exact copy.
    """
    payload = json.loads(src.read_text(encoding="utf-8-sig"))
    if payload.get("format") != "photobank-export":
        raise ValueError("Not a Photobank export file")
    if int(payload.get("version", 0)) > FORMAT_VERSION:
        raise ValueError("Export was made by a newer Photobank; please update")

    engine = create_engine(settings.database_url_sync)
    dialect = engine.dialect.name
    if dialect == "sqlite":
        with engine.connect() as c:
            c.execute(text("PRAGMA foreign_keys=ON"))
    Base.metadata.create_all(engine)

    counts: dict[str, int] = {}
    with engine.begin() as conn:
        if replace:
            for model in reversed(TABLES):
                conn.execute(text(f"DELETE FROM {model.__tablename__}"))
        for model in TABLES:
            table = model.__table__
            rows = [_from_json_row(table, r) for r in payload["tables"].get(table.name, [])]
            written = 0
            for i in range(0, len(rows), 500):
                chunk = rows[i : i + 500]
                if not chunk:
                    continue
                if replace:
                    conn.execute(insert(table), chunk)
                    written += len(chunk)
                else:
                    stmt = (pg_insert if dialect == "postgresql" else sqlite_insert)(table)
                    res = conn.execute(stmt.values(chunk).on_conflict_do_nothing())
                    written += res.rowcount if res.rowcount >= 0 else 0
            counts[table.name] = written
        if dialect == "postgresql":
            conn.execute(text(
                "SELECT setval(pg_get_serial_sequence('asset_texts','id'), "
                "COALESCE((SELECT MAX(id) FROM asset_texts), 0) + 1, false)"
            ))
    return counts
