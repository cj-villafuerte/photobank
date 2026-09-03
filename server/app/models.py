import uuid
from datetime import datetime, timezone

from sqlalchemy import (
    BigInteger,
    Boolean,
    DateTime,
    Double,
    Float,
    ForeignKey,
    Index,
    Integer,
    Text,
    TypeDecorator,
    UniqueConstraint,
    Uuid,
    func,
    text,
)
from sqlalchemy.orm import DeclarativeBase, Mapped, mapped_column, relationship


class TZDateTime(TypeDecorator):
    """Timezone-aware datetimes on both Postgres and SQLite.

    SQLite has no timestamptz: we store naive UTC there and re-attach the UTC
    tzinfo on read, so application code always sees aware datetimes.
    """

    impl = DateTime(timezone=True)
    cache_ok = True

    def process_bind_param(self, value, dialect):
        if value is not None and dialect.name == "sqlite" and value.tzinfo is not None:
            return value.astimezone(timezone.utc).replace(tzinfo=None)
        return value

    def process_result_value(self, value, dialect):
        if value is not None and value.tzinfo is None:
            return value.replace(tzinfo=timezone.utc)
        return value


class Base(DeclarativeBase):
    pass


class User(Base):
    __tablename__ = "users"

    id: Mapped[uuid.UUID] = mapped_column(Uuid(), primary_key=True, default=uuid.uuid4)
    email: Mapped[str] = mapped_column(Text, unique=True, nullable=False)
    display_name: Mapped[str] = mapped_column(Text, nullable=False)
    password_hash: Mapped[str] = mapped_column(Text, nullable=False)
    is_admin: Mapped[bool] = mapped_column(Boolean, nullable=False, default=False)
    is_active: Mapped[bool] = mapped_column(Boolean, nullable=False, default=True)
    created_at: Mapped[datetime] = mapped_column(
        TZDateTime(), nullable=False, server_default=func.now()
    )


class Asset(Base):
    __tablename__ = "assets"
    __table_args__ = (
        UniqueConstraint("owner_id", "checksum", name="uq_assets_owner_checksum"),
        Index("ix_assets_owner_taken_at", "owner_id", "taken_at"),
        Index("ix_assets_owner_trashed_at", "owner_id", "trashed_at"),
        Index("ix_assets_owner_favorite", "owner_id", postgresql_where=text("is_favorite")),
    )

    id: Mapped[uuid.UUID] = mapped_column(Uuid(), primary_key=True, default=uuid.uuid4)
    owner_id: Mapped[uuid.UUID] = mapped_column(
        Uuid(), ForeignKey("users.id", ondelete="CASCADE"), nullable=False
    )
    checksum: Mapped[str] = mapped_column(Text, nullable=False)
    original_filename: Mapped[str] = mapped_column(Text, nullable=False)
    file_path: Mapped[str] = mapped_column(Text, nullable=False)
    file_size: Mapped[int] = mapped_column(BigInteger, nullable=False)
    mime_type: Mapped[str] = mapped_column(Text, nullable=False)
    asset_type: Mapped[str] = mapped_column(Text, nullable=False)  # 'image' | 'video'
    width: Mapped[int | None] = mapped_column(Integer)
    height: Mapped[int | None] = mapped_column(Integer)
    duration_sec: Mapped[float | None] = mapped_column(Float)
    taken_at: Mapped[datetime] = mapped_column(TZDateTime(), nullable=False)
    taken_at_source: Mapped[str] = mapped_column(Text, nullable=False, default="upload")
    gps_lat: Mapped[float | None] = mapped_column(Double)
    gps_lon: Mapped[float | None] = mapped_column(Double)
    camera_make: Mapped[str | None] = mapped_column(Text)
    camera_model: Mapped[str | None] = mapped_column(Text)
    is_favorite: Mapped[bool] = mapped_column(Boolean, nullable=False, default=False)
    trashed_at: Mapped[datetime | None] = mapped_column(TZDateTime())
    hidden_at: Mapped[datetime | None] = mapped_column(TZDateTime())
    thumb_status: Mapped[str] = mapped_column(Text, nullable=False, default="pending")
    phash: Mapped[int | None] = mapped_column(BigInteger)  # dHash for near-duplicate detection
    ocr_status: Mapped[str] = mapped_column(Text, nullable=False, default="pending")
    live_video_path: Mapped[str | None] = mapped_column(Text)  # Live Photo companion video

    @property
    def has_live_video(self) -> bool:
        return self.live_video_path is not None
    created_at: Mapped[datetime] = mapped_column(
        TZDateTime(), nullable=False, server_default=func.now()
    )


class AssetText(Base):
    """One OCR'd word with its position, normalized 0-1 to the preview image."""

    __tablename__ = "asset_texts"
    __table_args__ = (Index("ix_asset_texts_asset", "asset_id"),)

    # SQLite only auto-numbers an exact INTEGER PRIMARY KEY, so BIGINT there would
    # insert NULL ids; keep BIGINT on Postgres, INTEGER on SQLite.
    id: Mapped[int] = mapped_column(
        BigInteger().with_variant(Integer, "sqlite"), primary_key=True, autoincrement=True
    )
    asset_id: Mapped[uuid.UUID] = mapped_column(
        Uuid(), ForeignKey("assets.id", ondelete="CASCADE"), nullable=False
    )
    word: Mapped[str] = mapped_column(Text, nullable=False)
    x: Mapped[float] = mapped_column(Float, nullable=False)
    y: Mapped[float] = mapped_column(Float, nullable=False)
    w: Mapped[float] = mapped_column(Float, nullable=False)
    h: Mapped[float] = mapped_column(Float, nullable=False)


class Album(Base):
    __tablename__ = "albums"
    __table_args__ = (Index("ix_albums_owner", "owner_id"),)

    id: Mapped[uuid.UUID] = mapped_column(Uuid(), primary_key=True, default=uuid.uuid4)
    owner_id: Mapped[uuid.UUID] = mapped_column(
        Uuid(), ForeignKey("users.id", ondelete="CASCADE"), nullable=False
    )
    name: Mapped[str] = mapped_column(Text, nullable=False)
    cover_asset_id: Mapped[uuid.UUID | None] = mapped_column(
        Uuid(), ForeignKey("assets.id", ondelete="SET NULL")
    )
    created_at: Mapped[datetime] = mapped_column(
        TZDateTime(), nullable=False, server_default=func.now()
    )


class AlbumAsset(Base):
    __tablename__ = "album_assets"
    __table_args__ = (Index("ix_album_assets_asset", "asset_id"),)

    album_id: Mapped[uuid.UUID] = mapped_column(
        Uuid(), ForeignKey("albums.id", ondelete="CASCADE"), primary_key=True
    )
    asset_id: Mapped[uuid.UUID] = mapped_column(
        Uuid(), ForeignKey("assets.id", ondelete="CASCADE"), primary_key=True
    )
    added_at: Mapped[datetime] = mapped_column(
        TZDateTime(), nullable=False, server_default=func.now()
    )
