"""initial schema

Revision ID: 0001
Revises:
Create Date: 2026-09-03

"""
from alembic import op
import sqlalchemy as sa
from sqlalchemy.dialects.postgresql import UUID

revision = "0001"
down_revision = None
branch_labels = None
depends_on = None


def upgrade() -> None:
    op.create_table(
        "users",
        sa.Column("id", UUID(as_uuid=True), primary_key=True),
        sa.Column("email", sa.Text(), nullable=False, unique=True),
        sa.Column("display_name", sa.Text(), nullable=False),
        sa.Column("password_hash", sa.Text(), nullable=False),
        sa.Column("is_admin", sa.Boolean(), nullable=False, server_default=sa.false()),
        sa.Column("is_active", sa.Boolean(), nullable=False, server_default=sa.true()),
        sa.Column("created_at", sa.DateTime(timezone=True), nullable=False, server_default=sa.func.now()),
    )

    op.create_table(
        "assets",
        sa.Column("id", UUID(as_uuid=True), primary_key=True),
        sa.Column("owner_id", UUID(as_uuid=True), sa.ForeignKey("users.id", ondelete="CASCADE"), nullable=False),
        sa.Column("checksum", sa.Text(), nullable=False),
        sa.Column("original_filename", sa.Text(), nullable=False),
        sa.Column("file_path", sa.Text(), nullable=False),
        sa.Column("file_size", sa.BigInteger(), nullable=False),
        sa.Column("mime_type", sa.Text(), nullable=False),
        sa.Column("asset_type", sa.Text(), nullable=False),
        sa.Column("width", sa.Integer()),
        sa.Column("height", sa.Integer()),
        sa.Column("duration_sec", sa.Float()),
        sa.Column("taken_at", sa.DateTime(timezone=True), nullable=False),
        sa.Column("taken_at_source", sa.Text(), nullable=False, server_default="upload"),
        sa.Column("gps_lat", sa.Double()),
        sa.Column("gps_lon", sa.Double()),
        sa.Column("camera_make", sa.Text()),
        sa.Column("camera_model", sa.Text()),
        sa.Column("is_favorite", sa.Boolean(), nullable=False, server_default=sa.false()),
        sa.Column("trashed_at", sa.DateTime(timezone=True)),
        sa.Column("thumb_status", sa.Text(), nullable=False, server_default="pending"),
        sa.Column("created_at", sa.DateTime(timezone=True), nullable=False, server_default=sa.func.now()),
        sa.UniqueConstraint("owner_id", "checksum", name="uq_assets_owner_checksum"),
    )
    op.create_index("ix_assets_owner_taken_at", "assets", ["owner_id", "taken_at"])
    op.create_index("ix_assets_owner_trashed_at", "assets", ["owner_id", "trashed_at"])
    op.create_index(
        "ix_assets_owner_favorite", "assets", ["owner_id"],
        postgresql_where=sa.text("is_favorite"),
    )

    op.create_table(
        "albums",
        sa.Column("id", UUID(as_uuid=True), primary_key=True),
        sa.Column("owner_id", UUID(as_uuid=True), sa.ForeignKey("users.id", ondelete="CASCADE"), nullable=False),
        sa.Column("name", sa.Text(), nullable=False),
        sa.Column("cover_asset_id", UUID(as_uuid=True), sa.ForeignKey("assets.id", ondelete="SET NULL")),
        sa.Column("created_at", sa.DateTime(timezone=True), nullable=False, server_default=sa.func.now()),
    )
    op.create_index("ix_albums_owner", "albums", ["owner_id"])

    op.create_table(
        "album_assets",
        sa.Column("album_id", UUID(as_uuid=True), sa.ForeignKey("albums.id", ondelete="CASCADE"), primary_key=True),
        sa.Column("asset_id", UUID(as_uuid=True), sa.ForeignKey("assets.id", ondelete="CASCADE"), primary_key=True),
        sa.Column("added_at", sa.DateTime(timezone=True), nullable=False, server_default=sa.func.now()),
    )
    op.create_index("ix_album_assets_asset", "album_assets", ["asset_id"])


def downgrade() -> None:
    op.drop_table("album_assets")
    op.drop_table("albums")
    op.drop_table("assets")
    op.drop_table("users")
