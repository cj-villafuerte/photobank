"""live photo companion video

Revision ID: 0002
Revises: 0001
Create Date: 2026-09-03

"""
from alembic import op
import sqlalchemy as sa

revision = "0002"
down_revision = "0001"
branch_labels = None
depends_on = None


def upgrade() -> None:
    op.add_column("assets", sa.Column("live_video_path", sa.Text(), nullable=True))


def downgrade() -> None:
    op.drop_column("assets", "live_video_path")
