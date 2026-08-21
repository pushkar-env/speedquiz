"""Player-authored quizzes: the shell, its ACL, and its report log.

The questions themselves need no new table. A custom quiz owns one hidden row
in ``topics`` and writes ordinary ``questions`` under it, so sessions, the
three game modes, multiplayer boards, scoring and anti-cheat all keep working
against a concept they already have. ``topics.is_user_generated`` is the flag
that tells gameplay to treat that bank as a *finite deck* — deal it once, end
the run at the bottom, and keep it out of the global ladder.

``scores`` gains a (topic_id, final_score) index because every custom quiz now
has its own leaderboard, and that read is "best scores for one topic" — which
on the existing single-column topic index means fetching every score row for
the quiz and sorting them.
"""

from typing import Sequence, Union

import sqlalchemy as sa
from alembic import op
from sqlalchemy.dialects import postgresql

revision: str = "0010_custom_quizzes"
down_revision: Union[str, None] = "0009_news_topics"
branch_labels: Union[str, Sequence[str], None] = None
depends_on: Union[str, Sequence[str], None] = None


visibility_enum = postgresql.ENUM(
    "private",
    "friends",
    "link",
    name="custom_quiz_visibility",
    create_type=False,
)
status_enum = postgresql.ENUM(
    "draft",
    "published",
    "archived",
    "hidden",
    name="custom_quiz_status",
    create_type=False,
)


