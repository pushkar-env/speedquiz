"""Two language axes: app chrome language and question-bank content language.

Every existing row is English, so each column lands with a server default of
'en' and Postgres backfills it — no data migration, no rewrite pass, and old
clients that never send a language keep behaving exactly as before.

The topic/difficulty/status index on `questions` is replaced rather than
supplemented: after this migration every read of the bank is language-scoped,
so the old index would only add write cost. Its replacement leads with the same
`topic_id` prefix, so nothing that used it loses its index.
"""

from typing import Sequence, Union

import sqlalchemy as sa
from alembic import op
from sqlalchemy.dialects import postgresql

revision: str = "0005_content_languages"
down_revision: Union[str, None] = "0004_subscriptions_v2"
branch_labels: Union[str, Sequence[str], None] = None
depends_on: Union[str, Sequence[str], None] = None

_DEFAULT = sa.text("'en'")
_EMPTY_JSONB = sa.text("'{}'::jsonb")


def _language_column(name: str) -> sa.Column:
    return sa.Column(name, sa.String(8), nullable=False, server_default=_DEFAULT)


def _i18n_column(name: str) -> sa.Column:
    return sa.Column(name, postgresql.JSONB(), nullable=False, server_default=_EMPTY_JSONB)


def upgrade() -> None:
    # --- Content language -------------------------------------------------
    op.add_column("questions", _language_column("language"))
    op.add_column("quiz_sessions", _language_column("language"))
    op.add_column("custom_topics", _language_column("language"))
    op.add_column("generation_jobs", _language_column("language"))

    op.drop_index("ix_questions_topic_difficulty_status", table_name="questions")
    op.create_index(
        "ix_questions_topic_language_status",
        "questions",
        ["topic_id", "language", "status", "difficulty"],
    )

    # --- Player preferences ----------------------------------------------
    op.add_column("user_profiles", _language_column("app_language"))
    op.add_column("user_profiles", _language_column("quiz_language"))

    # --- Localized catalog copy ------------------------------------------
    op.add_column("topic_categories", _i18n_column("name_i18n"))
    op.add_column("topics", _i18n_column("name_i18n"))
    op.add_column("topics", _i18n_column("description_i18n"))


def downgrade() -> None:
    op.drop_column("topics", "description_i18n")
    op.drop_column("topics", "name_i18n")
    op.drop_column("topic_categories", "name_i18n")

    op.drop_column("user_profiles", "quiz_language")
    op.drop_column("user_profiles", "app_language")

    op.drop_index("ix_questions_topic_language_status", table_name="questions")
    op.create_index(
        "ix_questions_topic_difficulty_status",
        "questions",
        ["topic_id", "difficulty", "status"],
    )

    op.drop_column("generation_jobs", "language")
    op.drop_column("custom_topics", "language")
    op.drop_column("quiz_sessions", "language")
    op.drop_column("questions", "language")
