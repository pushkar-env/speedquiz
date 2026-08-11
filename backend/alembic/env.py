from logging.config import fileConfig

from alembic import context
from sqlalchemy import engine_from_config, pool, text

from app.core.config import get_settings
from app.core.database import AdvisoryLock, Base
from app import models  # noqa: F401 — register models

config = context.config
settings = get_settings()
config.set_main_option("sqlalchemy.url", settings.database_url_sync)

if config.config_file_name is not None:
    fileConfig(config.config_file_name)

target_metadata = Base.metadata


def run_migrations_offline() -> None:
    url = config.get_main_option("sqlalchemy.url")
    context.configure(
        url=url,
        target_metadata=target_metadata,
        literal_binds=True,
        dialect_opts={"paramstyle": "named"},
        compare_type=True,
    )
    with context.begin_transaction():
        context.run_migrations()


def run_migrations_online() -> None:
    connectable = engine_from_config(
        config.get_section(config.config_ini_section, {}),
        prefix="sqlalchemy.",
        poolclass=pool.NullPool,
    )
    with connectable.connect() as connection:
        # Every API container runs `alembic upgrade head` on boot. With more
        # than one replica those runs start simultaneously, and Alembic takes
        # no lock of its own — so serialise them here. Latecomers block until
        # the leader finishes, then find themselves already at head and no-op.
        connection.execute(
            text("SELECT pg_advisory_lock(:key)"), {"key": AdvisoryLock.MIGRATIONS}
        )
        # End the implicit transaction; the advisory lock is session-scoped
        # and survives the commit.
        connection.commit()
        try:
            context.configure(
                connection=connection,
                target_metadata=target_metadata,
                compare_type=True,
            )
            with context.begin_transaction():
                context.run_migrations()
        finally:
            connection.execute(
                text("SELECT pg_advisory_unlock(:key)"),
                {"key": AdvisoryLock.MIGRATIONS},
            )
            connection.commit()


if context.is_offline_mode():
    run_migrations_offline()
else:
    run_migrations_online()
