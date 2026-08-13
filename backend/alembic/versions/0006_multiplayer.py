"""Multiplayer: friends, matches, ranked ratings, devices and notifications.

Three things in here are worth knowing before reading the DDL.

**Usernames stop being confusable.** They were unique but case-sensitively, so
`Ravi` and `ravi` could both exist — harmless while a username was only ever
shown, and a real problem the moment other players search by it and challenge
by it. A new ``username_skeleton`` column stores the folded form (lowercased,
separators dropped, digits mapped to the letters they imitate) and carries the
unique index, so `R4vi` is refused too. Live data may already contain a
colliding pair, so the migration renames the losers *before* creating the
index rather than failing the deploy.

**Friendship pairs are canonicalized by Postgres.** ``friendships.pair_key`` is
a generated column, so the unordered pair {A,B} has one spelling regardless of
who sent the request. The unique index over it is partial — open requests and
accepted friendships occupy the slot; declined and cancelled rows do not — so a
refused request can be sent again later without deleting history.

**Friend codes are backfilled lazily.** ``friend_code`` lands nullable and the
service mints one on first read. Generating a few hundred thousand collision-
free codes inside a migration is a long-running write that buys nothing: nobody
can use a code until they open the app, and that read can make it.
"""

from typing import Sequence, Union

import sqlalchemy as sa
from alembic import op
from sqlalchemy.dialects import postgresql

revision: str = "0006_multiplayer"
down_revision: Union[str, None] = "0005_content_languages"
branch_labels: Union[str, Sequence[str], None] = None
depends_on: Union[str, Sequence[str], None] = None

_LANG_DEFAULT = sa.text("'en'")
_EMPTY_JSONB = sa.text("'{}'::jsonb")
_EMPTY_JSONB_ARRAY = sa.text("'[]'::jsonb")

# --- New Postgres ENUM types -------------------------------------------------
# Created up front so a table can reference one without owning its lifecycle,
# and so `downgrade` has a single place to drop them.

_ENUMS: dict[str, tuple[str, ...]] = {
    "friendship_status": ("pending", "accepted", "declined", "cancelled"),
    "match_format": ("duel", "room"),
    "match_kind": ("friendly", "ranked"),
    "match_delivery": ("live", "async"),
    "match_status": (
        "pending",
        "lobby",
        "live",
        "awaiting_opponent",
        "completed",
        "expired",
        "cancelled",
    ),
    "participant_status": (
        "invited",
        "joined",
        "ready",
        "playing",
        "finished",
        "declined",
        "forfeited",
    ),
    "match_outcome": ("win", "loss", "draw"),
    "notification_type": (
        "friend_request",
        "friend_accepted",
        "match_invite",
        "match_your_turn",
        "match_result",
        "match_expiring",
    ),
    "device_platform": ("android", "ios"),
}


def _enum(name: str) -> postgresql.ENUM:
    """Reference an already-created type; never emit CREATE TYPE from a column."""
    return postgresql.ENUM(*_ENUMS[name], name=name, create_type=False)


def _existing_enum(name: str) -> postgresql.ENUM:
    """Reference a type created by an earlier migration (game_mode et al)."""
    return postgresql.ENUM(name=name, create_type=False)


def _language_column(name: str) -> sa.Column:
    return sa.Column(name, sa.String(8), nullable=False, server_default=_LANG_DEFAULT)


# The confusable form of a username, as SQL. This must stay identical to
# `app.services.usernames.username_skeleton`: the column carries a unique index,
# so if the backfill and the application disagree, accounts created before this
# migration stop being comparable with accounts created after it.
_SKELETON_SQL = (
    "translate(lower(regexp_replace({col}, '[^A-Za-z0-9]', '', 'g')), "
    "'01345789', 'oieastbg')"
)


