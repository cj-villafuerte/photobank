"""Copy Photobank data between databases (SQLite <-> PostgreSQL) in either direction.

  python dbsync.py --from <src> --to <dst> (--replace | --merge)

<src>/<dst> are SQLAlchemy URLs or a path to a .db file. Shortcuts:
  pg        the Postgres URL from .env (DATABASE_URL_SYNC)
  desktop   %LOCALAPPDATA%\\Photobank\\photobank.db (the desktop app's database)

--replace  wipe the target tables, then copy everything (exact mirror)
--merge    insert only rows whose primary key is missing in the target
Without a mode the tool refuses to write into a non-empty target.
"""

import argparse
import os
import sys
from pathlib import Path

from sqlalchemy import create_engine, func, insert, select, text
from sqlalchemy.dialects.postgresql import insert as pg_insert
from sqlalchemy.dialects.sqlite import insert as sqlite_insert

from app.config import settings
from app.models import Album, AlbumAsset, Asset, AssetText, Base, User

TABLES = [User, Asset, Album, AlbumAsset, AssetText]  # FK dependency order


def resolve(spec: str) -> str:
    if spec == "pg":
        return settings.database_url_sync
    if spec == "desktop":
        db = Path(os.environ.get("LOCALAPPDATA", "")) / "Photobank" / "photobank.db"
        return f"sqlite:///{db}"
    if "://" in spec:
        return spec
    return f"sqlite:///{Path(spec).resolve()}"


def main() -> None:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--from", dest="src", required=True)
    ap.add_argument("--to", dest="dst", required=True)
    mode = ap.add_mutually_exclusive_group()
    mode.add_argument("--replace", action="store_true")
    mode.add_argument("--merge", action="store_true")
    args = ap.parse_args()

    src_url, dst_url = resolve(args.src), resolve(args.dst)
    if src_url == dst_url:
        sys.exit("source and target are the same database")
    src = create_engine(src_url)
    dst = create_engine(dst_url)
    dst_dialect = dst.dialect.name
    if dst_dialect == "sqlite":
        with dst.connect() as c:
            c.execute(text("PRAGMA foreign_keys=ON"))
    Base.metadata.create_all(dst)

    with src.connect() as s, dst.begin() as d:
        target_rows = d.execute(select(func.count()).select_from(Asset.__table__)).scalar()
        if target_rows and not (args.replace or args.merge):
            sys.exit(f"target already has {target_rows} assets - pass --replace or --merge")

        if args.replace:
            for model in reversed(TABLES):
                d.execute(text(f"DELETE FROM {model.__tablename__}"))
            print(f"cleared target ({dst_dialect})")

        for model in TABLES:
            table = model.__table__
            rows = [dict(r._mapping) for r in s.execute(select(table))]
            written = 0
            for i in range(0, len(rows), 500):
                chunk = rows[i : i + 500]
                if not chunk:
                    continue
                if args.merge:
                    stmt = (pg_insert if dst_dialect == "postgresql" else sqlite_insert)(table)
                    result = d.execute(stmt.values(chunk).on_conflict_do_nothing())
                    written += result.rowcount if result.rowcount >= 0 else 0
                else:
                    d.execute(insert(table), chunk)
                    written += len(chunk)
            print(f"{table.name}: {len(rows)} source rows, {written} written")

        if dst_dialect == "postgresql":
            # rows carry their ids; move the serial past them
            d.execute(text(
                "SELECT setval(pg_get_serial_sequence('asset_texts','id'), "
                "COALESCE((SELECT MAX(id) FROM asset_texts), 0) + 1, false)"
            ))

    with dst.connect() as d:
        n = d.execute(select(func.count()).select_from(Asset.__table__)).scalar()
    print(f"\ntarget now has {n} assets ({dst_url.split('://')[0]})")


if __name__ == "__main__":
    main()
