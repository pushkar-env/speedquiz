from datetime import datetime, timezone

from fastapi import HTTPException, Request, status
from fastapi.responses import JSONResponse
from starlette.middleware.base import BaseHTTPMiddleware

from app.core.logging import get_logger, new_request_id, request_id_ctx

logger = get_logger(__name__)


class RequestIdMiddleware(BaseHTTPMiddleware):
    async def dispatch(self, request: Request, call_next):
        request_id = request.headers.get("X-Request-ID") or new_request_id()
        token = request_id_ctx.set(request_id)
        try:
            response = await call_next(request)
            response.headers["X-Request-ID"] = request_id
            return response
        finally:
            request_id_ctx.reset(token)


async def http_exception_handler(request: Request, exc: HTTPException) -> JSONResponse:
    # Keep FastAPI-style `detail` for clients, plus structured `error` envelope.
    return JSONResponse(
        status_code=exc.status_code,
        content={
            "detail": exc.detail,
            "error": {
                "message": exc.detail,
                "status_code": exc.status_code,
                "path": str(request.url.path),
                "timestamp": datetime.now(timezone.utc).isoformat(),
                "request_id": request_id_ctx.get(),
            },
        },
    )


async def unhandled_exception_handler(request: Request, exc: Exception) -> JSONResponse:
    logger.exception("unhandled_exception", path=str(request.url.path), error=str(exc))
    return JSONResponse(
        status_code=status.HTTP_500_INTERNAL_SERVER_ERROR,
        content={
            "error": {
                "message": "Internal server error",
                "status_code": 500,
                "path": str(request.url.path),
                "timestamp": datetime.now(timezone.utc).isoformat(),
                "request_id": request_id_ctx.get(),
            }
        },
    )
