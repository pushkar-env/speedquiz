"""Mistake notebook, and per-attempt pacing configuration.

The notebook is maintained at submission rather than derived on read. Deriving
it means a four-table join across every attempt a student has ever made, on a
screen they open often — and "I have reviewed this one" has nowhere to live in
derived data, which is what turns a notebook from a revision tool into an
ever-growing list nobody opens.

Pacing (casual / timed / practice, and a custom duration) needs no schema of
its own: it lives in `mock_test_attempts.config`, which already exists. What it
does need is `counts_for_rank`, because a practice run reveals the answers as
you go and letting those scores into the percentile would make the ladder
meaningless for everyone taking the paper seriously.
"""

from typing import Sequence, Union

import sqlalchemy as sa
from alembic import op
from sqlalchemy.dialects import postgresql

revision: str = "0012_notebook_and_modes"
down_revision: Union[str, None] = "0011_exam_mode"
branch_labels: Union[str, Sequence[str], None] = None
depends_on: Union[str, Sequence[str], None] = None

notebook_status_enum = postgresql.ENUM(
    "open", "reviewed", "recovered", name="notebook_status", create_type=False
)


def upgrade() -> None:
    bind = op.get_bind()
    notebook_status_enum.create(bind, checkfirst=True)

    # Existing attempts were all full mocks, so they all count.
    op.add_column(
        "mock_test_attempts",
        sa.Column("counts_for_rank", sa.Boolean(), nullable=False, server_default=sa.true()),
    )

    op.create_table(
        "notebook_entries",
        sa.Column("id", postgresql.UUID(as_uuid=True), nullable=False),
        sa.Column("user_id", postgresql.UUID(as_uuid=True), nullable=False),
        sa.Column("question_id", postgresql.UUID(as_uuid=True), nullable=False),
        sa.Column("exam_question_id", postgresql.UUID(as_uuid=True), nullable=True),
        sa.Column("chapter", sa.String(length=120), nullable=False, server_default=""),
        sa.Column("subject", sa.String(length=80), nullable=False, server_default=""),
        sa.Column("status", notebook_status_enum, nullable=False, server_default="open"),
        sa.Column("wrong_count", sa.Integer(), nullable=False, server_default="1"),
        sa.Column("first_wrong_at", sa.DateTime(timezone=True), server_default=sa.func.now(), nullable=False),
        sa.Column("last_wrong_at", sa.DateTime(timezone=True), server_default=sa.func.now(), nullable=False),
        sa.Column("reviewed_at", sa.DateTime(timezone=True), nullable=True),
        sa.Column(
            "last_selected",
            postgresql.JSONB(astext_type=sa.Text()),
            nullable=False,
            server_default=sa.text("'[]'::jsonb"),
        ),
        sa.Column("last_numeric", sa.Float(), nullable=True),
        sa.Column("created_at", sa.DateTime(timezone=True), server_default=sa.func.now(), nullable=False),
        sa.Column("updated_at", sa.DateTime(timezone=True), server_default=sa.func.now(), nullable=False),
        sa.ForeignKeyConstraint(["user_id"], ["users.id"], ondelete="CASCADE"),
        sa.ForeignKeyConstraint(["question_id"], ["questions.id"], ondelete="CASCADE"),
        sa.ForeignKeyConstraint(["exam_question_id"], ["exam_questions.id"], ondelete="SET NULL"),
        sa.PrimaryKeyConstraint("id"),
        sa.UniqueConstraint("user_id", "question_id", name="uq_notebook_user_question"),
    )
    op.create_index("ix_notebook_entries_user_id", "notebook_entries", ["user_id"])
    op.create_index("ix_notebook_entries_question_id", "notebook_entries", ["question_id"])
    op.create_index(
        "ix_notebook_user_status_seen",
        "notebook_entries",
        ["user_id", "status", "last_wrong_at"],
    )
    op.create_index("ix_notebook_user_chapter", "notebook_entries", ["user_id", "chapter"])


def downgrade() -> None:
    op.drop_index("ix_notebook_user_chapter", table_name="notebook_entries")
    op.drop_index("ix_notebook_user_status_seen", table_name="notebook_entries")
    op.drop_index("ix_notebook_entries_question_id", table_name="notebook_entries")
    op.drop_index("ix_notebook_entries_user_id", table_name="notebook_entries")
    op.drop_table("notebook_entries")

    op.drop_column("mock_test_attempts", "counts_for_rank")

    notebook_status_enum.drop(op.get_bind(), checkfirst=True)
