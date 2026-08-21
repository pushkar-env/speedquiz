"""Exam mode: past-year papers, figures, and timed mock-test attempts.

Three things land here.

**A content layer on top of the bank.** ``exams`` / ``exam_papers`` /
``exam_sections`` / ``exam_questions`` describe a real paper that was sat, but
the question text still lives in ``questions``. Each paper owns one hidden
``topics`` row, exactly as a ``custom_quizzes`` row does, so practice mode, the
three game modes, multiplayer boards and anti-cheat keep working against a
concept they already have.

**Three new columns on ``questions``, and one nullability change.** The bank
was single-answer-MCQ only: ``correct_option_index`` was NOT NULL and options
were four rows of text. That cannot express a JEE numerical (14 of 75 questions
on the paper this was built against), a GATE NAT, or a GATE MSQ. ``answer_type``
defaults to ``single`` at the server, so every pre-existing row is already
correct and no backfill runs.

**Attempts, which genuinely could not reuse ``quiz_sessions``.** A three-hour
paper needs free navigation, mark-for-review, changing an answer, one shared
clock and submit-at-end. ``uq_answer_once`` makes changing an answer a
constraint violation and ``current_question_index`` only moves forward, so
widening that table would have meant unpicking the rules that make the fast
modes work. Mock tests get their own pair of tables; practice quizzes keep the
existing engine untouched.
"""

from typing import Sequence, Union

import sqlalchemy as sa
from alembic import op
from sqlalchemy.dialects import postgresql

revision: str = "0011_exam_mode"
down_revision: Union[str, None] = "0010_custom_quizzes"
branch_labels: Union[str, Sequence[str], None] = None
depends_on: Union[str, Sequence[str], None] = None


answer_type_enum = postgresql.ENUM(
    "single", "multi", "numeric", name="answer_type", create_type=False
)
solution_status_enum = postgresql.ENUM(
    "verified", "needs_review", "withheld", name="solution_status", create_type=False
)
paper_status_enum = postgresql.ENUM(
    "draft", "in_review", "published", "archived",
    name="exam_paper_status", create_type=False,
)
attempt_mode_enum = postgresql.ENUM(
    "full", "sectional", "practice", name="attempt_mode", create_type=False
)
attempt_status_enum = postgresql.ENUM(
    "in_progress", "submitted", "auto_submitted", "abandoned",
    name="attempt_status", create_type=False,
)
response_state_enum = postgresql.ENUM(
    "not_visited", "not_answered", "answered", "marked", "answered_and_marked",
    name="response_state", create_type=False,
)

ALL_ENUMS = (
    answer_type_enum,
    solution_status_enum,
    paper_status_enum,
    attempt_mode_enum,
    attempt_status_enum,
    response_state_enum,
)


