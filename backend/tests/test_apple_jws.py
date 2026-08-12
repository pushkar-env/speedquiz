"""Apple notification signature verification.

The App Store notification endpoint is public and unauthenticated at the HTTP
layer — the JWS signature is the *only* thing standing between a genuine
"subscription renewed" event and one an attacker POSTs. These tests build real
certificate chains so the failure modes are exercised for real rather than
mocked away.
"""

from __future__ import annotations

import base64
import json
from datetime import datetime, timedelta, timezone
from types import SimpleNamespace
from unittest.mock import patch

import pytest
from cryptography import x509
from cryptography.hazmat.primitives import hashes, serialization
from cryptography.hazmat.primitives.asymmetric import ec
from cryptography.hazmat.primitives.asymmetric.utils import decode_dss_signature
from cryptography.x509.oid import NameOID

from app.payments import apple_jws
from app.payments.apple_jws import AppleJwsError, verify_and_decode

NOW = datetime(2026, 8, 12, 12, 0, tzinfo=timezone.utc)


def _keypair():
    return ec.generate_private_key(ec.SECP256R1())


def _name(common_name: str) -> x509.Name:
    return x509.Name([x509.NameAttribute(NameOID.COMMON_NAME, common_name)])


def _self_signed(key, common_name: str) -> x509.Certificate:
    subject = _name(common_name)
    return (
        x509.CertificateBuilder()
        .subject_name(subject)
        .issuer_name(subject)
        .public_key(key.public_key())
        .serial_number(x509.random_serial_number())
        .not_valid_before(NOW - timedelta(days=365))
        .not_valid_after(NOW + timedelta(days=365))
        .add_extension(x509.BasicConstraints(ca=True, path_length=None), critical=True)
        .sign(key, hashes.SHA256())
    )


def _issued_by(issuer_cert, issuer_key, subject_key, common_name: str, *, ca: bool):
    return (
        x509.CertificateBuilder()
        .subject_name(_name(common_name))
        .issuer_name(issuer_cert.subject)
        .public_key(subject_key.public_key())
        .serial_number(x509.random_serial_number())
        .not_valid_before(NOW - timedelta(days=30))
        .not_valid_after(NOW + timedelta(days=30))
        .add_extension(x509.BasicConstraints(ca=ca, path_length=None), critical=True)
        .sign(issuer_key, hashes.SHA256())
    )


def _der_b64(cert: x509.Certificate) -> str:
    return base64.b64encode(cert.public_bytes(serialization.Encoding.DER)).decode()


def _pem(cert: x509.Certificate) -> str:
    return cert.public_bytes(serialization.Encoding.PEM).decode()


def _b64url(data: bytes) -> str:
    return base64.urlsafe_b64encode(data).rstrip(b"=").decode()


def _sign_jws(payload: dict, leaf_key, chain: list[x509.Certificate]) -> str:
    header = {"alg": "ES256", "x5c": [_der_b64(c) for c in chain]}
    header_segment = _b64url(json.dumps(header).encode())
    payload_segment = _b64url(json.dumps(payload).encode())
    signing_input = f"{header_segment}.{payload_segment}".encode("ascii")

    der_signature = leaf_key.sign(signing_input, ec.ECDSA(hashes.SHA256()))
    r, s = decode_dss_signature(der_signature)
    raw_signature = r.to_bytes(32, "big") + s.to_bytes(32, "big")

    return f"{header_segment}.{payload_segment}.{_b64url(raw_signature)}"


class Chain:
    """A full root → intermediate → leaf chain plus a signing helper."""

    def __init__(self, root_name: str = "Apple Root CA - G3"):
        self.root_key = _keypair()
        self.root = _self_signed(self.root_key, root_name)
        self.intermediate_key = _keypair()
        self.intermediate = _issued_by(
            self.root, self.root_key, self.intermediate_key, "Apple WWDR", ca=True
        )
        self.leaf_key = _keypair()
        self.leaf = _issued_by(
            self.intermediate,
            self.intermediate_key,
            self.leaf_key,
            "prod.itunes.apple.com",
            ca=False,
        )

    @property
    def certs(self) -> list[x509.Certificate]:
        return [self.leaf, self.intermediate, self.root]

    def sign(self, payload: dict) -> str:
        return _sign_jws(payload, self.leaf_key, self.certs)


@pytest.fixture(autouse=True)
def _clear_root_cache():
    apple_jws.reset_root_ca_cache()
    yield
    apple_jws.reset_root_ca_cache()


