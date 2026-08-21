"""Where figure files go, and what URL the app fetches them from.

Two backends behind one interface.

* ``local`` -- copy into the backend's static directory. Right for development
  and small deployments; the API serves the bytes itself.
* ``r2`` -- Cloudflare R2 (or any S3-compatible bucket). Right for production,
  because egress is the whole cost model once figures are being pulled by a
  large number of users, and R2 charges nothing for it.

Either way the object key is the content hash, so a figure is immutable by
construction and can be cached forever. Correcting one produces a new key
rather than invalidating an old one.
"""

from __future__ import annotations

import os
import shutil
from abc import ABC, abstractmethod
from pathlib import Path
from typing import Optional

#: A year, and immutable: the key is the content hash, so the bytes behind a
#: URL can never change.
CACHE_CONTROL = "public, max-age=31536000, immutable"


class AssetStore(ABC):
    @abstractmethod
    def put(self, checksum: str, variant: str, data: bytes) -> str:
        """Store one variant and return the URL the app should fetch."""

    @abstractmethod
    def describe(self) -> str:
        ...


class LocalAssetStore(AssetStore):
    """Copy into a directory the API serves as static files."""

    def __init__(self, root: Path, base_url: str) -> None:
        self.root = root
        self.base_url = base_url.rstrip("/")
        self.root.mkdir(parents=True, exist_ok=True)
        self.written = 0
        self.skipped = 0

    def put(self, checksum: str, variant: str, data: bytes) -> str:
        name = f"{checksum}.{variant}.png"
        # Fan out by the first two hex characters: a few thousand files in one
        # directory is slow to enumerate on Windows and on some network mounts.
        target = self.root / checksum[:2] / name
        target.parent.mkdir(parents=True, exist_ok=True)
        if target.exists() and target.stat().st_size == len(data):
            self.skipped += 1
        else:
            target.write_bytes(data)
            self.written += 1
        return f"{self.base_url}/{checksum[:2]}/{name}"

    def describe(self) -> str:
        return f"local:{self.root} -> {self.base_url}"


class R2AssetStore(AssetStore):
    """S3-compatible object storage (Cloudflare R2, MinIO, AWS S3).

    Uploads are conditional on the object not already existing, which makes a
    re-import of an unchanged paper free rather than a full re-upload.
    """

    def __init__(
        self,
        *,
        bucket: str,
        endpoint: str,
        access_key: str,
        secret_key: str,
        public_base_url: str,
        prefix: str = "figures",
    ) -> None:
        try:
            import boto3  # noqa: PLC0415
        except ImportError as error:
            raise RuntimeError(
                "The r2 asset store needs boto3: pip install -r tools/ingest/requirements.txt"
            ) from error

        self._client = boto3.client(
            "s3",
            endpoint_url=endpoint,
            aws_access_key_id=access_key,
            aws_secret_access_key=secret_key,
            region_name="auto",
        )
        self.bucket = bucket
        self.prefix = prefix.strip("/")
        self.base_url = public_base_url.rstrip("/")
        self.written = 0
        self.skipped = 0

    def _key(self, checksum: str, variant: str) -> str:
        return f"{self.prefix}/{checksum[:2]}/{checksum}.{variant}.png"

    def put(self, checksum: str, variant: str, data: bytes) -> str:
        key = self._key(checksum, variant)
        try:
            self._client.head_object(Bucket=self.bucket, Key=key)
            self.skipped += 1
        except Exception:
            self._client.put_object(
                Bucket=self.bucket,
                Key=key,
                Body=data,
                ContentType="image/png",
                CacheControl=CACHE_CONTROL,
            )
            self.written += 1
        return f"{self.base_url}/{key}"

    def describe(self) -> str:
        return f"r2:{self.bucket}/{self.prefix} -> {self.base_url}"


def build_store(kind: Optional[str] = None) -> AssetStore:
    """Pick a backend from the environment.

    Defaults to local, so the pipeline works out of the box with no bucket and
    no credentials -- which is what makes a first run possible before anyone
    has decided where production assets will live.
    """
    kind = (kind or os.environ.get("INGEST_ASSET_STORE") or "local").lower()

    if kind == "local":
        repo_root = Path(__file__).resolve().parents[3]
        root = Path(os.environ.get("INGEST_ASSET_DIR") or (repo_root / "backend" / "static" / "figures"))
        base_url = os.environ.get("INGEST_ASSET_BASE_URL") or "/static/figures"
        return LocalAssetStore(root, base_url)

    if kind in {"r2", "s3"}:
        missing = [
            name for name in ("R2_BUCKET", "R2_ENDPOINT", "R2_ACCESS_KEY_ID",
                              "R2_SECRET_ACCESS_KEY", "R2_PUBLIC_BASE_URL")
            if not os.environ.get(name)
        ]
        if missing:
            raise RuntimeError(f"asset store {kind!r} needs: {', '.join(missing)}")
        return R2AssetStore(
            bucket=os.environ["R2_BUCKET"],
            endpoint=os.environ["R2_ENDPOINT"],
            access_key=os.environ["R2_ACCESS_KEY_ID"],
            secret_key=os.environ["R2_SECRET_ACCESS_KEY"],
            public_base_url=os.environ["R2_PUBLIC_BASE_URL"],
            prefix=os.environ.get("R2_PREFIX", "figures"),
        )

    raise RuntimeError(f"unknown asset store {kind!r} (expected 'local' or 'r2')")


def upload_paper_assets(store: AssetStore, document: dict, assets_dir: Path) -> dict[str, dict]:
    """Push every figure a paper uses, and return checksum -> variant URLs."""
    urls: dict[str, dict] = {}
    for checksum, meta in (document.get("assets") or {}).items():
        variants: dict[str, dict] = {}
        for variant, filename in (meta.get("variants") or {}).items():
            path = assets_dir / filename
            if not path.exists():
                continue
            data = path.read_bytes()
            variants[variant] = {"url": store.put(checksum, variant, data), "bytes": len(data)}
        if variants:
            urls[checksum] = variants
    return urls