def _backfill_username_skeletons() -> None:
    """Fill in the skeleton column and break any ties it exposes.

    Case-insensitive uniqueness alone would already have needed a de-duplication
    pass; folding digits to letters widens the net (`Ravi` and `R4vi` now
    collide), so the pass runs against the skeleton rather than against
    ``lower(username)``.

    Losers are renamed with a suffix derived from their own row id, which is
    stable across a re-run and, being unique per row, cannot itself produce a
    second collision. The oldest account keeps its spelling.
    """
    skeleton_of_username = _SKELETON_SQL.format(col="username")

    op.execute(sa.text(f"UPDATE user_profiles SET username_skeleton = {skeleton_of_username}"))
    op.execute(
        sa.text(
            """
            WITH ranked AS (
                SELECT id,
                       row_number() OVER (
                           PARTITION BY username_skeleton ORDER BY created_at, id
                       ) AS rn
                  FROM user_profiles
            )
            UPDATE user_profiles AS p
               SET username = left(p.username, 24) || left(md5(p.id::text), 6)
              FROM ranked
             WHERE p.id = ranked.id
               AND ranked.rn > 1
            """
        )
    )
    op.execute(sa.text(f"UPDATE user_profiles SET username_skeleton = {skeleton_of_username}"))


def upgrade() -> None:
    bind = op.get_bind()
    for name, values in _ENUMS.items():
        postgresql.ENUM(*values, name=name).create(bind, checkfirst=True)

    # --- Profile: identity a stranger can find you by ----------------------
    op.add_column(
        "user_profiles",
        sa.Column("username_changed_at", sa.DateTime(timezone=True), nullable=True),
    )
    op.add_column(
        "user_profiles", sa.Column("friend_code", sa.String(12), nullable=True)
    )
    op.create_index(
        "ix_user_profiles_friend_code",
        "user_profiles",
        ["friend_code"],
        unique=True,
    )
    op.add_column(
        "user_profiles", sa.Column("username_skeleton", sa.String(32), nullable=True)
    )
    op.add_column(
        "user_profiles",
        sa.Column(
            "notification_prefs",
            postgresql.JSONB(),
            nullable=False,
            server_default=_EMPTY_JSONB,
        ),
    )

    _backfill_username_skeletons()

    op.alter_column("user_profiles", "username_skeleton", nullable=False)
    op.create_index(
        "uq_user_profiles_username_skeleton",
        "user_profiles",
        ["username_skeleton"],
        unique=True,
    )
    # Exact-name uniqueness follows from the skeleton index, but search reads
    # `lower(username) = ?` and wants an index of its own to do it on.
    op.create_index(
        "ix_user_profiles_username_lower",
        "user_profiles",
        [sa.text("lower(username)")],
    )

    # --- Lifetime head-to-head record --------------------------------------
    for column in (
        "multiplayer_played",
        "multiplayer_wins",
        "multiplayer_losses",
        "multiplayer_draws",
    ):
        op.add_column(
            "player_statistics",
            sa.Column(column, sa.Integer(), nullable=False, server_default="0"),
        )

    # --- Social graph -------------------------------------------------------
    op.create_table(
        "friendships",
        sa.Column("id", postgresql.UUID(as_uuid=True), primary_key=True),
        sa.Column(
            "requester_id",
            postgresql.UUID(as_uuid=True),
            sa.ForeignKey("users.id", ondelete="CASCADE"),
            nullable=False,
        ),
        sa.Column(
            "addressee_id",
            postgresql.UUID(as_uuid=True),
            sa.ForeignKey("users.id", ondelete="CASCADE"),
            nullable=False,
        ),
        sa.Column(
            "status",
            _enum("friendship_status"),
            nullable=False,
            server_default="pending",
        ),
        sa.Column("responded_at", sa.DateTime(timezone=True), nullable=True),
        sa.Column(
            "pair_key",
            sa.String(73),
            sa.Computed(
                "CASE WHEN requester_id < addressee_id "
                "THEN requester_id::text || ':' || addressee_id::text "
                "ELSE addressee_id::text || ':' || requester_id::text END",
                persisted=True,
            ),
            nullable=False,
        ),
        sa.Column(
            "created_at", sa.DateTime(timezone=True), server_default=sa.func.now(), nullable=False
        ),
        sa.Column(
            "updated_at", sa.DateTime(timezone=True), server_default=sa.func.now(), nullable=False
        ),
        sa.CheckConstraint("requester_id <> addressee_id", name="ck_friendship_not_self"),
    )
    op.create_index(
        "uq_friendship_open_pair",
        "friendships",
        ["pair_key"],
        unique=True,
        postgresql_where=sa.text("status IN ('pending', 'accepted')"),
    )
    op.create_index(
        "ix_friendships_addressee_status", "friendships", ["addressee_id", "status"]
    )
    op.create_index(
        "ix_friendships_requester_status", "friendships", ["requester_id", "status"]
    )

    op.create_table(
        "user_blocks",
        sa.Column("id", postgresql.UUID(as_uuid=True), primary_key=True),
        sa.Column(
            "blocker_id",
            postgresql.UUID(as_uuid=True),
            sa.ForeignKey("users.id", ondelete="CASCADE"),
            nullable=False,
        ),
        sa.Column(
            "blocked_id",
            postgresql.UUID(as_uuid=True),
            sa.ForeignKey("users.id", ondelete="CASCADE"),
            nullable=False,
        ),
        sa.Column("reason", sa.String(64), nullable=True),
        sa.Column(
            "created_at", sa.DateTime(timezone=True), server_default=sa.func.now(), nullable=False
        ),
        sa.Column(
            "updated_at", sa.DateTime(timezone=True), server_default=sa.func.now(), nullable=False
        ),
        sa.UniqueConstraint("blocker_id", "blocked_id", name="uq_user_block_pair"),
        sa.CheckConstraint("blocker_id <> blocked_id", name="ck_user_block_not_self"),
    )
    op.create_index("ix_user_blocks_blocker_id", "user_blocks", ["blocker_id"])
    op.create_index("ix_user_blocks_blocked_id", "user_blocks", ["blocked_id"])

    # --- Matches ------------------------------------------------------------
    op.create_table(
        "matches",
        sa.Column("id", postgresql.UUID(as_uuid=True), primary_key=True),
        sa.Column("code", sa.String(12), nullable=True),
        sa.Column("format", _enum("match_format"), nullable=False, server_default="duel"),
        sa.Column("kind", _enum("match_kind"), nullable=False, server_default="friendly"),
        sa.Column("delivery", _enum("match_delivery"), nullable=False, server_default="live"),
        sa.Column("status", _enum("match_status"), nullable=False, server_default="pending"),
        sa.Column(
            "created_by_user_id",
            postgresql.UUID(as_uuid=True),
            sa.ForeignKey("users.id", ondelete="CASCADE"),
            nullable=False,
        ),
        sa.Column(
            "topic_id",
            postgresql.UUID(as_uuid=True),
            sa.ForeignKey("topics.id", ondelete="CASCADE"),
            nullable=False,
        ),
        sa.Column("mode", _existing_enum("game_mode"), nullable=False, server_default="casual"),
        sa.Column(
            "difficulty",
            _existing_enum("difficulty_label"),
            nullable=False,
            server_default="medium",
        ),
        _language_column("language"),
        sa.Column("max_players", sa.Integer(), nullable=False, server_default="2"),
        sa.Column("question_count", sa.Integer(), nullable=False, server_default="7"),
        sa.Column(
            "question_time_limit_ms", sa.Integer(), nullable=False, server_default="15000"
        ),
        sa.Column(
            "question_ids", postgresql.JSONB(), nullable=False, server_default=_EMPTY_JSONB_ARRAY
        ),
        sa.Column(
            "option_orders", postgresql.JSONB(), nullable=False, server_default=_EMPTY_JSONB_ARRAY
        ),
        sa.Column("seed", sa.String(64), nullable=False, server_default=""),
        sa.Column("current_round_index", sa.Integer(), nullable=False, server_default="0"),
        sa.Column("round_started_at", sa.DateTime(timezone=True), nullable=True),
        sa.Column("started_at", sa.DateTime(timezone=True), nullable=True),
        sa.Column("finished_at", sa.DateTime(timezone=True), nullable=True),
        sa.Column("expires_at", sa.DateTime(timezone=True), nullable=True),
        sa.Column("rating_applied", sa.Boolean(), nullable=False, server_default=sa.false()),
        sa.Column("season_key", sa.String(16), nullable=True),
        sa.Column("config", postgresql.JSONB(), nullable=False, server_default=_EMPTY_JSONB),
        sa.Column(
            "created_at", sa.DateTime(timezone=True), server_default=sa.func.now(), nullable=False
        ),
        sa.Column(
            "updated_at", sa.DateTime(timezone=True), server_default=sa.func.now(), nullable=False
        ),
        sa.CheckConstraint("max_players BETWEEN 2 AND 8", name="ck_match_seat_count"),
    )
    op.create_index("ix_matches_code", "matches", ["code"], unique=True)
    op.create_index("ix_matches_created_by_user_id", "matches", ["created_by_user_id"])
    op.create_index("ix_matches_status_created", "matches", ["status", "created_at"])
    op.create_index("ix_matches_status_expires", "matches", ["status", "expires_at"])
    op.create_index("ix_matches_season_key", "matches", ["season_key"])

    op.create_table(
        "match_participants",
        sa.Column("id", postgresql.UUID(as_uuid=True), primary_key=True),
        sa.Column(
            "match_id",
            postgresql.UUID(as_uuid=True),
            sa.ForeignKey("matches.id", ondelete="CASCADE"),
            nullable=False,
        ),
        sa.Column(
            "user_id",
            postgresql.UUID(as_uuid=True),
            sa.ForeignKey("users.id", ondelete="CASCADE"),
            nullable=False,
        ),
        sa.Column(
            "status", _enum("participant_status"), nullable=False, server_default="invited"
        ),
        sa.Column("is_host", sa.Boolean(), nullable=False, server_default=sa.false()),
        sa.Column("score", sa.Integer(), nullable=False, server_default="0"),
        sa.Column("correct_count", sa.Integer(), nullable=False, server_default="0"),
        sa.Column("incorrect_count", sa.Integer(), nullable=False, server_default="0"),
        sa.Column("streak", sa.Integer(), nullable=False, server_default="0"),
        sa.Column("best_streak", sa.Integer(), nullable=False, server_default="0"),
        sa.Column("total_answer_ms", sa.Integer(), nullable=False, server_default="0"),
        sa.Column("rounds_answered", sa.Integer(), nullable=False, server_default="0"),
        sa.Column("round_served_at", sa.DateTime(timezone=True), nullable=True),
        sa.Column("joined_at", sa.DateTime(timezone=True), nullable=True),
        sa.Column("finished_at", sa.DateTime(timezone=True), nullable=True),
        sa.Column("last_seen_at", sa.DateTime(timezone=True), nullable=True),
        sa.Column("placement", sa.Integer(), nullable=True),
        sa.Column("outcome", _enum("match_outcome"), nullable=True),
        sa.Column("rating_before", sa.Integer(), nullable=True),
        sa.Column("rating_after", sa.Integer(), nullable=True),
        sa.Column("xp_earned", sa.Integer(), nullable=False, server_default="0"),
        sa.Column("coins_earned", sa.Integer(), nullable=False, server_default="0"),
        sa.Column(
            "created_at", sa.DateTime(timezone=True), server_default=sa.func.now(), nullable=False
        ),
        sa.Column(
            "updated_at", sa.DateTime(timezone=True), server_default=sa.func.now(), nullable=False
        ),
        sa.UniqueConstraint("match_id", "user_id", name="uq_match_participant"),
    )
    op.create_index("ix_match_participants_match_id", "match_participants", ["match_id"])
    op.create_index(
        "ix_match_participants_user_status", "match_participants", ["user_id", "status"]
    )

    op.create_table(
        "match_answers",
        sa.Column("id", postgresql.UUID(as_uuid=True), primary_key=True),
        sa.Column(
            "match_id",
            postgresql.UUID(as_uuid=True),
            sa.ForeignKey("matches.id", ondelete="CASCADE"),
            nullable=False,
        ),
        sa.Column(
            "participant_id",
            postgresql.UUID(as_uuid=True),
            sa.ForeignKey("match_participants.id", ondelete="CASCADE"),
            nullable=False,
        ),
        sa.Column(
            "user_id",
            postgresql.UUID(as_uuid=True),
            sa.ForeignKey("users.id", ondelete="CASCADE"),
            nullable=False,
        ),
        sa.Column("round_index", sa.Integer(), nullable=False),
        sa.Column(
            "question_id",
            postgresql.UUID(as_uuid=True),
            sa.ForeignKey("questions.id", ondelete="CASCADE"),
            nullable=False,
        ),
        sa.Column("selected_option_index", sa.Integer(), nullable=True),
        sa.Column("is_correct", sa.Boolean(), nullable=False, server_default=sa.false()),
        sa.Column("client_elapsed_ms", sa.Integer(), nullable=True),
        sa.Column("server_elapsed_ms", sa.Integer(), nullable=False, server_default="0"),
        sa.Column("base_points", sa.Integer(), nullable=False, server_default="0"),
        sa.Column("speed_bonus", sa.Integer(), nullable=False, server_default="0"),
        sa.Column("streak_multiplier", sa.Numeric(4, 2), nullable=False, server_default="1"),
        sa.Column("points_awarded", sa.Integer(), nullable=False, server_default="0"),
        sa.Column(
            "answered_at", sa.DateTime(timezone=True), server_default=sa.func.now(), nullable=False
        ),
        sa.UniqueConstraint("participant_id", "round_index", name="uq_match_answer_once"),
    )
    op.create_index("ix_match_answers_match_round", "match_answers", ["match_id", "round_index"])

    # --- Ranked -------------------------------------------------------------
    op.create_table(
        "player_ratings",
        sa.Column("id", postgresql.UUID(as_uuid=True), primary_key=True),
        sa.Column(
            "user_id",
            postgresql.UUID(as_uuid=True),
            sa.ForeignKey("users.id", ondelete="CASCADE"),
            nullable=False,
        ),
        sa.Column("season_key", sa.String(16), nullable=False),
        sa.Column("rating", sa.Integer(), nullable=False, server_default="1000"),
        sa.Column("peak_rating", sa.Integer(), nullable=False, server_default="1000"),
        sa.Column("placements_remaining", sa.Integer(), nullable=False, server_default="5"),
        sa.Column("matches_played", sa.Integer(), nullable=False, server_default="0"),
        sa.Column("wins", sa.Integer(), nullable=False, server_default="0"),
        sa.Column("losses", sa.Integer(), nullable=False, server_default="0"),
        sa.Column("draws", sa.Integer(), nullable=False, server_default="0"),
        sa.Column("win_streak", sa.Integer(), nullable=False, server_default="0"),
        sa.Column("best_win_streak", sa.Integer(), nullable=False, server_default="0"),
        sa.Column("last_match_at", sa.DateTime(timezone=True), nullable=True),
        sa.Column(
            "created_at", sa.DateTime(timezone=True), server_default=sa.func.now(), nullable=False
        ),
        sa.Column(
            "updated_at", sa.DateTime(timezone=True), server_default=sa.func.now(), nullable=False
        ),
        sa.UniqueConstraint("user_id", "season_key", name="uq_player_rating_season"),
    )
    op.create_index("ix_player_ratings_user_id", "player_ratings", ["user_id"])
    op.create_index(
        "ix_player_ratings_season_rating", "player_ratings", ["season_key", "rating"]
    )

    # --- Delivery -----------------------------------------------------------
    op.create_table(
        "device_tokens",
        sa.Column("id", postgresql.UUID(as_uuid=True), primary_key=True),
        sa.Column(
            "user_id",
            postgresql.UUID(as_uuid=True),
            sa.ForeignKey("users.id", ondelete="CASCADE"),
            nullable=False,
        ),
        sa.Column("token", sa.Text(), nullable=False),
        sa.Column(
            "platform", _enum("device_platform"), nullable=False, server_default="android"
        ),
        sa.Column("app_version", sa.String(32), nullable=True),
        _language_column("language"),
        sa.Column("utc_offset_minutes", sa.Integer(), nullable=False, server_default="0"),
        sa.Column("is_active", sa.Boolean(), nullable=False, server_default=sa.true()),
        sa.Column("last_seen_at", sa.DateTime(timezone=True), nullable=True),
        sa.Column("failure_count", sa.Integer(), nullable=False, server_default="0"),
        sa.Column(
            "created_at", sa.DateTime(timezone=True), server_default=sa.func.now(), nullable=False
        ),
        sa.Column(
            "updated_at", sa.DateTime(timezone=True), server_default=sa.func.now(), nullable=False
        ),
        sa.UniqueConstraint("token", name="uq_device_token"),
    )
    op.create_index("ix_device_tokens_user_active", "device_tokens", ["user_id", "is_active"])

    op.create_table(
        "notifications",
        sa.Column("id", postgresql.UUID(as_uuid=True), primary_key=True),
        sa.Column(
            "user_id",
            postgresql.UUID(as_uuid=True),
            sa.ForeignKey("users.id", ondelete="CASCADE"),
            nullable=False,
        ),
        sa.Column("type", _enum("notification_type"), nullable=False),
        sa.Column(
            "actor_user_id",
            postgresql.UUID(as_uuid=True),
            sa.ForeignKey("users.id", ondelete="CASCADE"),
            nullable=True,
        ),
        sa.Column(
            "match_id",
            postgresql.UUID(as_uuid=True),
            sa.ForeignKey("matches.id", ondelete="CASCADE"),
            nullable=True,
        ),
        sa.Column("payload", postgresql.JSONB(), nullable=False, server_default=_EMPTY_JSONB),
        sa.Column("deep_link", sa.String(255), nullable=True),
        sa.Column("read_at", sa.DateTime(timezone=True), nullable=True),
        sa.Column("pushed_at", sa.DateTime(timezone=True), nullable=True),
        sa.Column(
            "created_at", sa.DateTime(timezone=True), server_default=sa.func.now(), nullable=False
        ),
    )
    op.create_index("ix_notifications_user_created", "notifications", ["user_id", "created_at"])
    op.create_index(
        "ix_notifications_user_unread",
        "notifications",
        ["user_id"],
        postgresql_where=sa.text("read_at IS NULL"),
    )


def downgrade() -> None:
    op.drop_table("notifications")
    op.drop_table("device_tokens")
    op.drop_table("player_ratings")
    op.drop_table("match_answers")
    op.drop_table("match_participants")
    op.drop_table("matches")
    op.drop_table("user_blocks")
    op.drop_table("friendships")

    for column in (
        "multiplayer_draws",
        "multiplayer_losses",
        "multiplayer_wins",
        "multiplayer_played",
    ):
        op.drop_column("player_statistics", column)

    op.drop_index("ix_user_profiles_username_lower", table_name="user_profiles")
    op.drop_index("uq_user_profiles_username_skeleton", table_name="user_profiles")
    op.drop_index("ix_user_profiles_friend_code", table_name="user_profiles")
    op.drop_column("user_profiles", "notification_prefs")
    op.drop_column("user_profiles", "username_skeleton")
    op.drop_column("user_profiles", "friend_code")
    op.drop_column("user_profiles", "username_changed_at")

    bind = op.get_bind()
    for name in _ENUMS:
        postgresql.ENUM(name=name).drop(bind, checkfirst=True)
