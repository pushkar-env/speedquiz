"""Add analytics_events table for Phase 6a light analytics."""

from typing import Sequence, Union

import sqlalchemy as sa
from alembic import op
from sqlalchemy.dialects import postgresql

revision: str = "0003_analytics_events"
down_revision: Union[str, None] = "0002_quiz_question_reuse"
branch_labels: Union[str, Sequence[str], None] = None
depends_on: Union[str, Sequence[str], None] = None


def upgrade() -> None:
    op.create_table(
        "analytics_events",
        sa.Column("id", postgresql.UUID(as_uuid=True), primary_key=True),
        sa.Column("user_id", postgresql.UUID(as_uuid=True), sa.ForeignKey("users.id", ondelete="SET NULL")),
        sa.Column("event", sa.String(128), nullable=False),
        sa.Column(
            "properties",
            postgresql.JSONB(),
            nullable=False,
            server_default=sa.text("'{}'::jsonb"),
        ),
        sa.Column(
            "created_at",
            sa.DateTime(timezone=True),
            server_default=sa.text("now()"),
            nullable=False,
        ),
    )
    op.create_index(
        "ix_analytics_events_event_created",
        "analytics_events",
        ["event", "created_at"],
    )
    op.create_index(
        "ix_analytics_events_user_created",
        "analytics_events",
        ["user_id", "created_at"],
    )


def downgrade() -> None:
    op.drop_index("ix_analytics_events_user_created", table_name="analytics_events")
    op.drop_index("ix_analytics_events_event_created", table_name="analytics_events")
    op.drop_table("analytics_events")
