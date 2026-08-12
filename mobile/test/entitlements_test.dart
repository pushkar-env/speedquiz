import 'package:flutter_test/flutter_test.dart';
import 'package:in_app_purchase/in_app_purchase.dart';
import 'package:speedquiz/features/entitlements/data/billing_service.dart';
import 'package:speedquiz/features/entitlements/domain/entitlement_models.dart';

PremiumPlan _plan({
  required String code,
  required int months,
  bool recommended = false,
}) {
  return PremiumPlan(
    code: code,
    productId: 'speedquiz_premium_$code',
    period: months >= 12 ? 'P1Y' : 'P1M',
    months: months,
    title: code,
    subtitle: '',
    recommended: recommended,
  );
}

PlanOffer _offer({
  required String code,
  required int months,
  double? price,
  String currency = 'INR',
}) {
  return PlanOffer(
    plan: _plan(code: code, months: months),
    details: price == null
        ? null
        : ProductDetails(
            id: 'speedquiz_premium_$code',
            title: code,
            description: '',
            price: '₹$price',
            rawPrice: price,
            currencyCode: currency,
          ),
  );
}

void main() {
  group('EntitlementsMe parsing', () {
    test('reads subscription state and renewal detail', () {
      final me = EntitlementsMe.fromJson({
        'is_premium': true,
        'enforce_caps': true,
        'custom_topics_unlimited': true,
        'premium_cosmetics': true,
        'dev_toggle_allowed': false,
        'plan_code': 'annual',
        'plan_title': 'Annual',
        'subscription_status': 'active',
        'expires_at': '2027-08-12T10:00:00+00:00',
        'auto_renewing': true,
        'will_renew': true,
        'manage_url': 'https://play.google.com/store/account/subscriptions',
      });

      expect(me.isPremium, isTrue);
      expect(me.state, SubscriptionState.active);
      expect(me.planCode, 'annual');
      expect(me.willRenew, isTrue);
      expect(me.expiresAt, isNotNull);
      expect(me.premiumCosmetics, isTrue);
    });

    test('a missing payload is treated as free, not premium', () {
      final me = EntitlementsMe.fromJson(const {});
      expect(me.isPremium, isFalse);
      expect(me.state, SubscriptionState.none);
      expect(me.hasSubscription, isFalse);
    });

    test('an unrecognised state does not grant entitlement', () {
      final me = EntitlementsMe.fromJson(const {'subscription_status': 'wat'});
      expect(me.state, SubscriptionState.none);
      expect(me.state.isEntitled, isFalse);
    });

    test('grace and cancelled still count as entitled', () {
      // Both stores keep serving a cancelled subscription until the paid
      // period ends, and a grace period means the retry is still in flight.
      expect(SubscriptionState.active.isEntitled, isTrue);
      expect(SubscriptionState.grace.isEntitled, isTrue);
      expect(SubscriptionState.cancelled.isEntitled, isTrue);

      expect(SubscriptionState.onHold.isEntitled, isFalse);
      expect(SubscriptionState.paused.isEntitled, isFalse);
      expect(SubscriptionState.pending.isEntitled, isFalse);
      expect(SubscriptionState.expired.isEntitled, isFalse);
      expect(SubscriptionState.revoked.isEntitled, isFalse);
    });

    test('a failed payment is surfaced for a fix-payment prompt', () {
      final me = EntitlementsMe.fromJson(const {
        'is_premium': true,
        'enforce_caps': true,
        'custom_topics_unlimited': true,
        'dev_toggle_allowed': false,
        'subscription_status': 'grace',
        'needs_payment_fix': true,
      });
      expect(me.needsPaymentFix, isTrue);
      expect(me.isPremium, isTrue);
    });

    test('endsAtPeriodEnd is true only after cancelling inside the period', () {
      final cancelled = EntitlementsMe.fromJson(const {
        'is_premium': true,
        'enforce_caps': false,
        'custom_topics_unlimited': true,
        'dev_toggle_allowed': false,
        'subscription_status': 'cancelled',
        'auto_renewing': false,
        'expires_at': '2027-01-01T00:00:00+00:00',
      });
      expect(cancelled.endsAtPeriodEnd, isTrue);

      final renewing = EntitlementsMe.fromJson(const {
        'is_premium': true,
        'enforce_caps': false,
        'custom_topics_unlimited': true,
        'dev_toggle_allowed': false,
        'subscription_status': 'active',
        'auto_renewing': true,
        'expires_at': '2027-01-01T00:00:00+00:00',
      });
      expect(renewing.endsAtPeriodEnd, isFalse);
    });
  });

  group('PremiumPlan', () {
    test('parses the catalog payload', () {
      final plan = PremiumPlan.fromJson(const {
        'code': 'annual',
        'product_id': 'speedquiz_premium_annual',
        'period': 'P1Y',
        'months': 12,
        'title': 'Annual',
        'subtitle': 'Billed once a year',
        'recommended': true,
        'badge': 'BEST VALUE',
      });

      expect(plan.code, 'annual');
      expect(plan.isAnnual, isTrue);
      expect(plan.badge, 'BEST VALUE');
    });
  });

  group('PlanOffer savings', () {
    test('computes annual savings from real store prices', () {
      final monthly = _offer(code: 'monthly', months: 1, price: 99);
      final annual = _offer(code: 'annual', months: 12, price: 799);

      // ₹799/yr is ₹66.58/mo against ₹99/mo — a 33% saving.
      expect(annual.savingsPercentAgainst([monthly, annual]), 33);
    });

    test('the monthly plan never claims a saving against itself', () {
      final monthly = _offer(code: 'monthly', months: 1, price: 99);
      expect(monthly.savingsPercentAgainst([monthly]), isNull);
    });

    test('no claim when the annual plan is not actually cheaper', () {
      final monthly = _offer(code: 'monthly', months: 1, price: 50);
      final annual = _offer(code: 'annual', months: 12, price: 700);
      expect(annual.savingsPercentAgainst([monthly, annual]), isNull);
    });

    test('no claim when the store has not priced the other plan', () {
      final monthly = _offer(code: 'monthly', months: 1);
      final annual = _offer(code: 'annual', months: 12, price: 799);
      expect(annual.savingsPercentAgainst([monthly, annual]), isNull);
    });

    test('an unpriced plan is not purchasable', () {
      expect(_offer(code: 'annual', months: 12).purchasable, isFalse);
      expect(_offer(code: 'annual', months: 12, price: 799).purchasable, isTrue);
    });

    test('monthly equivalent divides the cycle price by its months', () {
      final annual = _offer(code: 'annual', months: 12, price: 1200);
      expect(annual.monthlyEquivalent, 100);
    });
  });
}
