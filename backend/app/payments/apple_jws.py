"""Verification of Apple-signed JWS payloads (App Store Server API + ASSN v2).

App Store Server Notifications arrive on a public, unauthenticated endpoint —
Apple does not send a shared secret or sign the HTTP request. The *only* thing
separating a genuine "this user subscribed" notification from one an attacker
POSTs at us is the signature on the JWS body. So this module does the full job:

1. The `x5c` header carries the chain [leaf, intermediate, root], DER + base64.
2. The root must be Apple Root CA G3 — compared byte-for-byte against a copy
   the operator supplies. Without pinning, anyone can mint a self-signed cert
   claiming to be Apple and the chain would still "verify".
3. Each certificate must be signed by the next one up and be inside its
   validity window.
4. The JWS signature itself is checked against the leaf's public key.

Fetch the root once during setup:

    curl -o backend/certs/AppleRootCA-G3.cer \\
      https://www.apple.com/certificateauthority/AppleRootCA-G3.cer

Apple's root is ECDSA P-384; the leaf that signs notifications is P-256
(ES256). Both are handled.
"""

from __future__ import annotations

import base64
import binascii
import json
from datetime import datetime, timezone
from functools import lru_cache
from typing import Any, Optional

from cryptography import x509
from cryptography.exceptions import InvalidSignature
from cryptography.hazmat.primitives.asymmetric import ec, padding, rsa
from cryptography.hazmat.primitives.asymmetric.utils import encode_dss_signature
from cryptography.hazmat.primitives.hashes import SHA256, SHA384, SHA512

from app.core.config import get_settings
from app.core.logging import get_logger

logger = get_logger(__name__)


class AppleJwsError(Exception):
    """Raised when a payload is not provably signed by Apple."""


_HASHES = {"ES256": SHA256, "ES384": SHA384, "ES512": SHA512}
#: r||s halves for each ECDSA variant.
_COORD_BYTES = {"ES256": 32, "ES384": 48, "ES512": 66}


def _b64url_decode(segment: str) -> bytes:
    padding_needed = "=" * (-len(segment) % 4)
    try:
        return base64.urlsafe_b64decode(segment + padding_needed)
    except (binascii.Error, ValueError) as exc:
        raise AppleJwsError("Malformed base64url segment") from exc


def _load_root_certificates() -> list[x509.Certificate]:
    """Parse the configured Apple root CA (PEM or base64/raw DER)."""
    material = get_settings().apple_root_ca_material
    if not material.strip():
        return []

    roots: list[x509.Certificate] = []
    text = material.strip()

    if "-----BEGIN CERTIFICATE-----" in text:
        for chunk in text.split("-----END CERTIFICATE-----"):
            if "-----BEGIN CERTIFICATE-----" not in chunk:
                continue
            pem = chunk + "-----END CERTIFICATE-----\n"
            try:
                roots.append(x509.load_pem_x509_certificate(pem.encode("utf-8")))
            except ValueError:
                continue
        return roots

    # A .cer download is raw DER; config may also carry it base64-encoded.
    raw = material.encode("utf-8", errors="ignore")
    for candidate in (raw, None):
        if candidate is None:
            try:
                candidate = base64.b64decode("".join(text.split()), validate=False)
            except (binascii.Error, ValueError):
                break
        try:
            roots.append(x509.load_der_x509_certificate(candidate))
            break
        except ValueError:
            continue
    return roots


@lru_cache(maxsize=1)
def _root_fingerprints() -> frozenset[bytes]:
    return frozenset(cert.fingerprint(SHA256()) for cert in _load_root_certificates())


def apple_root_ca_available() -> bool:
    return bool(_root_fingerprints())


def reset_root_ca_cache() -> None:
    """Drop the cached root — used by tests that patch settings."""
    _root_fingerprints.cache_clear()


def _verify_cert_signature(child: x509.Certificate, issuer: x509.Certificate) -> None:
    """Check that `issuer` signed `child`."""
    public_key = issuer.public_key()
    algorithm = child.signature_hash_algorithm
    if algorithm is None:
        raise AppleJwsError("Certificate has no signature hash algorithm")

    try:
        if isinstance(public_key, ec.EllipticCurvePublicKey):
            public_key.verify(
                child.signature,
                child.tbs_certificate_bytes,
                ec.ECDSA(algorithm),
            )
        elif isinstance(public_key, rsa.RSAPublicKey):
            public_key.verify(
                child.signature,
                child.tbs_certificate_bytes,
                padding.PKCS1v15(),
                algorithm,
            )
        else:
            raise AppleJwsError("Unsupported certificate key type in Apple chain")
    except InvalidSignature as exc:
        raise AppleJwsError("Apple certificate chain signature is invalid") from exc


def _assert_within_validity(cert: x509.Certificate, now: datetime, label: str) -> None:
    not_before = cert.not_valid_before_utc
    not_after = cert.not_valid_after_utc
    if now < not_before or now > not_after:
        raise AppleJwsError(f"Apple {label} certificate is outside its validity window")


