"""Initial schema for QuizVerse Phase 1."""

from typing import Sequence, Union

import sqlalchemy as sa
from alembic import op
from sqlalchemy.dialects import postgresql

revision: str = "0001_initial"
down_revision: Union[str, None] = None
branch_labels: Union[str, Sequence[str], None] = None
depends_on: Union[str, Sequence[str], None] = None

auth_provider = postgresql.ENUM(
    "guest", "email", "google", "apple", name="auth_provider", create_type=False
)
user_role = postgresql.ENUM("player", "admin", "moderator", name="user_role", create_type=False)
question_status = postgresql.ENUM(
    "pending", "active", "rejected", "retired", "reported", name="question_status", create_type=False
)
game_mode = postgresql.ENUM(
    "casual",
    "speedrun",
    "survival",
    "negative",
    "sudden_death",
    "daily",
    name="game_mode",
    create_type=False,
)
difficulty_label = postgresql.ENUM(
    "easy", "medium", "hard", "expert", name="difficulty_label", create_type=False
)
quiz_session_status = postgresql.ENUM(
    "pending", "active", "completed", "abandoned", "expired", name="quiz_session_status", create_type=False
)
subscription_status = postgresql.ENUM(
    "none", "active", "grace", "expired", "cancelled", name="subscription_status", create_type=False
)
generation_job_status = postgresql.ENUM(
    "queued", "running", "completed", "failed", name="generation_job_status", create_type=False
)


