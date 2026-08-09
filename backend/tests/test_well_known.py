"""Well-known App Links / Universal Links association endpoints."""

from types import SimpleNamespace
from unittest.mock import patch

import pytest
from httpx import ASGITransport, AsyncClient

from app.api.well_known import build_aasa_payload, build_assetlinks_payload
from app.main import create_app


def _settings(**overrides):
    base = SimpleNamespace(
        app_link_android_package="com.example.mobile",
        app_link_android_sha256_cert_fingerprints="",
        app_link_ios_app_id="",
    )
    for key, value in overrides.items():
        setattr(base, key, value)
    return base


def test_build_assetlinks_shape():
    payload = build_assetlinks_payload(
        package_name="com.example.mobile",
        fingerprints=["AA:BB:CC", "DD:EE:FF"],
    )
    assert len(payload) == 1
    assert payload[0]["relation"] == ["delegate_permission/common.handle_all_urls"]
    target = payload[0]["target"]
    assert target["namespace"] == "android_app"
    assert target["package_name"] == "com.example.mobile"
    assert target["sha256_cert_fingerprints"] == ["AA:BB:CC", "DD:EE:FF"]


def test_build_aasa_paths():
    payload = build_aasa_payload(app_id="TEAMID.com.example.mobile")
    details = payload["applinks"]["details"]
    assert details[0]["appID"] == "TEAMID.com.example.mobile"
    assert "/r/*" in details[0]["paths"]
    assert "/share/results/*" in details[0]["paths"]


@pytest.mark.asyncio
async def test_assetlinks_503_when_fingerprints_unset():
    app = create_app()
    transport = ASGITransport(app=app)
    async with AsyncClient(transport=transport, base_url="http://test") as client:
        with patch("app.api.well_known.get_settings", return_value=_settings()):
            response = await client.get("/.well-known/assetlinks.json")
    assert response.status_code == 503
    body = response.json()
    assert "APP_LINK_ANDROID_SHA256_CERT_FINGERPRINTS" in (
        body.get("detail") or body.get("error", {}).get("message", "")
    )


@pytest.mark.asyncio
async def test_assetlinks_200_when_configured():
    app = create_app()
    transport = ASGITransport(app=app)
    async with AsyncClient(transport=transport, base_url="http://test") as client:
        with patch(
            "app.api.well_known.get_settings",
            return_value=_settings(
                app_link_android_sha256_cert_fingerprints="AA:BB:CC, DD:EE:FF",
            ),
        ):
            response = await client.get("/.well-known/assetlinks.json")
    assert response.status_code == 200
    assert "application/json" in response.headers.get("content-type", "")
    data = response.json()
    assert data[0]["target"]["package_name"] == "com.example.mobile"
    assert data[0]["target"]["sha256_cert_fingerprints"] == ["AA:BB:CC", "DD:EE:FF"]


@pytest.mark.asyncio
async def test_aasa_503_when_ios_app_id_unset():
    app = create_app()
    transport = ASGITransport(app=app)
    async with AsyncClient(transport=transport, base_url="http://test") as client:
        with patch("app.api.well_known.get_settings", return_value=_settings()):
            response = await client.get("/.well-known/apple-app-site-association")
    assert response.status_code == 503


@pytest.mark.asyncio
async def test_aasa_200_includes_r_paths():
    app = create_app()
    transport = ASGITransport(app=app)
    async with AsyncClient(transport=transport, base_url="http://test") as client:
        with patch(
            "app.api.well_known.get_settings",
            return_value=_settings(app_link_ios_app_id="TEAMID.com.example.mobile"),
        ):
            response = await client.get("/.well-known/apple-app-site-association")
    assert response.status_code == 200
    assert "application/json" in response.headers.get("content-type", "")
    paths = response.json()["applinks"]["details"][0]["paths"]
    assert "/r/*" in paths