def _verify_chain(chain: list[x509.Certificate], now: datetime) -> x509.Certificate:
    """Validate [leaf, intermediate…, root] and return the leaf."""
    if len(chain) < 2:
        raise AppleJwsError("Apple JWS x5c chain is too short")

    pinned = _root_fingerprints()
    if not pinned:
        raise AppleJwsError(
            "Apple Root CA G3 is not configured — cannot authenticate App Store "
            "notifications. Set APPLE_ROOT_CA_PEM or APPLE_ROOT_CA_PATH."
        )

    root = chain[-1]
    if root.fingerprint(SHA256()) not in pinned:
        raise AppleJwsError("Apple JWS chain does not terminate at the pinned root CA")

    labels = ["leaf"] + ["intermediate"] * (len(chain) - 2) + ["root"]
    for cert, label in zip(chain, labels):
        _assert_within_validity(cert, now, label)

    for index in range(len(chain) - 1):
        _verify_cert_signature(chain[index], chain[index + 1])
    # The pinned root is self-signed; verifying it against itself confirms the
    # copy we hold has not been tampered with in transit from config.
    _verify_cert_signature(root, root)

    return chain[0]


def _verify_jws_signature(
    leaf: x509.Certificate,
    signing_input: bytes,
    signature: bytes,
    algorithm: str,
) -> None:
    hash_cls = _HASHES.get(algorithm)
    coord_len = _COORD_BYTES.get(algorithm)
    if hash_cls is None or coord_len is None:
        raise AppleJwsError(f"Unsupported Apple JWS algorithm {algorithm!r}")

    public_key = leaf.public_key()
    if not isinstance(public_key, ec.EllipticCurvePublicKey):
        raise AppleJwsError("Apple JWS leaf certificate is not an EC key")

    if len(signature) != coord_len * 2:
        raise AppleJwsError("Apple JWS signature has the wrong length")

    r = int.from_bytes(signature[:coord_len], "big")
    s = int.from_bytes(signature[coord_len:], "big")

    try:
        public_key.verify(
            encode_dss_signature(r, s),
            signing_input,
            ec.ECDSA(hash_cls()),
        )
    except InvalidSignature as exc:
        raise AppleJwsError("Apple JWS signature does not verify") from exc


def verify_and_decode(jws: str, *, now: Optional[datetime] = None) -> dict[str, Any]:
    """Return the payload of `jws`, or raise `AppleJwsError`.

    Every failure path raises. There is deliberately no "decode without
    verifying" fallback: a caller that could not prove Apple signed a payload
    must not act on it.
    """
    if not jws or not isinstance(jws, str):
        raise AppleJwsError("Missing Apple JWS payload")

    parts = jws.split(".")
    if len(parts) != 3:
        raise AppleJwsError("Apple JWS must have three segments")

    header_segment, payload_segment, signature_segment = parts

    try:
        header = json.loads(_b64url_decode(header_segment))
    except (ValueError, json.JSONDecodeError) as exc:
        raise AppleJwsError("Apple JWS header is not JSON") from exc
    if not isinstance(header, dict):
        raise AppleJwsError("Apple JWS header must be an object")

    algorithm = str(header.get("alg") or "")
    if algorithm not in _HASHES:
        # Rejects alg=none and any algorithm confusion attempt outright.
        raise AppleJwsError(f"Unexpected Apple JWS algorithm {algorithm!r}")

    x5c = header.get("x5c")
    if not isinstance(x5c, list) or not x5c:
        raise AppleJwsError("Apple JWS header is missing the x5c chain")

    chain: list[x509.Certificate] = []
    for entry in x5c:
        if not isinstance(entry, str):
            raise AppleJwsError("Apple JWS x5c entries must be strings")
        try:
            chain.append(x509.load_der_x509_certificate(base64.b64decode(entry)))
        except (ValueError, binascii.Error) as exc:
            raise AppleJwsError("Apple JWS x5c entry is not a DER certificate") from exc

    moment = now or datetime.now(timezone.utc)
    leaf = _verify_chain(chain, moment)

    _verify_jws_signature(
        leaf,
        f"{header_segment}.{payload_segment}".encode("ascii"),
        _b64url_decode(signature_segment),
        algorithm,
    )

    try:
        payload = json.loads(_b64url_decode(payload_segment))
    except (ValueError, json.JSONDecodeError) as exc:
        raise AppleJwsError("Apple JWS payload is not JSON") from exc
    if not isinstance(payload, dict):
        raise AppleJwsError("Apple JWS payload must be an object")

    return payload


def decode_unverified(jws: str) -> dict[str, Any]:
    """Read a JWS payload *without* checking the signature.

    Only legitimate for values pulled from an authenticated App Store Server
    API response over TLS, where Apple's identity is already established by the
    connection. Never use this on a webhook body.
    """
    parts = (jws or "").split(".")
    if len(parts) != 3:
        raise AppleJwsError("Apple JWS must have three segments")
    try:
        payload = json.loads(_b64url_decode(parts[1]))
    except (ValueError, json.JSONDecodeError) as exc:
        raise AppleJwsError("Apple JWS payload is not JSON") from exc
    if not isinstance(payload, dict):
        raise AppleJwsError("Apple JWS payload must be an object")
    return payload