def upgrade() -> None:
    bind = op.get_bind()
    for enum_type in ALL_ENUMS:
        enum_type.create(bind, checkfirst=True)

    # ------------------------------------------------------------------
    # questions: new answer types, structured content, solution trust
    # ------------------------------------------------------------------
    op.add_column(
        "questions",
        sa.Column(
            "answer_type", answer_type_enum, nullable=False, server_default="single"
        ),
    )
    op.add_column(
        "questions",
        sa.Column(
            "answer_spec",
            postgresql.JSONB(astext_type=sa.Text()),
            nullable=False,
            server_default=sa.text("'{}'::jsonb"),
        ),
    )
    op.add_column(
        "questions",
        sa.Column(
            "content",
            postgresql.JSONB(astext_type=sa.Text()),
            nullable=False,
            server_default=sa.text("'{}'::jsonb"),
        ),
    )
    op.add_column(
        "questions",
        sa.Column(
            "option_content",
            postgresql.JSONB(astext_type=sa.Text()),
            nullable=False,
            server_default=sa.text("'[]'::jsonb"),
        ),
    )
    op.add_column(
        "questions",
        sa.Column(
            "solution_status",
            solution_status_enum,
            nullable=False,
            server_default="verified",
        ),
    )
    # A numeric question has no option index. Widening to NULL cannot fail and
    # cannot lose data; the reverse direction is the one that needs care.
    op.alter_column("questions", "correct_option_index", existing_type=sa.Integer(), nullable=True)

    # The dealer's covering index has to know about answer_type, or a Survival
    # round will happily deal a numeric-entry question it cannot render.
    op.create_index(
        "ix_questions_topic_lang_status_type",
        "questions",
        ["topic_id", "language", "status", "answer_type", "difficulty"],
    )

    # ------------------------------------------------------------------
    # assets
    # ------------------------------------------------------------------
    op.create_table(
        "question_assets",
        sa.Column("id", postgresql.UUID(as_uuid=True), nullable=False),
        sa.Column("checksum", sa.String(length=64), nullable=False),
        sa.Column("kind", sa.String(length=16), nullable=False, server_default="raster"),
        sa.Column("width", sa.Integer(), nullable=False, server_default="0"),
        sa.Column("height", sa.Integer(), nullable=False, server_default="0"),
        sa.Column("alt_text", sa.Text(), nullable=True),
        sa.Column(
            "variants",
            postgresql.JSONB(astext_type=sa.Text()),
            nullable=False,
            server_default=sa.text("'{}'::jsonb"),
        ),
        sa.Column("total_bytes", sa.Integer(), nullable=False, server_default="0"),
        sa.Column("created_at", sa.DateTime(timezone=True), server_default=sa.func.now(), nullable=False),
        sa.Column("updated_at", sa.DateTime(timezone=True), server_default=sa.func.now(), nullable=False),
        sa.PrimaryKeyConstraint("id"),
        sa.UniqueConstraint("checksum"),
    )
    op.create_index("ix_question_assets_checksum", "question_assets", ["checksum"])

    op.create_table(
        "question_asset_links",
        sa.Column("id", postgresql.UUID(as_uuid=True), nullable=False),
        sa.Column("question_id", postgresql.UUID(as_uuid=True), nullable=False),
        sa.Column("asset_id", postgresql.UUID(as_uuid=True), nullable=False),
        sa.Column("ref", sa.String(length=16), nullable=False),
        sa.Column("role", sa.String(length=24), nullable=False, server_default="figure"),
        sa.Column("position", sa.Integer(), nullable=False, server_default="0"),
        sa.ForeignKeyConstraint(["question_id"], ["questions.id"], ondelete="CASCADE"),
        sa.ForeignKeyConstraint(["asset_id"], ["question_assets.id"], ondelete="CASCADE"),
        sa.PrimaryKeyConstraint("id"),
        sa.UniqueConstraint("question_id", "ref", name="uq_question_asset_ref"),
    )
    op.create_index("ix_question_asset_links_question_id", "question_asset_links", ["question_id"])
    op.create_index("ix_question_asset_links_asset_id", "question_asset_links", ["asset_id"])

    # ------------------------------------------------------------------
    # exams / papers / sections / questions
    # ------------------------------------------------------------------
    op.create_table(
        "exams",
        sa.Column("id", postgresql.UUID(as_uuid=True), nullable=False),
        sa.Column("slug", sa.String(length=64), nullable=False),
        sa.Column("name", sa.String(length=120), nullable=False),
        sa.Column("authority", sa.String(length=120), nullable=True),
        sa.Column("description", sa.Text(), nullable=True),
        sa.Column("icon", sa.String(length=64), nullable=False, server_default="exam"),
        sa.Column(
            "default_marking",
            postgresql.JSONB(astext_type=sa.Text()),
            nullable=False,
            server_default=sa.text("'{}'::jsonb"),
        ),
        sa.Column("sort_order", sa.Integer(), nullable=False, server_default="0"),
        sa.Column("is_active", sa.Boolean(), nullable=False, server_default=sa.true()),
        sa.Column(
            "name_i18n",
            postgresql.JSONB(astext_type=sa.Text()),
            nullable=False,
            server_default=sa.text("'{}'::jsonb"),
        ),
        sa.Column("created_at", sa.DateTime(timezone=True), server_default=sa.func.now(), nullable=False),
        sa.Column("updated_at", sa.DateTime(timezone=True), server_default=sa.func.now(), nullable=False),
        sa.PrimaryKeyConstraint("id"),
        sa.UniqueConstraint("slug"),
    )
    op.create_index("ix_exams_slug", "exams", ["slug"])

    op.create_table(
        "exam_papers",
        sa.Column("id", postgresql.UUID(as_uuid=True), nullable=False),
        sa.Column("exam_id", postgresql.UUID(as_uuid=True), nullable=False),
        sa.Column("key", sa.String(length=120), nullable=False),
        sa.Column("year", sa.Integer(), nullable=False),
        sa.Column("session", sa.String(length=32), nullable=False, server_default=""),
        sa.Column("shift", sa.Integer(), nullable=False, server_default="0"),
        sa.Column("paper_code", sa.String(length=32), nullable=False, server_default=""),
        sa.Column("held_on", sa.Date(), nullable=True),
        sa.Column("title", sa.String(length=160), nullable=False),
        sa.Column("duration_minutes", sa.Integer(), nullable=False, server_default="180"),
        sa.Column("total_marks", sa.Float(), nullable=False, server_default="0"),
        sa.Column("question_count", sa.Integer(), nullable=False, server_default="0"),
        sa.Column("language", sa.String(length=16), nullable=False, server_default="en"),
        sa.Column("topic_id", postgresql.UUID(as_uuid=True), nullable=True),
        sa.Column("status", paper_status_enum, nullable=False, server_default="draft"),
        sa.Column("is_free", sa.Boolean(), nullable=False, server_default=sa.false()),
        sa.Column("source_pdf", sa.String(length=255), nullable=True),
        sa.Column("source_sha256", sa.String(length=64), nullable=True),
        sa.Column(
            "ingest_meta",
            postgresql.JSONB(astext_type=sa.Text()),
            nullable=False,
            server_default=sa.text("'{}'::jsonb"),
        ),
        sa.Column("attempt_count", sa.Integer(), nullable=False, server_default="0"),
        sa.Column("published_at", sa.DateTime(timezone=True), nullable=True),
        sa.Column("created_at", sa.DateTime(timezone=True), server_default=sa.func.now(), nullable=False),
        sa.Column("updated_at", sa.DateTime(timezone=True), server_default=sa.func.now(), nullable=False),
        sa.ForeignKeyConstraint(["exam_id"], ["exams.id"], ondelete="CASCADE"),
        sa.ForeignKeyConstraint(["topic_id"], ["topics.id"], ondelete="SET NULL"),
        sa.PrimaryKeyConstraint("id"),
        sa.UniqueConstraint("key"),
        sa.UniqueConstraint("topic_id"),
        sa.UniqueConstraint(
            "exam_id", "year", "session", "shift", "paper_code",
            name="uq_exam_paper_identity",
        ),
    )
    op.create_index("ix_exam_papers_exam_id", "exam_papers", ["exam_id"])
    op.create_index("ix_exam_papers_key", "exam_papers", ["key"])
    op.create_index("ix_exam_papers_source_sha256", "exam_papers", ["source_sha256"])
    op.create_index(
        "ix_exam_papers_exam_status_year", "exam_papers", ["exam_id", "status", "year"]
    )

    op.create_table(
        "exam_sections",
        sa.Column("id", postgresql.UUID(as_uuid=True), nullable=False),
        sa.Column("paper_id", postgresql.UUID(as_uuid=True), nullable=False),
        sa.Column("name", sa.String(length=120), nullable=False),
        sa.Column("subject", sa.String(length=80), nullable=False),
        sa.Column("position", sa.Integer(), nullable=False),
        sa.Column("first_question", sa.Integer(), nullable=False),
        sa.Column("last_question", sa.Integer(), nullable=False),
        sa.Column("question_count", sa.Integer(), nullable=False, server_default="0"),
        sa.Column("answer_type", answer_type_enum, nullable=False, server_default="single"),
        sa.Column(
            "marking",
            postgresql.JSONB(astext_type=sa.Text()),
            nullable=False,
            server_default=sa.text("'{}'::jsonb"),
        ),
        sa.Column(
            "rules",
            postgresql.JSONB(astext_type=sa.Text()),
            nullable=False,
            server_default=sa.text("'{}'::jsonb"),
        ),
        sa.Column("time_limit_minutes", sa.Integer(), nullable=True),
        sa.Column("created_at", sa.DateTime(timezone=True), server_default=sa.func.now(), nullable=False),
        sa.Column("updated_at", sa.DateTime(timezone=True), server_default=sa.func.now(), nullable=False),
        sa.ForeignKeyConstraint(["paper_id"], ["exam_papers.id"], ondelete="CASCADE"),
        sa.PrimaryKeyConstraint("id"),
        sa.UniqueConstraint("paper_id", "position", name="uq_exam_section_position"),
    )
    op.create_index("ix_exam_sections_paper_id", "exam_sections", ["paper_id"])

    op.create_table(
        "exam_questions",
        sa.Column("id", postgresql.UUID(as_uuid=True), nullable=False),
        sa.Column("paper_id", postgresql.UUID(as_uuid=True), nullable=False),
        sa.Column("section_id", postgresql.UUID(as_uuid=True), nullable=True),
        sa.Column("question_id", postgresql.UUID(as_uuid=True), nullable=False),
        sa.Column("question_number", sa.Integer(), nullable=False),
        sa.Column("marks", sa.Float(), nullable=False, server_default="1"),
        sa.Column("negative_marks", sa.Float(), nullable=False, server_default="0"),
        sa.Column("key_revision", sa.Integer(), nullable=False, server_default="1"),
        sa.Column("is_dropped", sa.Boolean(), nullable=False, server_default=sa.false()),
        sa.Column(
            "accepted_answers",
            postgresql.JSONB(astext_type=sa.Text()),
            nullable=False,
            server_default=sa.text("'[]'::jsonb"),
        ),
        sa.Column("answer_key_raw", sa.String(length=64), nullable=True),
        sa.Column("created_at", sa.DateTime(timezone=True), server_default=sa.func.now(), nullable=False),
        sa.Column("updated_at", sa.DateTime(timezone=True), server_default=sa.func.now(), nullable=False),
        sa.ForeignKeyConstraint(["paper_id"], ["exam_papers.id"], ondelete="CASCADE"),
        sa.ForeignKeyConstraint(["section_id"], ["exam_sections.id"], ondelete="SET NULL"),
        sa.ForeignKeyConstraint(["question_id"], ["questions.id"], ondelete="CASCADE"),
        sa.PrimaryKeyConstraint("id"),
        sa.UniqueConstraint("paper_id", "question_number", name="uq_exam_question_number"),
    )
    op.create_index("ix_exam_questions_paper_id", "exam_questions", ["paper_id"])
    op.create_index("ix_exam_questions_question_id", "exam_questions", ["question_id"])
    op.create_index(
        "ix_exam_questions_paper_section", "exam_questions", ["paper_id", "section_id"]
    )

    # ------------------------------------------------------------------
    # attempts
    # ------------------------------------------------------------------
    op.create_table(
        "mock_test_attempts",
        sa.Column("id", postgresql.UUID(as_uuid=True), nullable=False),
        sa.Column("user_id", postgresql.UUID(as_uuid=True), nullable=False),
        sa.Column("paper_id", postgresql.UUID(as_uuid=True), nullable=False),
        sa.Column("mode", attempt_mode_enum, nullable=False, server_default="full"),
        sa.Column("status", attempt_status_enum, nullable=False, server_default="in_progress"),
        sa.Column("section_id", postgresql.UUID(as_uuid=True), nullable=True),
        sa.Column("started_at", sa.DateTime(timezone=True), server_default=sa.func.now(), nullable=False),
        sa.Column("server_deadline_at", sa.DateTime(timezone=True), nullable=False),
        sa.Column("submitted_at", sa.DateTime(timezone=True), nullable=True),
        sa.Column("last_sync_revision", sa.BigInteger(), nullable=False, server_default="0"),
        sa.Column("score", sa.Float(), nullable=False, server_default="0"),
        sa.Column("max_score", sa.Float(), nullable=False, server_default="0"),
        sa.Column("correct_count", sa.Integer(), nullable=False, server_default="0"),
        sa.Column("incorrect_count", sa.Integer(), nullable=False, server_default="0"),
        sa.Column("unattempted_count", sa.Integer(), nullable=False, server_default="0"),
        sa.Column(
            "section_scores",
            postgresql.JSONB(astext_type=sa.Text()),
            nullable=False,
            server_default=sa.text("'{}'::jsonb"),
        ),
        sa.Column("percentile", sa.Float(), nullable=True),
        sa.Column("total_time_ms", sa.Integer(), nullable=False, server_default="0"),
        sa.Column(
            "config",
            postgresql.JSONB(astext_type=sa.Text()),
            nullable=False,
            server_default=sa.text("'{}'::jsonb"),
        ),
        sa.Column("created_at", sa.DateTime(timezone=True), server_default=sa.func.now(), nullable=False),
        sa.Column("updated_at", sa.DateTime(timezone=True), server_default=sa.func.now(), nullable=False),
        sa.ForeignKeyConstraint(["user_id"], ["users.id"], ondelete="CASCADE"),
        sa.ForeignKeyConstraint(["paper_id"], ["exam_papers.id"], ondelete="CASCADE"),
        sa.ForeignKeyConstraint(["section_id"], ["exam_sections.id"], ondelete="SET NULL"),
        sa.PrimaryKeyConstraint("id"),
    )
    op.create_index("ix_mock_attempts_user_id", "mock_test_attempts", ["user_id"])
    op.create_index("ix_mock_attempts_paper_id", "mock_test_attempts", ["paper_id"])
    op.create_index("ix_mock_attempts_user_status", "mock_test_attempts", ["user_id", "status"])
    op.create_index("ix_mock_attempts_paper_score", "mock_test_attempts", ["paper_id", "score"])
    # Partial index: the auto-submit sweep looks only at live attempts past
    # their deadline, which is a vanishing slice of an unbounded table.
    op.create_index(
        "ix_mock_attempts_live_deadline",
        "mock_test_attempts",
        ["server_deadline_at"],
        postgresql_where=sa.text("status = 'in_progress'"),
    )

    op.create_table(
        "mock_test_responses",
        sa.Column("attempt_id", postgresql.UUID(as_uuid=True), nullable=False),
        sa.Column("exam_question_id", postgresql.UUID(as_uuid=True), nullable=False),
        sa.Column("state", response_state_enum, nullable=False, server_default="not_visited"),
        sa.Column(
            "selected",
            postgresql.JSONB(astext_type=sa.Text()),
            nullable=False,
            server_default=sa.text("'[]'::jsonb"),
        ),
        sa.Column("numeric_value", sa.Float(), nullable=True),
        sa.Column("numeric_raw", sa.String(length=64), nullable=True),
        sa.Column("time_spent_ms", sa.Integer(), nullable=False, server_default="0"),
        sa.Column("visit_count", sa.Integer(), nullable=False, server_default="0"),
        sa.Column("client_revision", sa.BigInteger(), nullable=False, server_default="0"),
        sa.Column("is_correct", sa.Boolean(), nullable=True),
        sa.Column("marks_awarded", sa.Float(), nullable=True),
        sa.Column("counted", sa.Boolean(), nullable=False, server_default=sa.true()),
        sa.Column("first_seen_at", sa.DateTime(timezone=True), nullable=True),
        sa.Column("last_updated_at", sa.DateTime(timezone=True), nullable=True),
        sa.ForeignKeyConstraint(["attempt_id"], ["mock_test_attempts.id"], ondelete="CASCADE"),
        sa.ForeignKeyConstraint(["exam_question_id"], ["exam_questions.id"], ondelete="CASCADE"),
        sa.PrimaryKeyConstraint("attempt_id", "exam_question_id", name="pk_mock_test_response"),
    )


