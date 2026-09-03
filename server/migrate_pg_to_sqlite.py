"""Copy all Photobank data from Postgres into a fresh SQLite file.

Usage:  python migrate_pg_to_sqlite.py C:\\path\\to\\photobank.db
Reads the Postgres URL from .env (DATABASE_URL_SYNC). Safe to re-run: it
refuses to write into a non-empty target.
"""

import sys
from pathlib import Path

from sqlalchemy import create_engine, insert, select, text

from app.config import settings
from app.models import Album, AlbumAsset, Asset, AssetText, Base, User

TABLES = [User, Asset, Album, AlbumAsset, AssetText]  # FK dependency order


def main() -> None:
    if len(sys.argv) != 2:
        sys.exit("usage: migrate_pg_to_sqlite.py <target.db>")
    target = Path(sys.argv[1])
    target.parent.mkdir(parents=True, exist_ok=True)

    src = create_engine(settings.database_url_sync)
    dst = create_engine(f"sqlite:///{target}")
    with dst.connect() as c:
        c.execute(text("PRAGMA foreign_keys=ON"))
    Base.metadata.create_all(dst)

    with src.connect() as s, dst.begin() as d:
        existing = d.execute(select(User.id).limit(1)).first()
        if existing:
            sys.exit(f"target {target} already has data - aborting")
        for model in TABLES:
            table = model.__table__
            rows = [dict(r._mapping) for r in s.execute(select(table))]
            if rows:
                for i in range(0, len(rows), 500):
                    d.execute(insert(table), rows[i : i + 500])
            print(f"{table.name}: {len(rows)} rows")

    print(f"\nDone. Point .env at it:\n"
          f"DATABASE_URL=sqlite+aiosqlite:///{target}\n"
          f"DATABASE_URL_SYNC=sqlite:///{target}")


if __name__ == "__main__":
    main()
