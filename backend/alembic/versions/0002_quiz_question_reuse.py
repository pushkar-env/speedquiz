"""Drop session/question uniqueness so endless modes can reshuffle-reuse bank items."""

from typing import Sequence, Union

import sqlalchemy as sa
from alembic import op

revision: str = "0002_quiz_question_reuse"
down_revision: Union[str, None] = "0001_initial"
branch_labels: Union[str, Sequence[str], None] = None
depends_on: Union[str, Sequence[str], None] = None


def upgrade() -> None:
    op.drop_constraint("uq_quiz_question_unique", "quiz_questions", type_="unique")
    op.create_index(
        "ix_quiz_questions_session_question",
        "quiz_questions",
        ["session_id", "question_id"],
    )


def downgrade() -> None:
    op.drop_index("ix_quiz_questions_session_question", table_name="quiz_questions")
    op.create_unique_constraint(
        "uq_quiz_question_unique",
        "quiz_questions",
        ["session_id", "question_id"],
    )
