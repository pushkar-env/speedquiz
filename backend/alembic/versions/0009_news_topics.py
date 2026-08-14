"""Mark rolling current-affairs topics so the generic top-up skips them.

Separate from ``is_custom``: a news topic is curated, not player-created, and
the two need different treatment. Custom topics are one-shot banks nobody grows;
news topics are grown daily, but only by the grounded builder, never by the
watermark scan that would refill them from the model's memory.

Every existing topic lands ``false``, which is what all of them are.
"""

from typing import Sequence, Union

import sqlalchemy as sa
from alembic import op

revision: str = "0009_news_topics"
down_revision: Union[str, None] = "0008_news_corpus"
branch_labels: Union[str, Sequence[str], None] = None
depends_on: Union[str, Sequence[str], None] = None


def upgrade() -> None:
    op.add_column(
        "topics",
        sa.Column("is_news", sa.Boolean(), nullable=False, server_default=sa.false()),
    )


def downgrade() -> None:
    op.drop_column("topics", "is_news")
