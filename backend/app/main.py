from contextlib import asynccontextmanager

from fastapi import FastAPI, HTTPException
from fastapi.middleware.cors import CORSMiddleware

from app import __version__
from app.api.v1 import api_router
from app.api.v1.health import router as health_router
from app.core.config import get_settings
from app.core.exceptions import (
    RequestIdMiddleware,
    http_exception_handler,
    unhandled_exception_handler,
)
from app.core.logging import configure_logging, get_logger
from app.core.redis import close_redis, init_redis
from app.services.seed import seed_reference_data
from app.services.question_bank import seed_question_bank

settings = get_settings()
logger = get_logger(__name__)


@asynccontextmanager
async def lifespan(_: FastAPI):
    configure_logging(settings.log_level)
    logger.info("startup", app=settings.app_name, env=settings.app_env, version=__version__)
    await init_redis()
    try:
        await seed_reference_data()
        await seed_question_bank()
    except Exception as exc:
        logger.warning("seed_skipped", error=str(exc))
    yield
    await close_redis()
    logger.info("shutdown")


def create_app() -> FastAPI:
    app = FastAPI(
        title=settings.app_name,
        version=__version__,
        docs_url="/docs",
        redoc_url="/redoc",
        openapi_url="/openapi.json",
        lifespan=lifespan,
    )

    app.add_middleware(
        CORSMiddleware,
        allow_origins=settings.cors_origin_list,
        allow_credentials=True,
        allow_methods=["*"],
        allow_headers=["*"],
    )
    app.add_middleware(RequestIdMiddleware)

    app.add_exception_handler(HTTPException, http_exception_handler)
    app.add_exception_handler(Exception, unhandled_exception_handler)

    # Ops probes at root; versioned API under /api/v1
    app.include_router(health_router)
    app.include_router(api_router, prefix=settings.api_prefix)

    return app


app = create_app()