def downgrade() -> None:
    op.drop_table("mock_test_responses")
    op.drop_index("ix_mock_attempts_live_deadline", table_name="mock_test_attempts")
    op.drop_index("ix_mock_attempts_paper_score", table_name="mock_test_attempts")
    op.drop_index("ix_mock_attempts_user_status", table_name="mock_test_attempts")
    op.drop_index("ix_mock_attempts_paper_id", table_name="mock_test_attempts")
    op.drop_index("ix_mock_attempts_user_id", table_name="mock_test_attempts")
    op.drop_table("mock_test_attempts")

    op.drop_index("ix_exam_questions_paper_section", table_name="exam_questions")
    op.drop_index("ix_exam_questions_question_id", table_name="exam_questions")
    op.drop_index("ix_exam_questions_paper_id", table_name="exam_questions")
    op.drop_table("exam_questions")

    op.drop_index("ix_exam_sections_paper_id", table_name="exam_sections")
    op.drop_table("exam_sections")

    op.drop_index("ix_exam_papers_exam_status_year", table_name="exam_papers")
    op.drop_index("ix_exam_papers_source_sha256", table_name="exam_papers")
    op.drop_index("ix_exam_papers_key", table_name="exam_papers")
    op.drop_index("ix_exam_papers_exam_id", table_name="exam_papers")
    op.drop_table("exam_papers")

    op.drop_index("ix_exams_slug", table_name="exams")
    op.drop_table("exams")

    op.drop_index("ix_question_asset_links_asset_id", table_name="question_asset_links")
    op.drop_index("ix_question_asset_links_question_id", table_name="question_asset_links")
    op.drop_table("question_asset_links")
    op.drop_index("ix_question_assets_checksum", table_name="question_assets")
    op.drop_table("question_assets")

    op.drop_index("ix_questions_topic_lang_status_type", table_name="questions")
    # Every numeric question has a NULL here, so they have to go before the
    # column can be narrowed again. Deleting them is correct: without exam mode
    # there is nothing that can serve them.
    op.execute("DELETE FROM questions WHERE correct_option_index IS NULL")
    op.alter_column(
        "questions", "correct_option_index", existing_type=sa.Integer(), nullable=False
    )
    op.drop_column("questions", "solution_status")
    op.drop_column("questions", "option_content")
    op.drop_column("questions", "content")
    op.drop_column("questions", "answer_spec")
    op.drop_column("questions", "answer_type")

    bind = op.get_bind()
    for enum_type in reversed(ALL_ENUMS):
        enum_type.drop(bind, checkfirst=True)
