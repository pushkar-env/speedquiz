from datetime import datetime, timezone

from fastapi import APIRouter, Response, status
from sqlalchemy import text

from app.core.config import get_settings
from app.core.database import engine
from app.core.redis import redis_ping
from app.schemas.auth import HealthResponse, ReadyResponse

router = APIRouter(tags=["health"])
settings = get_settings()


@router.get("/health", response_model=HealthResponse)
async def health() -> HealthResponse:
    return HealthResponse(
        status="ok",
        service=settings.app_name,
        timestamp=datetime.now(timezone.utc),
    )


@router.get("/ready", response_model=ReadyResponse)
async def ready(response: Response) -> ReadyResponse:
    db_ok = False
    try:
        async with engine.connect() as conn:
            await conn.execute(text("SELECT 1"))
            db_ok = True
    except Exception:
        db_ok = False

    redis_ok = await redis_ping()
    healthy = db_ok and redis_ok

    # Readiness has to be machine-readable: a 200 tells the platform to keep
    # sending traffic to an instance that cannot reach its database.
    if not healthy:
        response.status_code = status.HTTP_503_SERVICE_UNAVAILABLE

    return ReadyResponse(
        status="ready" if healthy else "degraded",
        database=db_ok,
        redis=redis_ok,
        timestamp=datetime.now(timezone.utc),
    )
