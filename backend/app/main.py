from contextlib import asynccontextmanager

from fastapi import FastAPI, HTTPException
from fastapi.middleware.cors import CORSMiddleware

from app import __version__
from app.api.v1 import api_router
from app.api.v1.health import router as health_router
from app.api.share_landing import router as share_landing_router
from app.api.well_known import router as well_known_router
from app.core.config import get_settings
from app.core.exceptions import (
    RequestIdMiddleware,
    http_exception_handler,
    unhandled_exception_handler,
)
from app.core.database import AdvisoryLock, advisory_lock
from app.core.logging import configure_logging, get_logger
from app.core.redis import close_redis, init_redis
from app.services.seed import seed_reference_data
from app.services.question_bank import seed_question_bank

settings = get_settings()
logger = get_logger(__name__)


async def _seed_once() -> None:
    """Run startup seeding on exactly one replica.

    Seeding is one-shot reference data. Without a lock, replicas booting
    together race each other into unique-constraint failures — which the old
    blanket `except` then swallowed, leaving the database unseeded and the
    logs quiet about it.
    """
    try:
        async with advisory_lock(AdvisoryLock.SEED) as acquired:
            if not acquired:
                logger.info("seed_skipped_lock_held_by_another_replica")
                return
            await seed_reference_data()
            await seed_question_bank()
    except Exception as exc:  # noqa: BLE001 — never block the API from serving
        logger.exception("seed_failed", error=str(exc))


@asynccontextmanager
async def lifespan(_: FastAPI):
    configure_logging(settings.log_level)
    logger.info("startup", app=settings.app_name, env=settings.app_env, version=__version__)
    await init_redis()
    await _seed_once()
    yield
    await close_redis()
    logger.info("shutdown")


def create_app() -> FastAPI:
    # The schema is a map of the API surface; don't publish it by default in
    # production. Set ENABLE_DOCS_IN_PRODUCTION=true to opt back in.
    docs = settings.docs_enabled

    app = FastAPI(
        title=settings.app_name,
        version=__version__,
        docs_url="/docs" if docs else None,
        redoc_url="/redoc" if docs else None,
        openapi_url="/openapi.json" if docs else None,
        lifespan=lifespan,
    )

    origins = settings.cors_origin_list
    app.add_middleware(
        CORSMiddleware,
        allow_origins=origins,
        # `Access-Control-Allow-Origin: *` with credentials is rejected by
        # every browser, so the two are mutually exclusive. Mobile clients do
        # not use CORS at all; this only matters if a web client is added.
        allow_credentials="*" not in origins,
        allow_methods=["*"],
        allow_headers=["*"],
    )
    app.add_middleware(RequestIdMiddleware)

    app.add_exception_handler(HTTPException, http_exception_handler)
    app.add_exception_handler(Exception, unhandled_exception_handler)

    # Ops probes at root; versioned API under /api/v1
    app.include_router(health_router)
    app.include_router(well_known_router)
    app.include_router(share_landing_router)
    app.include_router(api_router, prefix=settings.api_prefix)

    return app


app = create_app()
