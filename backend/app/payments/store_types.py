"""Shared store verification result."""

from __future__ import annotations

from dataclasses import dataclass
from datetime import datetime
from typing import Optional


@dataclass(frozen=True)
class VerifiedPurchase:
    product_id: str
    original_transaction_id: str
    expires_at: Optional[datetime] = None