def upgrade() -> None:
    bind = op.get_bind()
    for enum_type in (
        auth_provider,
        user_role,
        question_status,
        game_mode,
        difficulty_label,
        quiz_session_status,
        subscription_status,
        generation_job_status,
    ):
        enum_type.create(bind, checkfirst=True)

    op.create_table(
        "users",
        sa.Column("id", postgresql.UUID(as_uuid=True), primary_key=True),
        sa.Column("email", sa.String(320), unique=True),
        sa.Column("password_hash", sa.String(255)),
        sa.Column("auth_provider", auth_provider, nullable=False),
        sa.Column("provider_subject", sa.String(255)),
        sa.Column("role", user_role, nullable=False),
        sa.Column("is_guest", sa.Boolean(), nullable=False, server_default=sa.text("true")),
        sa.Column("is_active", sa.Boolean(), nullable=False, server_default=sa.text("true")),
        sa.Column("is_premium", sa.Boolean(), nullable=False, server_default=sa.text("false")),
        sa.Column("last_login_at", sa.DateTime(timezone=True)),
        sa.Column("created_at", sa.DateTime(timezone=True), server_default=sa.text("now()"), nullable=False),
        sa.Column("updated_at", sa.DateTime(timezone=True), server_default=sa.text("now()"), nullable=False),
    )
    op.create_index("ix_users_email", "users", ["email"])
    op.create_index("ix_users_provider_subject", "users", ["provider_subject"])

    op.create_table(
        "topic_categories",
        sa.Column("id", postgresql.UUID(as_uuid=True), primary_key=True),
        sa.Column("slug", sa.String(64), nullable=False, unique=True),
        sa.Column("name", sa.String(100), nullable=False),
        sa.Column("description", sa.String(255)),
        sa.Column("icon", sa.String(64), nullable=False),
        sa.Column("sort_order", sa.Integer(), nullable=False, server_default="0"),
        sa.Column("is_active", sa.Boolean(), nullable=False, server_default=sa.text("true")),
        sa.Column("created_at", sa.DateTime(timezone=True), server_default=sa.text("now()"), nullable=False),
        sa.Column("updated_at", sa.DateTime(timezone=True), server_default=sa.text("now()"), nullable=False),
    )

    op.create_table(
        "achievements",
        sa.Column("id", postgresql.UUID(as_uuid=True), primary_key=True),
        sa.Column("code", sa.String(64), nullable=False, unique=True),
        sa.Column("name", sa.String(120), nullable=False),
        sa.Column("description", sa.Text(), nullable=False),
        sa.Column("icon", sa.String(64), nullable=False),
        sa.Column("category", sa.String(64), nullable=False),
        sa.Column("criteria", postgresql.JSONB(), nullable=False),
        sa.Column("xp_reward", sa.Integer(), nullable=False, server_default="0"),
        sa.Column("coins_reward", sa.Integer(), nullable=False, server_default="0"),
        sa.Column("is_active", sa.Boolean(), nullable=False, server_default=sa.text("true")),
        sa.Column("sort_order", sa.Integer(), nullable=False, server_default="0"),
        sa.Column("created_at", sa.DateTime(timezone=True), server_default=sa.text("now()"), nullable=False),
        sa.Column("updated_at", sa.DateTime(timezone=True), server_default=sa.text("now()"), nullable=False),
    )

    op.create_table(
        "user_profiles",
        sa.Column("id", postgresql.UUID(as_uuid=True), primary_key=True),
        sa.Column("user_id", postgresql.UUID(as_uuid=True), sa.ForeignKey("users.id", ondelete="CASCADE"), nullable=False, unique=True),
        sa.Column("username", sa.String(32), nullable=False, unique=True),
        sa.Column("display_name", sa.String(64)),
        sa.Column("avatar_id", sa.String(64), nullable=False),
        sa.Column("bio", sa.String(280)),
        sa.Column("level", sa.Integer(), nullable=False, server_default="1"),
        sa.Column("xp", sa.Integer(), nullable=False, server_default="0"),
        sa.Column("coins", sa.Integer(), nullable=False, server_default="0"),
        sa.Column("current_streak", sa.Integer(), nullable=False, server_default="0"),
        sa.Column("best_streak", sa.Integer(), nullable=False, server_default="0"),
        sa.Column("daily_streak", sa.Integer(), nullable=False, server_default="0"),
        sa.Column("last_played_date", sa.Date()),
        sa.Column("favorite_topic_ids", postgresql.JSONB(), nullable=False, server_default=sa.text("'[]'::jsonb")),
        sa.Column("onboarding_completed", sa.Boolean(), nullable=False, server_default=sa.text("false")),
        sa.Column("theme_preference", sa.String(16), nullable=False, server_default="dark"),
        sa.Column("created_at", sa.DateTime(timezone=True), server_default=sa.text("now()"), nullable=False),
        sa.Column("updated_at", sa.DateTime(timezone=True), server_default=sa.text("now()"), nullable=False),
    )
    op.create_index("ix_user_profiles_username", "user_profiles", ["username"])

    op.create_table(
        "player_statistics",
        sa.Column("id", postgresql.UUID(as_uuid=True), primary_key=True),
        sa.Column("user_id", postgresql.UUID(as_uuid=True), sa.ForeignKey("users.id", ondelete="CASCADE"), nullable=False, unique=True),
        sa.Column("total_quizzes", sa.Integer(), nullable=False, server_default="0"),
        sa.Column("total_questions", sa.Integer(), nullable=False, server_default="0"),
        sa.Column("total_correct", sa.Integer(), nullable=False, server_default="0"),
        sa.Column("total_incorrect", sa.Integer(), nullable=False, server_default="0"),
        sa.Column("best_score", sa.Integer(), nullable=False, server_default="0"),
        sa.Column("total_score", sa.Integer(), nullable=False, server_default="0"),
        sa.Column("best_streak", sa.Integer(), nullable=False, server_default="0"),
        sa.Column("average_answer_ms", sa.Integer(), nullable=False, server_default="0"),
        sa.Column("topic_mastery", postgresql.JSONB(), nullable=False, server_default=sa.text("'{}'::jsonb")),
        sa.Column("skill_ratings", postgresql.JSONB(), nullable=False, server_default=sa.text("'{}'::jsonb")),
        sa.Column("created_at", sa.DateTime(timezone=True), server_default=sa.text("now()"), nullable=False),
        sa.Column("updated_at", sa.DateTime(timezone=True), server_default=sa.text("now()"), nullable=False),
    )

    op.create_table(
        "refresh_tokens",
        sa.Column("id", postgresql.UUID(as_uuid=True), primary_key=True),
        sa.Column("user_id", postgresql.UUID(as_uuid=True), sa.ForeignKey("users.id", ondelete="CASCADE"), nullable=False),
        sa.Column("token_hash", sa.String(128), nullable=False, unique=True),
        sa.Column("expires_at", sa.DateTime(timezone=True), nullable=False),
        sa.Column("revoked_at", sa.DateTime(timezone=True)),
        sa.Column("device_info", sa.String(255)),
        sa.Column("created_at", sa.DateTime(timezone=True), server_default=sa.text("now()"), nullable=False),
        sa.Column("updated_at", sa.DateTime(timezone=True), server_default=sa.text("now()"), nullable=False),
    )
    op.create_index("ix_refresh_tokens_user_id", "refresh_tokens", ["user_id"])

    op.create_table(
        "topics",
        sa.Column("id", postgresql.UUID(as_uuid=True), primary_key=True),
        sa.Column("category_id", postgresql.UUID(as_uuid=True), sa.ForeignKey("topic_categories.id", ondelete="SET NULL")),
        sa.Column("slug", sa.String(100), nullable=False, unique=True),
        sa.Column("name", sa.String(120), nullable=False),
        sa.Column("description", sa.Text()),
        sa.Column("icon", sa.String(64), nullable=False),
        sa.Column("is_custom", sa.Boolean(), nullable=False, server_default=sa.text("false")),
        sa.Column("is_active", sa.Boolean(), nullable=False, server_default=sa.text("true")),
        sa.Column("is_trending", sa.Boolean(), nullable=False, server_default=sa.text("false")),
        sa.Column("popularity_score", sa.Integer(), nullable=False, server_default="0"),
        sa.Column("question_count", sa.Integer(), nullable=False, server_default="0"),
        sa.Column("created_by_user_id", postgresql.UUID(as_uuid=True), sa.ForeignKey("users.id", ondelete="SET NULL")),
        sa.Column("created_at", sa.DateTime(timezone=True), server_default=sa.text("now()"), nullable=False),
        sa.Column("updated_at", sa.DateTime(timezone=True), server_default=sa.text("now()"), nullable=False),
    )
    op.create_index("ix_topics_slug", "topics", ["slug"])

    op.create_table(
        "subtopics",
        sa.Column("id", postgresql.UUID(as_uuid=True), primary_key=True),
        sa.Column("topic_id", postgresql.UUID(as_uuid=True), sa.ForeignKey("topics.id", ondelete="CASCADE"), nullable=False),
        sa.Column("slug", sa.String(120), nullable=False),
        sa.Column("name", sa.String(120), nullable=False),
        sa.Column("description", sa.Text()),
        sa.Column("is_active", sa.Boolean(), nullable=False, server_default=sa.text("true")),
        sa.Column("created_at", sa.DateTime(timezone=True), server_default=sa.text("now()"), nullable=False),
        sa.Column("updated_at", sa.DateTime(timezone=True), server_default=sa.text("now()"), nullable=False),
        sa.UniqueConstraint("topic_id", "slug", name="uq_subtopic_topic_slug"),
    )
    op.create_index("ix_subtopics_topic_id", "subtopics", ["topic_id"])

    op.create_table(
        "custom_topics",
        sa.Column("id", postgresql.UUID(as_uuid=True), primary_key=True),
        sa.Column("user_id", postgresql.UUID(as_uuid=True), sa.ForeignKey("users.id", ondelete="CASCADE"), nullable=False),
        sa.Column("topic_id", postgresql.UUID(as_uuid=True), sa.ForeignKey("topics.id", ondelete="SET NULL")),
        sa.Column("prompt", sa.Text(), nullable=False),
        sa.Column("sanitized_prompt", sa.Text(), nullable=False),
        sa.Column("classified_subject", sa.String(120)),
        sa.Column("difficulty", difficulty_label, nullable=False),
        sa.Column("style", sa.String(120)),
        sa.Column("requested_count", sa.Integer(), nullable=False, server_default="10"),
        sa.Column("cache_key", sa.String(128), nullable=False),
        sa.Column("status", sa.String(32), nullable=False, server_default="pending"),
        sa.Column("created_at", sa.DateTime(timezone=True), server_default=sa.text("now()"), nullable=False),
        sa.Column("updated_at", sa.DateTime(timezone=True), server_default=sa.text("now()"), nullable=False),
    )
    op.create_index("ix_custom_topics_user_id", "custom_topics", ["user_id"])
    op.create_index("ix_custom_topics_cache_key", "custom_topics", ["cache_key"])

    op.create_table(
        "questions",
        sa.Column("id", postgresql.UUID(as_uuid=True), primary_key=True),
        sa.Column("topic_id", postgresql.UUID(as_uuid=True), sa.ForeignKey("topics.id", ondelete="CASCADE"), nullable=False),
        sa.Column("subtopic_id", postgresql.UUID(as_uuid=True), sa.ForeignKey("subtopics.id", ondelete="SET NULL")),
        sa.Column("prompt", sa.Text(), nullable=False),
        sa.Column("explanation", sa.Text(), nullable=False),
        sa.Column("source", sa.String(255)),
        sa.Column("difficulty", sa.Float(), nullable=False),
        sa.Column("difficulty_label", difficulty_label, nullable=False),
        sa.Column("correct_option_index", sa.Integer(), nullable=False),
        sa.Column("quality_score", sa.Integer(), nullable=False, server_default="0"),
        sa.Column("status", question_status, nullable=False),
        sa.Column("content_hash", sa.String(64), nullable=False, unique=True),
        sa.Column("embedding_fingerprint", sa.String(128)),
        sa.Column("times_served", sa.Integer(), nullable=False, server_default="0"),
        sa.Column("times_correct", sa.Integer(), nullable=False, server_default="0"),
        sa.Column("times_incorrect", sa.Integer(), nullable=False, server_default="0"),
        sa.Column("times_reported", sa.Integer(), nullable=False, server_default="0"),
        sa.Column("generation_meta", postgresql.JSONB(), nullable=False, server_default=sa.text("'{}'::jsonb")),
        sa.Column("created_at", sa.DateTime(timezone=True), server_default=sa.text("now()"), nullable=False),
        sa.Column("updated_at", sa.DateTime(timezone=True), server_default=sa.text("now()"), nullable=False),
    )
    op.create_index("ix_questions_topic_id", "questions", ["topic_id"])
    op.create_index("ix_questions_status", "questions", ["status"])
    op.create_index("ix_questions_embedding_fingerprint", "questions", ["embedding_fingerprint"])
    op.create_index("ix_questions_topic_difficulty_status", "questions", ["topic_id", "difficulty", "status"])
    op.create_index("ix_questions_quality_status", "questions", ["quality_score", "status"])

    op.create_table(
        "question_options",
        sa.Column("id", postgresql.UUID(as_uuid=True), primary_key=True),
        sa.Column("question_id", postgresql.UUID(as_uuid=True), sa.ForeignKey("questions.id", ondelete="CASCADE"), nullable=False),
        sa.Column("position", sa.Integer(), nullable=False),
        sa.Column("text", sa.Text(), nullable=False),
        sa.UniqueConstraint("question_id", "position", name="uq_question_option_position"),
    )
    op.create_index("ix_question_options_question_id", "question_options", ["question_id"])

    op.create_table(
        "daily_challenges",
        sa.Column("id", postgresql.UUID(as_uuid=True), primary_key=True),
        sa.Column("challenge_date", sa.Date(), nullable=False),
        sa.Column("topic_id", postgresql.UUID(as_uuid=True), sa.ForeignKey("topics.id", ondelete="CASCADE"), nullable=False),
        sa.Column("title", sa.String(120), nullable=False),
        sa.Column("difficulty", difficulty_label, nullable=False),
        sa.Column("question_ids", postgresql.JSONB(), nullable=False),
        sa.Column("is_active", sa.Boolean(), nullable=False, server_default=sa.text("true")),
        sa.Column("created_at", sa.DateTime(timezone=True), server_default=sa.text("now()"), nullable=False),
        sa.Column("updated_at", sa.DateTime(timezone=True), server_default=sa.text("now()"), nullable=False),
        sa.UniqueConstraint("challenge_date", name="uq_daily_challenge_date"),
    )

    op.create_table(
        "quiz_sessions",
        sa.Column("id", postgresql.UUID(as_uuid=True), primary_key=True),
        sa.Column("user_id", postgresql.UUID(as_uuid=True), sa.ForeignKey("users.id", ondelete="CASCADE"), nullable=False),
        sa.Column("topic_id", postgresql.UUID(as_uuid=True), sa.ForeignKey("topics.id", ondelete="CASCADE"), nullable=False),
        sa.Column("mode", game_mode, nullable=False),
        sa.Column("difficulty", difficulty_label, nullable=False),
        sa.Column("status", quiz_session_status, nullable=False),
        sa.Column("score", sa.Integer(), nullable=False, server_default="0"),
        sa.Column("streak", sa.Integer(), nullable=False, server_default="0"),
        sa.Column("best_streak", sa.Integer(), nullable=False, server_default="0"),
        sa.Column("lives", sa.Integer()),
        sa.Column("time_budget_ms", sa.Integer()),
        sa.Column("time_remaining_ms", sa.Integer()),
        sa.Column("question_time_limit_ms", sa.Integer(), nullable=False, server_default="15000"),
        sa.Column("current_question_index", sa.Integer(), nullable=False, server_default="0"),
        sa.Column("correct_count", sa.Integer(), nullable=False, server_default="0"),
        sa.Column("incorrect_count", sa.Integer(), nullable=False, server_default="0"),
        sa.Column("started_at", sa.DateTime(timezone=True)),
        sa.Column("finished_at", sa.DateTime(timezone=True)),
        sa.Column("config", postgresql.JSONB(), nullable=False, server_default=sa.text("'{}'::jsonb")),
        sa.Column("is_daily_challenge", sa.Boolean(), nullable=False, server_default=sa.text("false")),
        sa.Column("daily_challenge_id", postgresql.UUID(as_uuid=True), sa.ForeignKey("daily_challenges.id", ondelete="SET NULL")),
        sa.Column("created_at", sa.DateTime(timezone=True), server_default=sa.text("now()"), nullable=False),
        sa.Column("updated_at", sa.DateTime(timezone=True), server_default=sa.text("now()"), nullable=False),
    )
    op.create_index("ix_quiz_sessions_user_id", "quiz_sessions", ["user_id"])
    op.create_index("ix_quiz_sessions_user_status", "quiz_sessions", ["user_id", "status"])

    op.create_table(
        "quiz_questions",
        sa.Column("id", postgresql.UUID(as_uuid=True), primary_key=True),
        sa.Column("session_id", postgresql.UUID(as_uuid=True), sa.ForeignKey("quiz_sessions.id", ondelete="CASCADE"), nullable=False),
        sa.Column("question_id", postgresql.UUID(as_uuid=True), sa.ForeignKey("questions.id", ondelete="CASCADE"), nullable=False),
        sa.Column("sequence_index", sa.Integer(), nullable=False),
        sa.Column("served_at", sa.DateTime(timezone=True)),
        sa.Column("option_order", postgresql.JSONB(), nullable=False, server_default=sa.text("'[]'::jsonb")),
        sa.UniqueConstraint("session_id", "sequence_index", name="uq_quiz_question_sequence"),
        sa.UniqueConstraint("session_id", "question_id", name="uq_quiz_question_unique"),
    )
    op.create_index("ix_quiz_questions_session_id", "quiz_questions", ["session_id"])

    op.create_table(
        "answers",
        sa.Column("id", postgresql.UUID(as_uuid=True), primary_key=True),
        sa.Column("session_id", postgresql.UUID(as_uuid=True), sa.ForeignKey("quiz_sessions.id", ondelete="CASCADE"), nullable=False),
        sa.Column("quiz_question_id", postgresql.UUID(as_uuid=True), sa.ForeignKey("quiz_questions.id", ondelete="CASCADE"), nullable=False),
        sa.Column("question_id", postgresql.UUID(as_uuid=True), sa.ForeignKey("questions.id", ondelete="CASCADE"), nullable=False),
        sa.Column("selected_option_index", sa.Integer()),
        sa.Column("is_correct", sa.Boolean(), nullable=False),
        sa.Column("client_elapsed_ms", sa.Integer()),
        sa.Column("server_elapsed_ms", sa.Integer(), nullable=False),
        sa.Column("base_points", sa.Integer(), nullable=False, server_default="0"),
        sa.Column("speed_bonus", sa.Integer(), nullable=False, server_default="0"),
        sa.Column("streak_multiplier", sa.Numeric(4, 2), nullable=False, server_default="1"),
        sa.Column("points_awarded", sa.Integer(), nullable=False, server_default="0"),
        sa.Column("answered_at", sa.DateTime(timezone=True), server_default=sa.text("now()"), nullable=False),
        sa.Column("created_at", sa.DateTime(timezone=True), server_default=sa.text("now()"), nullable=False),
        sa.Column("updated_at", sa.DateTime(timezone=True), server_default=sa.text("now()"), nullable=False),
        sa.UniqueConstraint("session_id", "quiz_question_id", name="uq_answer_once"),
    )
    op.create_index("ix_answers_session_id", "answers", ["session_id"])

    op.create_table(
        "scores",
        sa.Column("id", postgresql.UUID(as_uuid=True), primary_key=True),
        sa.Column("user_id", postgresql.UUID(as_uuid=True), sa.ForeignKey("users.id", ondelete="CASCADE"), nullable=False),
        sa.Column("session_id", postgresql.UUID(as_uuid=True), sa.ForeignKey("quiz_sessions.id", ondelete="CASCADE"), nullable=False, unique=True),
        sa.Column("topic_id", postgresql.UUID(as_uuid=True), sa.ForeignKey("topics.id", ondelete="CASCADE"), nullable=False),
        sa.Column("mode", game_mode, nullable=False),
        sa.Column("difficulty", difficulty_label, nullable=False),
        sa.Column("final_score", sa.Integer(), nullable=False),
        sa.Column("accuracy", sa.Float(), nullable=False),
        sa.Column("best_streak", sa.Integer(), nullable=False),
        sa.Column("questions_answered", sa.Integer(), nullable=False),
        sa.Column("xp_earned", sa.Integer(), nullable=False, server_default="0"),
        sa.Column("is_personal_best", sa.Boolean(), nullable=False, server_default=sa.text("false")),
        sa.Column("created_at", sa.DateTime(timezone=True), server_default=sa.text("now()"), nullable=False),
        sa.Column("updated_at", sa.DateTime(timezone=True), server_default=sa.text("now()"), nullable=False),
    )
    op.create_index("ix_scores_user_id", "scores", ["user_id"])
    op.create_index("ix_scores_topic_id", "scores", ["topic_id"])

    op.create_table(
        "quiz_results",
        sa.Column("id", postgresql.UUID(as_uuid=True), primary_key=True),
        sa.Column("session_id", postgresql.UUID(as_uuid=True), sa.ForeignKey("quiz_sessions.id", ondelete="CASCADE"), nullable=False, unique=True),
        sa.Column("user_id", postgresql.UUID(as_uuid=True), sa.ForeignKey("users.id", ondelete="CASCADE"), nullable=False),
        sa.Column("summary", postgresql.JSONB(), nullable=False, server_default=sa.text("'{}'::jsonb")),
        sa.Column("share_payload", postgresql.JSONB(), nullable=False, server_default=sa.text("'{}'::jsonb")),
        sa.Column("comparisons", postgresql.JSONB(), nullable=False, server_default=sa.text("'{}'::jsonb")),
        sa.Column("created_at", sa.DateTime(timezone=True), server_default=sa.text("now()"), nullable=False),
        sa.Column("updated_at", sa.DateTime(timezone=True), server_default=sa.text("now()"), nullable=False),
    )
    op.create_index("ix_quiz_results_user_id", "quiz_results", ["user_id"])

    op.create_table(
        "leaderboards",
        sa.Column("id", postgresql.UUID(as_uuid=True), primary_key=True),
        sa.Column("scope", sa.String(32), nullable=False),
        sa.Column("period_key", sa.String(32), nullable=False),
        sa.Column("user_id", postgresql.UUID(as_uuid=True), sa.ForeignKey("users.id", ondelete="CASCADE"), nullable=False),
        sa.Column("topic_id", postgresql.UUID(as_uuid=True), sa.ForeignKey("topics.id", ondelete="CASCADE")),
        sa.Column("mode", game_mode),
        sa.Column("score", sa.Integer(), nullable=False),
        sa.Column("rank", sa.Integer(), nullable=False),
        sa.Column("created_at", sa.DateTime(timezone=True), server_default=sa.text("now()"), nullable=False),
        sa.Column("updated_at", sa.DateTime(timezone=True), server_default=sa.text("now()"), nullable=False),
        sa.UniqueConstraint("scope", "period_key", "user_id", "topic_id", "mode", name="uq_leaderboard_entry"),
    )
    op.create_index("ix_leaderboards_scope_period", "leaderboards", ["scope", "period_key", "rank"])

    op.create_table(
        "streaks",
        sa.Column("id", postgresql.UUID(as_uuid=True), primary_key=True),
        sa.Column("user_id", postgresql.UUID(as_uuid=True), sa.ForeignKey("users.id", ondelete="CASCADE"), nullable=False),
        sa.Column("streak_type", sa.String(32), nullable=False),
        sa.Column("current_count", sa.Integer(), nullable=False, server_default="0"),
        sa.Column("best_count", sa.Integer(), nullable=False, server_default="0"),
        sa.Column("last_increment_date", sa.Date()),
        sa.Column("created_at", sa.DateTime(timezone=True), server_default=sa.text("now()"), nullable=False),
        sa.Column("updated_at", sa.DateTime(timezone=True), server_default=sa.text("now()"), nullable=False),
        sa.UniqueConstraint("user_id", "streak_type", name="uq_user_streak_type"),
    )
    op.create_index("ix_streaks_user_id", "streaks", ["user_id"])

    op.create_table(
        "user_achievements",
        sa.Column("id", postgresql.UUID(as_uuid=True), primary_key=True),
        sa.Column("user_id", postgresql.UUID(as_uuid=True), sa.ForeignKey("users.id", ondelete="CASCADE"), nullable=False),
        sa.Column("achievement_id", postgresql.UUID(as_uuid=True), sa.ForeignKey("achievements.id", ondelete="CASCADE"), nullable=False),
        sa.Column("unlocked_at", sa.DateTime(timezone=True), server_default=sa.text("now()"), nullable=False),
        sa.Column("meta", postgresql.JSONB(), nullable=False, server_default=sa.text("'{}'::jsonb")),
        sa.Column("created_at", sa.DateTime(timezone=True), server_default=sa.text("now()"), nullable=False),
        sa.Column("updated_at", sa.DateTime(timezone=True), server_default=sa.text("now()"), nullable=False),
        sa.UniqueConstraint("user_id", "achievement_id", name="uq_user_achievement"),
    )
    op.create_index("ix_user_achievements_user_id", "user_achievements", ["user_id"])

    op.create_table(
        "question_reports",
        sa.Column("id", postgresql.UUID(as_uuid=True), primary_key=True),
        sa.Column("question_id", postgresql.UUID(as_uuid=True), sa.ForeignKey("questions.id", ondelete="CASCADE"), nullable=False),
        sa.Column("user_id", postgresql.UUID(as_uuid=True), sa.ForeignKey("users.id", ondelete="CASCADE"), nullable=False),
        sa.Column("reason", sa.String(64), nullable=False),
        sa.Column("details", sa.Text()),
        sa.Column("status", sa.String(32), nullable=False, server_default="open"),
        sa.Column("created_at", sa.DateTime(timezone=True), server_default=sa.text("now()"), nullable=False),
        sa.Column("updated_at", sa.DateTime(timezone=True), server_default=sa.text("now()"), nullable=False),
    )
    op.create_index("ix_question_reports_question_id", "question_reports", ["question_id"])

    op.create_table(
        "subscriptions",
        sa.Column("id", postgresql.UUID(as_uuid=True), primary_key=True),
        sa.Column("user_id", postgresql.UUID(as_uuid=True), sa.ForeignKey("users.id", ondelete="CASCADE"), nullable=False),
        sa.Column("status", subscription_status, nullable=False),
        sa.Column("product_id", sa.String(128)),
        sa.Column("platform", sa.String(32)),
        sa.Column("original_transaction_id", sa.String(255), unique=True),
        sa.Column("expires_at", sa.DateTime(timezone=True)),
        sa.Column("entitlements", postgresql.JSONB(), nullable=False, server_default=sa.text("'{}'::jsonb")),
        sa.Column("created_at", sa.DateTime(timezone=True), server_default=sa.text("now()"), nullable=False),
        sa.Column("updated_at", sa.DateTime(timezone=True), server_default=sa.text("now()"), nullable=False),
    )
    op.create_index("ix_subscriptions_user_id", "subscriptions", ["user_id"])

    op.create_table(
        "generation_jobs",
        sa.Column("id", postgresql.UUID(as_uuid=True), primary_key=True),
        sa.Column("topic_id", postgresql.UUID(as_uuid=True), sa.ForeignKey("topics.id", ondelete="SET NULL")),
        sa.Column("custom_topic_id", postgresql.UUID(as_uuid=True), sa.ForeignKey("custom_topics.id", ondelete="SET NULL")),
        sa.Column("requested_by_user_id", postgresql.UUID(as_uuid=True), sa.ForeignKey("users.id", ondelete="SET NULL")),
        sa.Column("status", generation_job_status, nullable=False),
        sa.Column("requested_count", sa.Integer(), nullable=False, server_default="10"),
        sa.Column("approved_count", sa.Integer(), nullable=False, server_default="0"),
        sa.Column("rejected_count", sa.Integer(), nullable=False, server_default="0"),
        sa.Column("attempts", sa.Integer(), nullable=False, server_default="0"),
        sa.Column("error_message", sa.Text()),
        sa.Column("payload", postgresql.JSONB(), nullable=False, server_default=sa.text("'{}'::jsonb")),
        sa.Column("created_at", sa.DateTime(timezone=True), server_default=sa.text("now()"), nullable=False),
        sa.Column("updated_at", sa.DateTime(timezone=True), server_default=sa.text("now()"), nullable=False),
    )
    op.create_index("ix_generation_jobs_status", "generation_jobs", ["status"])


def downgrade() -> None:
    for table in [
        "generation_jobs",
        "subscriptions",
        "question_reports",
        "user_achievements",
        "streaks",
        "leaderboards",
        "quiz_results",
        "scores",
        "answers",
        "quiz_questions",
        "quiz_sessions",
        "daily_challenges",
        "question_options",
        "questions",
        "custom_topics",
        "subtopics",
        "topics",
        "refresh_tokens",
        "player_statistics",
        "user_profiles",
        "achievements",
        "topic_categories",
        "users",
    ]:
        op.drop_table(table)

    bind = op.get_bind()
    for enum_type in (
        generation_job_status,
        subscription_status,
        quiz_session_status,
        difficulty_label,
        game_mode,
        question_status,
        user_role,
        auth_provider,
    ):
        enum_type.drop(bind, checkfirst=True)