def _with_root(cert: x509.Certificate | None):
    """Patch settings so the pinned root is `cert` (or nothing)."""
    return patch(
        "app.payments.apple_jws.get_settings",
        return_value=SimpleNamespace(
            apple_root_ca_material=_pem(cert) if cert is not None else ""
        ),
    )


def test_genuine_notification_verifies():
    chain = Chain()
    jws = chain.sign({"notificationType": "DID_RENEW", "notificationUUID": "abc"})

    with _with_root(chain.root):
        payload = verify_and_decode(jws, now=NOW)

    assert payload["notificationType"] == "DID_RENEW"
    assert payload["notificationUUID"] == "abc"


def test_forged_chain_from_a_different_root_is_rejected():
    """The attack this whole module exists to stop.

    An attacker can trivially mint a self-signed CA whose subject reads
    "Apple Root CA - G3" and build a valid-looking chain under it. Only
    pinning the real root's bytes catches it.
    """
    attacker = Chain()
    genuine = Chain()
    jws = attacker.sign({"notificationType": "SUBSCRIBED"})

    with _with_root(genuine.root):
        with pytest.raises(AppleJwsError, match="pinned root"):
            verify_and_decode(jws, now=NOW)


def test_tampered_payload_is_rejected():
    """Swap the payload for a 'you are premium forever' claim."""
    chain = Chain()
    jws = chain.sign({"notificationType": "DID_RENEW"})
    header, _, signature = jws.split(".")
    forged_payload = _b64url(json.dumps({"notificationType": "SUBSCRIBED"}).encode())

    with _with_root(chain.root):
        with pytest.raises(AppleJwsError, match="signature does not verify"):
            verify_and_decode(f"{header}.{forged_payload}.{signature}", now=NOW)


def test_alg_none_is_rejected():
    chain = Chain()
    header = _b64url(
        json.dumps({"alg": "none", "x5c": [_der_b64(c) for c in chain.certs]}).encode()
    )
    payload = _b64url(json.dumps({"notificationType": "SUBSCRIBED"}).encode())

    with _with_root(chain.root):
        with pytest.raises(AppleJwsError, match="algorithm"):
            verify_and_decode(f"{header}.{payload}.", now=NOW)


def test_missing_x5c_is_rejected():
    header = _b64url(json.dumps({"alg": "ES256"}).encode())
    payload = _b64url(json.dumps({"notificationType": "SUBSCRIBED"}).encode())
    chain = Chain()

    with _with_root(chain.root):
        with pytest.raises(AppleJwsError, match="x5c"):
            verify_and_decode(f"{header}.{payload}.sig", now=NOW)


def test_unconfigured_root_fails_closed():
    """No pinned root means no way to authenticate — refuse, never accept."""
    chain = Chain()
    jws = chain.sign({"notificationType": "DID_RENEW"})

    with _with_root(None):
        with pytest.raises(AppleJwsError, match="not configured"):
            verify_and_decode(jws, now=NOW)


def test_expired_leaf_certificate_is_rejected():
    chain = Chain()
    jws = chain.sign({"notificationType": "DID_RENEW"})

    with _with_root(chain.root):
        with pytest.raises(AppleJwsError, match="validity window"):
            verify_and_decode(jws, now=NOW + timedelta(days=90))


def test_broken_intermediate_link_is_rejected():
    """Leaf signed by a key that the intermediate does not vouch for."""
    chain = Chain()
    rogue_key = _keypair()
    rogue_leaf = _issued_by(
        chain.intermediate, rogue_key, _keypair(), "rogue.apple.com", ca=False
    )
    jws = _sign_jws(
        {"notificationType": "DID_RENEW"},
        chain.leaf_key,
        [rogue_leaf, chain.intermediate, chain.root],
    )

    with _with_root(chain.root):
        with pytest.raises(AppleJwsError):
            verify_and_decode(jws, now=NOW)


def test_root_accepted_as_raw_der_bytes():
    """A .cer downloaded from Apple is DER, not PEM."""
    chain = Chain()
    jws = chain.sign({"notificationType": "DID_RENEW"})
    der_b64 = base64.b64encode(
        chain.root.public_bytes(serialization.Encoding.DER)
    ).decode()

    with patch(
        "app.payments.apple_jws.get_settings",
        return_value=SimpleNamespace(apple_root_ca_material=der_b64),
    ):
        assert verify_and_decode(jws, now=NOW)["notificationType"] == "DID_RENEW"


def test_malformed_jws_is_rejected():
    chain = Chain()
    with _with_root(chain.root):
        for bad in ("", "not-a-jws", "a.b", "a.b.c.d"):
            with pytest.raises(AppleJwsError):
                verify_and_decode(bad, now=NOW)
