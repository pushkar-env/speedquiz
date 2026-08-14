"""Grounding corpus: harvested headlines the generator builds questions from.

Nothing else in the schema references this table. It is a cache of public feed
metadata with a retention sweep, so it can be truncated at any time and the
next harvest cycle refills it — which is also why there is no foreign key from
`questions` back to it. Questions record the snippet ids they cited in
`generation_meta`, not a row reference that would block retention.

The full-text index is the whole retrieval story: no embeddings, no pgvector,
no extra service. `search_vector` is a stored generated column so it cannot
drift from the text it indexes, and its text-search config is chosen per row
because Postgres has an English stemmer and no Hindi one.
"""

from typing import Sequence, Union

import sqlalchemy as sa
from alembic import op
from sqlalchemy.dialects import postgresql

revision: str = "0008_news_corpus"
down_revision: Union[str, None] = "0007_question_freshness"
branch_labels: Union[str, Sequence[str], None] = None
depends_on: Union[str, Sequence[str], None] = None

_SEARCH_EXPRESSION = (
    "to_tsvector("
    "CASE WHEN language = 'en' THEN 'english'::regconfig "
    "ELSE 'simple'::regconfig END, "
    "coalesce(title, '') || ' ' || coalesce(summary, ''))"
)


def upgrade() -> None:
    op.create_table(
        "news_documents",
        sa.Column("id", postgresql.UUID(as_uuid=True), primary_key=True),
        sa.Column("source", sa.String(120), nullable=False),
        sa.Column("url", sa.Text(), nullable=False),
        sa.Column("title", sa.Text(), nullable=False),
        sa.Column("summary", sa.Text(), nullable=False, server_default=sa.text("''")),
        sa.Column("published_at", sa.DateTime(timezone=True), nullable=False),
        sa.Column("language", sa.String(8), nullable=False, server_default=sa.text("'en'")),
        sa.Column("category", sa.String(40), nullable=False, server_default=sa.text("'general'")),
        sa.Column("content_hash", sa.String(64), nullable=False, unique=True),
        sa.Column(
            "fetched_at",
            sa.DateTime(timezone=True),
            nullable=False,
            server_default=sa.text("now()"),
        ),
        sa.Column(
            "search_vector",
            postgresql.TSVECTOR(),
            sa.Computed(_SEARCH_EXPRESSION, persisted=True),
            nullable=True,
        ),
        sa.Column(
            "created_at",
            sa.DateTime(timezone=True),
            nullable=False,
            server_default=sa.text("now()"),
        ),
        sa.Column(
            "updated_at",
            sa.DateTime(timezone=True),
            nullable=False,
            server_default=sa.text("now()"),
        ),
    )
    op.create_index("ix_news_documents_published_at", "news_documents", ["published_at"])
    op.create_index(
        "ix_news_documents_language_published",
        "news_documents",
        ["language", "published_at"],
    )
    op.create_index(
        "ix_news_documents_category_published",
        "news_documents",
        ["category", "published_at"],
    )
    op.create_index(
        "ix_news_documents_search",
        "news_documents",
        ["search_vector"],
        postgresql_using="gin",
    )


def downgrade() -> None:
    op.drop_index("ix_news_documents_search", table_name="news_documents")
    op.drop_index("ix_news_documents_category_published", table_name="news_documents")
    op.drop_index("ix_news_documents_language_published", table_name="news_documents")
    op.drop_index("ix_news_documents_published_at", table_name="news_documents")
    op.drop_table("news_documents")
