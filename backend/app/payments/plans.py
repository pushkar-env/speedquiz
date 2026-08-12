"""Premium plan catalog — the single source of truth for what we sell.

Two auto-renewing subscriptions, one product id each:

    speedquiz_premium_monthly   P1M
    speedquiz_premium_annual    P1Y   (anchor plan)

One product id per plan rather than one product with two base plans, because
that keeps the client honest: `queryProductDetails({...})` returns one entry
per plan and the paywall never has to guess which base plan a `ProductDetails`
came from.

**Prices are deliberately absent.** Play and the App Store are the merchant of
record in both India and the US; they own the price ladder, the currency, and
the tax treatment (GST in IN, sales tax in US). The client renders the
store-localised `ProductDetails.price` string, so a player in Mumbai sees
"₹399" and one in Austin sees "$4.99" without the backend knowing either
number. Hardcoding prices here would guarantee they drift out of sync with the
consoles and would show the wrong currency to half the world.

Apple requires both subscriptions to sit in the *same subscription group* so
that a plan switch is an upgrade/downgrade rather than two concurrent
subscriptions. Play gets the equivalent by us passing the old purchase token
in `ChangeSubscriptionParam`.
"""

from __future__ import annotations

from dataclasses import dataclass
from enum import Enum
from typing import Optional

from app.core.config import get_settings


class PlanCode(str, Enum):
    """Internal plan identity — stable across stores and price changes."""

    MONTHLY = "monthly"
    ANNUAL = "annual"
    # Pre-subscription non-consumable. Nothing sells it any more, but anyone
    # who bought it keeps premium forever, so verification still recognises it.
    LEGACY_LIFETIME = "legacy_lifetime"


class BillingPeriod(str, Enum):
    MONTH = "P1M"
    YEAR = "P1Y"
    LIFETIME = "lifetime"


@dataclass(frozen=True)
class Plan:
    code: PlanCode
    product_id: str
    period: BillingPeriod
    # Months of service per billing cycle; drives the "save X%" maths on the
    # paywall, which is computed client-side from real store prices.
    months: int
    title: str
    subtitle: str
    # Paywall ordering and default selection.
    sort_order: int
    recommended: bool = False
    badge: Optional[str] = None
    is_subscription: bool = True
    purchasable: bool = True

    @property
    def is_lifetime(self) -> bool:
        return self.period is BillingPeriod.LIFETIME


def _catalog() -> dict[PlanCode, Plan]:
    settings = get_settings()
    return {
        PlanCode.MONTHLY: Plan(
            code=PlanCode.MONTHLY,
            product_id=settings.iap_product_monthly,
            period=BillingPeriod.MONTH,
            months=1,
            title="Monthly",
            subtitle="Billed every month, cancel anytime",
            sort_order=0,
        ),
        PlanCode.ANNUAL: Plan(
            code=PlanCode.ANNUAL,
            product_id=settings.iap_product_annual,
            period=BillingPeriod.YEAR,
            months=12,
            title="Annual",
            subtitle="Billed once a year, cancel anytime",
            sort_order=1,
            recommended=True,
            badge="BEST VALUE",
        ),
        PlanCode.LEGACY_LIFETIME: Plan(
            code=PlanCode.LEGACY_LIFETIME,
            product_id=settings.iap_premium_product_id,
            period=BillingPeriod.LIFETIME,
            months=0,
            title="Lifetime",
            subtitle="One-time unlock",
            sort_order=99,
            is_subscription=False,
            # Honoured on verify/restore, never offered for sale again.
            purchasable=False,
        ),
    }


def all_plans() -> list[Plan]:
    return sorted(_catalog().values(), key=lambda p: p.sort_order)


def purchasable_plans() -> list[Plan]:
    """What the paywall is allowed to show."""
    return [p for p in all_plans() if p.purchasable]


def plan_for_product(product_id: str) -> Optional[Plan]:
    pid = (product_id or "").strip()
    if not pid:
        return None
    for plan in _catalog().values():
        if plan.product_id == pid:
            return plan
    return None


def plan_for_code(code: str | PlanCode) -> Optional[Plan]:
    try:
        key = PlanCode(code)
    except ValueError:
        return None
    return _catalog().get(key)


def is_known_product(product_id: str) -> bool:
    return plan_for_product(product_id) is not None


def subscription_product_ids() -> set[str]:
    return {p.product_id for p in _catalog().values() if p.is_subscription}


def manage_subscription_url(platform: Optional[str], product_id: Optional[str]) -> str:
    """Deep link to where the player can cancel, resume, or fix payment.

    Both stores require an app that sells subscriptions to link here, and it is
    also the only place a user in billing retry can update a failed card — a
    path that matters far more in India, where card e-mandates fail routinely
    on renewal, than it does in the US.
    """
    settings = get_settings()
    if (platform or "").strip().lower() == "ios":
        return "https://apps.apple.com/account/subscriptions"

    package = (settings.iap_android_package or "").strip()
    base = "https://play.google.com/store/account/subscriptions"
    params = []
    if product_id:
        params.append(f"sku={product_id}")
    if package:
        params.append(f"package={package}")
    return f"{base}?{'&'.join(params)}" if params else base
