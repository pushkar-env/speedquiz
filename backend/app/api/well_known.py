"""Digital Asset Links + Apple App Site Association for HTTPS app opens."""

from __future__ import annotations

from fastapi import APIRouter, HTTPException, status
from fastapi.responses import JSONResponse

from app.core.config import get_settings

router = APIRouter(tags=["well-known"])


def _android_fingerprints(raw: str) -> list[str]:
    text = (raw or "").strip()
    if not text:
        return []
    return [part.strip() for part in text.split(",") if part.strip()]


def build_assetlinks_payload(
    *,
    package_name: str,
    fingerprints: list[str],
) -> list[dict]:
    return [
        {
            "relation": ["delegate_permission/common.handle_all_urls"],
            "target": {
                "namespace": "android_app",
                "package_name": package_name,
                "sha256_cert_fingerprints": fingerprints,
            },
        }
    ]


def build_aasa_payload(*, app_id: str) -> dict:
    return {
        "applinks": {
            "apps": [],
            "details": [
                {
                    "appID": app_id,
                    # `/q/*` is a custom-quiz share code. It sits alongside
                    # the result paths rather than replacing them: both are
                    # links a player sends to a friend, and an install that
                    # verifies one must verify the other.
                    "paths": ["/r/*", "/share/results/*", "/q/*"],
                }
            ],
        }
    }


@router.get("/.well-known/assetlinks.json")
async def android_asset_links() -> JSONResponse:
    settings = get_settings()
    fingerprints = _android_fingerprints(settings.app_link_android_sha256_cert_fingerprints)
    if not fingerprints:
        raise HTTPException(
            status_code=status.HTTP_503_SERVICE_UNAVAILABLE,
            detail=(
                "Android App Links not configured — set "
                "APP_LINK_ANDROID_SHA256_CERT_FINGERPRINTS"
            ),
        )
    payload = build_assetlinks_payload(
        package_name=settings.app_link_android_package,
        fingerprints=fingerprints,
    )
    return JSONResponse(content=payload, media_type="application/json")


@router.get("/.well-known/apple-app-site-association")
async def apple_app_site_association() -> JSONResponse:
    settings = get_settings()
    app_id = (settings.app_link_ios_app_id or "").strip()
    if not app_id:
        raise HTTPException(
            status_code=status.HTTP_503_SERVICE_UNAVAILABLE,
            detail="iOS Universal Links not configured — set APP_LINK_IOS_APP_ID",
        )
    return JSONResponse(
        content=build_aasa_payload(app_id=app_id),
        media_type="application/json",
    )
