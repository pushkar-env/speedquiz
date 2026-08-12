"""Real store subscriptions: lifecycle columns on subscriptions + billing_events.

Turns the single-row "someone bought the unlock" record into a mirror of the
store's own subscription state, and adds an append-only notification log that
makes webhook delivery idempotent.

The subscription_status enum gains on_hold / paused / pending / revoked. Rather
than ALTER TYPE ... ADD VALUE (which has transaction-block caveats and cannot
be reversed), the type is swapped wholesale, which stays inside the migration
transaction and downgrades cleanly.
"""

from typing import Sequence, Union

import sqlalchemy as sa
from alembic import op
from sqlalchemy.dialects import postgresql

revision: str = "0004_subscriptions_v2"
down_revision: Union[str, None] = "0003_analytics_events"
branch_labels: Union[str, Sequence[str], None] = None
depends_on: Union[str, Sequence[str], None] = None

_OLD_STATUSES = ("none", "active", "grace", "expired", "cancelled")
_NEW_STATUSES = (
    "none",
    "active",
    "grace",
    "on_hold",
    "paused",
    "pending",
    "cancelled",
    "expired",
    "revoked",
)


def _swap_status_enum(values: Sequence[str]) -> None:
    """Replace the subscription_status type with one holding `values`.

    Any row whose status is not in the new set is coerced to 'expired' first,
    so the cast cannot fail partway and abort the migration.
    """
    allowed = ", ".join(f"'{v}'" for v in values)
    op.execute(
        f"UPDATE subscriptions SET status = 'expired' "
        f"WHERE status::text NOT IN ({allowed})"
    )
    op.execute("ALTER TYPE subscription_status RENAME TO subscription_status_old")
    postgresql.ENUM(*values, name="subscription_status").create(
        op.get_bind(), checkfirst=False
    )
    op.execute(
        "ALTER TABLE subscriptions ALTER COLUMN status TYPE subscription_status "
        "USING status::text::subscription_status"
    )
    op.execute("DROP TYPE subscription_status_old")