def upgrade() -> None:
    bind = op.get_bind()
    visibility_enum.create(bind, checkfirst=True)
    status_enum.create(bind, checkfirst=True)

    op.add_column(
        "topics",
        sa.Column(
            "is_user_generated",
            sa.Boolean(),
            nullable=False,
            server_default=sa.false(),
        ),
    )

    op.create_table(
        "custom_quizzes",
        sa.Column("id", postgresql.UUID(as_uuid=True), primary_key=True),
        sa.Column("owner_user_id", postgresql.UUID(as_uuid=True), nullable=False),
        sa.Column("topic_id", postgresql.UUID(as_uuid=True), nullable=False),
        sa.Column("title", sa.String(length=80), nullable=False),
        sa.Column("description", sa.String(length=280), nullable=True),
        sa.Column("icon", sa.String(length=16), nullable=False, server_default="🧠"),
        sa.Column("language", sa.String(length=8), nullable=False, server_default="en"),
        sa.Column("visibility", visibility_enum, nullable=False, server_default="private"),
        sa.Column("status", status_enum, nullable=False, server_default="draft"),
        sa.Column("code", sa.String(length=12), nullable=True),
        sa.Column("question_count", sa.Integer(), nullable=False, server_default="0"),
        sa.Column(
            "default_mode",
            postgresql.ENUM(name="game_mode", create_type=False),
            nullable=False,
            server_default="casual",
        ),
        sa.Column(
            "default_difficulty",
            postgresql.ENUM(name="difficulty_label", create_type=False),
            nullable=False,
            server_default="medium",
        ),
        sa.Column("play_count", sa.Integer(), nullable=False, server_default="0"),
        sa.Column("player_count", sa.Integer(), nullable=False, server_default="0"),
        sa.Column("top_score", sa.Integer(), nullable=False, server_default="0"),
        sa.Column("published_at", sa.DateTime(timezone=True), nullable=True),
        sa.Column("archived_at", sa.DateTime(timezone=True), nullable=True),
        sa.Column("report_count", sa.Integer(), nullable=False, server_default="0"),
        sa.Column("moderation_note", sa.String(length=255), nullable=True),
        sa.Column(
            "created_at",
            sa.DateTime(timezone=True),
            nullable=False,
            server_default=sa.func.now(),
        ),
        sa.Column(
            "updated_at",
            sa.DateTime(timezone=True),
            nullable=False,
            server_default=sa.func.now(),
        ),
        sa.ForeignKeyConstraint(["owner_user_id"], ["users.id"], ondelete="CASCADE"),
        sa.ForeignKeyConstraint(["topic_id"], ["topics.id"], ondelete="CASCADE"),
        sa.UniqueConstraint("topic_id"),
        sa.UniqueConstraint("code"),
        sa.CheckConstraint(
            "question_count >= 0 AND play_count >= 0", name="ck_custom_quiz_counters"
        ),
    )
    op.create_index("ix_custom_quizzes_owner_user_id", "custom_quizzes", ["owner_user_id"])
    op.create_index("ix_custom_quizzes_code", "custom_quizzes", ["code"])
    op.create_index(
        "ix_custom_quizzes_owner_status", "custom_quizzes", ["owner_user_id", "status"]
    )
    op.create_index(
        "ix_custom_quizzes_owner_created", "custom_quizzes", ["owner_user_id", "created_at"]
    )

    op.create_table(
        "custom_quiz_access",
        sa.Column("id", postgresql.UUID(as_uuid=True), primary_key=True),
        sa.Column("quiz_id", postgresql.UUID(as_uuid=True), nullable=False),
        sa.Column("user_id", postgresql.UUID(as_uuid=True), nullable=False),
        sa.Column("source", sa.String(length=16), nullable=False, server_default="code"),
        sa.Column(
            "created_at",
            sa.DateTime(timezone=True),
            nullable=False,
            server_default=sa.func.now(),
        ),
        sa.ForeignKeyConstraint(["quiz_id"], ["custom_quizzes.id"], ondelete="CASCADE"),
        sa.ForeignKeyConstraint(["user_id"], ["users.id"], ondelete="CASCADE"),
        sa.UniqueConstraint("quiz_id", "user_id", name="uq_custom_quiz_access"),
    )
    op.create_index("ix_custom_quiz_access_quiz_id", "custom_quiz_access", ["quiz_id"])
    op.create_index(
        "ix_custom_quiz_access_user_created",
        "custom_quiz_access",
        ["user_id", "created_at"],
    )

    op.create_table(
        "custom_quiz_reports",
        sa.Column("id", postgresql.UUID(as_uuid=True), primary_key=True),
        sa.Column("quiz_id", postgresql.UUID(as_uuid=True), nullable=False),
        sa.Column("user_id", postgresql.UUID(as_uuid=True), nullable=False),
        sa.Column("reason", sa.String(length=32), nullable=False),
        sa.Column("details", sa.Text(), nullable=True),
        sa.Column("status", sa.String(length=16), nullable=False, server_default="open"),
        sa.Column(
            "created_at",
            sa.DateTime(timezone=True),
            nullable=False,
            server_default=sa.func.now(),
        ),
        sa.ForeignKeyConstraint(["quiz_id"], ["custom_quizzes.id"], ondelete="CASCADE"),
        sa.ForeignKeyConstraint(["user_id"], ["users.id"], ondelete="CASCADE"),
        sa.UniqueConstraint("quiz_id", "user_id", name="uq_custom_quiz_report_once"),
    )
    op.create_index("ix_custom_quiz_reports_quiz_id", "custom_quiz_reports", ["quiz_id"])
    op.create_index(
        "ix_custom_quiz_reports_status", "custom_quiz_reports", ["status", "created_at"]
    )

    # Per-quiz leaderboards read "top scores for one topic". Descending on the
    # score leg so the ladder is an index scan rather than a sort of every run
    # the quiz has ever had.
    op.create_index(
        "ix_scores_topic_score",
        "scores",
        ["topic_id", sa.text("final_score DESC")],
    )


def downgrade() -> None:
    op.drop_index("ix_scores_topic_score", table_name="scores")

    op.drop_index("ix_custom_quiz_reports_status", table_name="custom_quiz_reports")
    op.drop_index("ix_custom_quiz_reports_quiz_id", table_name="custom_quiz_reports")
    op.drop_table("custom_quiz_reports")

    op.drop_index("ix_custom_quiz_access_user_created", table_name="custom_quiz_access")
    op.drop_index("ix_custom_quiz_access_quiz_id", table_name="custom_quiz_access")
    op.drop_table("custom_quiz_access")

    op.drop_index("ix_custom_quizzes_owner_created", table_name="custom_quizzes")
    op.drop_index("ix_custom_quizzes_owner_status", table_name="custom_quizzes")
    op.drop_index("ix_custom_quizzes_code", table_name="custom_quizzes")
    op.drop_index("ix_custom_quizzes_owner_user_id", table_name="custom_quizzes")
    op.drop_table("custom_quizzes")

    op.drop_column("topics", "is_user_generated")

    bind = op.get_bind()
    status_enum.drop(bind, checkfirst=True)
    visibility_enum.drop(bind, checkfirst=True)
