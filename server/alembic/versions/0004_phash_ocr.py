"""perceptual hash + OCR text

Revision ID: 0004
Revises: 0003
Create Date: 2026-09-03

"""
from alembic import op
import sqlalchemy as sa
from sqlalchemy.dialects.postgresql import UUID

revision = "0004"
down_revision = "0003"
branch_labels = None
depends_on = None


def upgrade() -> None:
    op.add_column("assets", sa.Column("phash", sa.BigInteger(), nullable=True))
    op.add_column(
        "assets",
        sa.Column("ocr_status", sa.Text(), nullable=False, server_default="pending"),
    )
    op.create_table(
        "asset_texts",
        sa.Column("id", sa.BigInteger(), primary_key=True, autoincrement=True),
        sa.Column("asset_id", UUID(as_uuid=True), sa.ForeignKey("assets.id", ondelete="CASCADE"), nullable=False),
        sa.Column("word", sa.Text(), nullable=False),
        sa.Column("x", sa.Float(), nullable=False),
        sa.Column("y", sa.Float(), nullable=False),
        sa.Column("w", sa.Float(), nullable=False),
        sa.Column("h", sa.Float(), nullable=False),
    )
    op.create_index("ix_asset_texts_asset", "asset_texts", ["asset_id"])


def downgrade() -> None:
    op.drop_table("asset_texts")
    op.drop_column("assets", "ocr_status")
    op.drop_column("assets", "phash")