def upgrade() -> None:
    _swap_status_enum(_NEW_STATUSES)

    op.add_column("subscriptions", sa.Column("plan_code", sa.String(32)))
    # Text, not String(255): on Play the store identity *is* a purchase token,
    # and those routinely run past 255 characters.
    op.add_column("subscriptions", sa.Column("store_subscription_id", sa.Text()))
    op.add_column("subscriptions", sa.Column("latest_transaction_id", sa.String(255)))
    op.add_column("subscriptions", sa.Column("purchase_token", sa.Text()))
    op.add_column("subscriptions", sa.Column("started_at", sa.DateTime(timezone=True)))
    op.add_column(
        "subscriptions", sa.Column("current_period_start", sa.DateTime(timezone=True))
    )
    op.add_column("subscriptions", sa.Column("grace_until", sa.DateTime(timezone=True)))
    op.add_column(
        "subscriptions", sa.Column("auto_resume_at", sa.DateTime(timezone=True))
    )
    op.add_column("subscriptions", sa.Column("cancelled_at", sa.DateTime(timezone=True)))
    op.add_column("subscriptions", sa.Column("revoked_at", sa.DateTime(timezone=True)))
    op.add_column(
        "subscriptions",
        sa.Column(
            "auto_renewing", sa.Boolean(), nullable=False, server_default=sa.text("true")
        ),
    )
    op.add_column("subscriptions", sa.Column("cancel_reason", sa.String(64)))
    op.add_column(
        "subscriptions",
        sa.Column(
            "is_intro_offer",
            sa.Boolean(),
            nullable=False,
            server_default=sa.text("false"),
        ),
    )
    op.add_column("subscriptions", sa.Column("offer_id", sa.String(128)))
    op.add_column("subscriptions", sa.Column("country", sa.String(8)))
    op.add_column("subscriptions", sa.Column("currency", sa.String(8)))
    op.add_column("subscriptions", sa.Column("price_micros", sa.BigInteger()))
    op.add_column("subscriptions", sa.Column("environment", sa.String(16)))
    op.add_column(
        "subscriptions",
        sa.Column(
            "is_test", sa.Boolean(), nullable=False, server_default=sa.text("false")
        ),
    )
    op.add_column(
        "subscriptions", sa.Column("last_verified_at", sa.DateTime(timezone=True))
    )
    op.add_column(
        "subscriptions",
        sa.Column(
            "raw", postgresql.JSONB(), nullable=False, server_default=sa.text("'{}'::jsonb")
        ),
    )

    # Pre-subscription rows were all the one-time unlock. Give them a store
    # identity (falling back to the primary key when the old row somehow has no
    # transaction id) and mark them lifetime so they keep resolving to premium.
    op.execute(
        "UPDATE subscriptions "
        "SET store_subscription_id = COALESCE(original_transaction_id, id::text), "
        "    plan_code = 'legacy_lifetime', "
        "    platform = COALESCE(platform, 'android'), "
        "    auto_renewing = false"
    )

    op.alter_column(
        "subscriptions", "store_subscription_id", nullable=False, existing_type=sa.Text()
    )
    op.alter_column(
        "subscriptions",
        "platform",
        type_=sa.String(16),
        existing_type=sa.String(32),
        nullable=False,
        server_default="android",
    )

    # The store identity, not the Apple-specific transaction id, is what must
    # be unique now — Play has no equivalent of originalTransactionId.
    op.execute(
        "ALTER TABLE subscriptions "
        "DROP CONSTRAINT IF EXISTS subscriptions_original_transaction_id_key"
    )
    op.create_index(
        "ix_subscriptions_original_transaction_id",
        "subscriptions",
        ["original_transaction_id"],
    )
    op.create_unique_constraint(
        "uq_subscription_store_identity",
        "subscriptions",
        ["platform", "store_subscription_id"],
    )
    op.create_index(
        "ix_subscriptions_user_status", "subscriptions", ["user_id", "status"]
    )
    op.create_index(
        "ix_subscriptions_status_expires", "subscriptions", ["status", "expires_at"]
    )

    op.create_table(
        "billing_events",
        sa.Column("id", postgresql.UUID(as_uuid=True), primary_key=True),
        sa.Column("provider", sa.String(16), nullable=False),
        sa.Column("event_id", sa.String(255), nullable=False),
        sa.Column("notification_type", sa.String(64)),
        sa.Column("subtype", sa.String(64)),
        sa.Column("store_subscription_id", sa.Text()),
        sa.Column("product_id", sa.String(128)),
        sa.Column(
            "user_id",
            postgresql.UUID(as_uuid=True),
            sa.ForeignKey("users.id", ondelete="SET NULL"),
        ),
        sa.Column(
            "subscription_id",
            postgresql.UUID(as_uuid=True),
            sa.ForeignKey("subscriptions.id", ondelete="SET NULL"),
        ),
        sa.Column(
            "payload",
            postgresql.JSONB(),
            nullable=False,
            server_default=sa.text("'{}'::jsonb"),
        ),
        sa.Column("processed_at", sa.DateTime(timezone=True)),
        sa.Column("error", sa.Text()),
        sa.Column(
            "created_at",
            sa.DateTime(timezone=True),
            server_default=sa.text("now()"),
            nullable=False,
        ),
        sa.UniqueConstraint("provider", "event_id", name="uq_billing_event_provider_id"),
    )
    op.create_index(
        "ix_billing_events_store_subscription", "billing_events", ["store_subscription_id"]
    )
    op.create_index("ix_billing_events_created", "billing_events", ["created_at"])


def downgrade() -> None:
    op.drop_index("ix_billing_events_created", table_name="billing_events")
    op.drop_index("ix_billing_events_store_subscription", table_name="billing_events")
    op.drop_table("billing_events")

    op.drop_index("ix_subscriptions_status_expires", table_name="subscriptions")
    op.drop_index("ix_subscriptions_user_status", table_name="subscriptions")
    op.drop_constraint(
        "uq_subscription_store_identity", "subscriptions", type_="unique"
    )
    op.drop_index("ix_subscriptions_original_transaction_id", table_name="subscriptions")
    op.create_unique_constraint(
        "subscriptions_original_transaction_id_key",
        "subscriptions",
        ["original_transaction_id"],
    )

    op.alter_column(
        "subscriptions",
        "platform",
        type_=sa.String(32),
        existing_type=sa.String(16),
        nullable=True,
        server_default=None,
    )

    for column in (
        "raw",
        "last_verified_at",
        "is_test",
        "environment",
        "price_micros",
        "currency",
        "country",
        "offer_id",
        "is_intro_offer",
        "cancel_reason",
        "auto_renewing",
        "revoked_at",
        "cancelled_at",
        "auto_resume_at",
        "grace_until",
        "current_period_start",
        "started_at",
        "purchase_token",
        "latest_transaction_id",
        "store_subscription_id",
        "plan_code",
    ):
        op.drop_column("subscriptions", column)

    _swap_status_enum(_OLD_STATUSES)
