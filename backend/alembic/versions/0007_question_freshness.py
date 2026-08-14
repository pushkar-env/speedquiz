"""Freshness lifecycle for the question bank.

Every existing row is treated as permanent: ``expires_at`` lands NULL and
``volatility`` lands 'static', so the retirement sweep introduced alongside this
migration has nothing to act on until the pipeline starts labelling new
questions. Deploy order therefore does not matter — the columns can sit unused
for as long as it takes.

The new index is partial. Only questions that can expire are in it, which keeps
it small enough to stay cached even once the bank is large, and leaves the
write path for permanent questions untouched.
"""

from typing import Sequence, Union

import sqlalchemy as sa
from alembic import op

revision: str = "0007_question_freshness"
down_revision: Union[str, None] = "0006_multiplayer"
branch_labels: Union[str, Sequence[str], None] = None
depends_on: Union[str, Sequence[str], None] = None


def upgrade() -> None:
    op.add_column(
        "questions",
        sa.Column("valid_as_of", sa.DateTime(timezone=True), nullable=True),
    )
    op.add_column(
        "questions",
        sa.Column("expires_at", sa.DateTime(timezone=True), nullable=True),
    )
    op.add_column(
        "questions",
        sa.Column(
            "volatility",
            sa.String(16),
            nullable=False,
            server_default=sa.text("'static'"),
        ),
    )
    op.create_index(
        "ix_questions_expiring",
        "questions",
        ["expires_at"],
        postgresql_where=sa.text("expires_at IS NOT NULL"),
    )


def downgrade() -> None:
    op.drop_index("ix_questions_expiring", table_name="questions")
    op.drop_column("questions", "volatility")
    op.drop_column("questions", "expires_at")
    op.drop_column("questions", "valid_as_of")
