import 'package:equatable/equatable.dart';

/// Lifecycle of the player's subscription, mirrored from the store.
///
/// Only [active], [grace] and [cancelled] grant premium — a cancelled
/// subscription keeps working until the period already paid for runs out,
/// which is what both stores promise the buyer.
enum SubscriptionState {
  none,
  active,
  grace,
  onHold,
  paused,
  pending,
  cancelled,
  expired,
  revoked;

  static SubscriptionState fromJson(String? raw) {
    switch (raw) {
      case 'active':
        return SubscriptionState.active;
      case 'grace':
        return SubscriptionState.grace;
      case 'on_hold':
        return SubscriptionState.onHold;
      case 'paused':
        return SubscriptionState.paused;
      case 'pending':
        return SubscriptionState.pending;
      case 'cancelled':
        return SubscriptionState.cancelled;
      case 'expired':
        return SubscriptionState.expired;
      case 'revoked':
        return SubscriptionState.revoked;
      default:
        return SubscriptionState.none;
    }
  }

  bool get isEntitled =>
      this == SubscriptionState.active ||
      this == SubscriptionState.grace ||
      this == SubscriptionState.cancelled;
}

/// A plan the paywall may offer.
///
/// Carries no price. Play and the App Store are the merchant of record, so the
/// localised price string comes from `ProductDetails` — that is the only way a
/// player in Mumbai sees ₹ and one in Austin sees $.
class PremiumPlan extends Equatable {
  const PremiumPlan({
    required this.code,
    required this.productId,
    required this.period,
    required this.months,
    required this.title,
    required this.subtitle,
    this.recommended = false,
    this.badge,
  });

  final String code;
  final String productId;

  /// ISO 8601 duration: `P1M` or `P1Y`.
  final String period;

  /// Months of service per cycle. Drives the savings maths on the paywall.
  final int months;
  final String title;
  final String subtitle;
  final bool recommended;
  final String? badge;

  bool get isAnnual => months >= 12;

  factory PremiumPlan.fromJson(Map<String, dynamic> json) {
    return PremiumPlan(
      code: json['code'] as String? ?? '',
      productId: json['product_id'] as String? ?? '',
      period: json['period'] as String? ?? 'P1M',
      months: (json['months'] as num?)?.toInt() ?? 1,
      title: json['title'] as String? ?? 'Premium',
      subtitle: json['subtitle'] as String? ?? '',
      recommended: json['recommended'] as bool? ?? false,
      badge: json['badge'] as String?,
    );
  }

  @override
  List<Object?> get props => [code, productId, period, months, title, subtitle, recommended, badge];
}

/// The entitlement + subscription state for the signed-in player.
class EntitlementsMe extends Equatable {
  const EntitlementsMe({
    required this.isPremium,
    required this.enforceCaps,
    required this.customTopicsUnlimited,
    required this.devToggleAllowed,
    this.premiumCosmetics = false,
    this.uniquePerTopicLimit,
    this.premiumProductId = 'speedquiz_premium',
    this.billingMode = 'stub',
    this.stubPurchaseAllowed = false,
    this.planCode,
    this.planTitle,
    this.productId,
    this.platform,
    this.state = SubscriptionState.none,
    this.expiresAt,
    this.graceUntil,
    this.autoRenewing = false,
    this.willRenew = false,
    this.isIntroOffer = false,
    this.needsPaymentFix = false,
    this.isPending = false,
    this.manageUrl,
  });

  final bool isPremium;
  final bool enforceCaps;
  final int? uniquePerTopicLimit;
  final bool customTopicsUnlimited;
  final bool premiumCosmetics;
  final bool devToggleAllowed;
  final String premiumProductId;

  /// `store` once the backend verifies against Play / the App Store, `stub`
  /// while it is still accepting simulated purchases.
  final String billingMode;

  /// The backend will accept a simulated purchase, so the paywall can be
  /// exercised end to end before any store products exist. Only ever true on
  /// a deployment whose operator explicitly enabled it.
  final bool stubPurchaseAllowed;

  final String? planCode;
  final String? planTitle;
  final String? productId;
  final String? platform;
  final SubscriptionState state;
  final DateTime? expiresAt;
  final DateTime? graceUntil;
  final bool autoRenewing;
  final bool willRenew;
  final bool isIntroOffer;

  /// The store is retrying a failed payment. Far more common in India, where
  /// card e-mandates lapse on renewal, so this drives a visible "fix payment"
  /// prompt rather than a silent downgrade.
  final bool needsPaymentFix;

  /// A purchase is settling — UPI and net banking can take minutes to days.
  final bool isPending;

  /// Store-managed subscription screen, for cancelling or fixing payment.
  final String? manageUrl;

  bool get hasSubscription => state != SubscriptionState.none;

  /// True once the player has cancelled but is still inside the paid period.
  bool get endsAtPeriodEnd =>
      isPremium && !autoRenewing && expiresAt != null;

  factory EntitlementsMe.fromJson(Map<String, dynamic> json) {
    return EntitlementsMe(
      isPremium: json['is_premium'] as bool? ?? false,
      enforceCaps: json['enforce_caps'] as bool? ?? false,
      uniquePerTopicLimit: (json['unique_per_topic_limit'] as num?)?.toInt(),
      customTopicsUnlimited: json['custom_topics_unlimited'] as bool? ?? true,
      premiumCosmetics: json['premium_cosmetics'] as bool? ?? false,
      devToggleAllowed: json['dev_toggle_allowed'] as bool? ?? false,
      premiumProductId:
          json['premium_product_id'] as String? ?? 'speedquiz_premium',
      billingMode: json['billing_mode'] as String? ?? 'stub',
      stubPurchaseAllowed: json['stub_purchase_allowed'] as bool? ?? false,
      planCode: json['plan_code'] as String?,
      planTitle: json['plan_title'] as String?,
      productId: json['product_id'] as String?,
      platform: json['platform'] as String?,
      state: SubscriptionState.fromJson(json['subscription_status'] as String?),
      expiresAt: _parseDate(json['expires_at']),
      graceUntil: _parseDate(json['grace_until']),
      autoRenewing: json['auto_renewing'] as bool? ?? false,
      willRenew: json['will_renew'] as bool? ?? false,
      isIntroOffer: json['is_intro_offer'] as bool? ?? false,
      needsPaymentFix: json['needs_payment_fix'] as bool? ?? false,
      isPending: json['is_pending'] as bool? ?? false,
      manageUrl: json['manage_url'] as String?,
    );
  }

  static DateTime? _parseDate(Object? raw) {
    if (raw is! String || raw.isEmpty) return null;
    return DateTime.tryParse(raw)?.toLocal();
  }

  EntitlementsMe copyWith({bool? isPremium}) {
    return EntitlementsMe(
      isPremium: isPremium ?? this.isPremium,
      enforceCaps: enforceCaps,
      uniquePerTopicLimit: uniquePerTopicLimit,
      customTopicsUnlimited: customTopicsUnlimited,
      premiumCosmetics: premiumCosmetics,
      devToggleAllowed: devToggleAllowed,
      premiumProductId: premiumProductId,
      billingMode: billingMode,
      stubPurchaseAllowed: stubPurchaseAllowed,
      planCode: planCode,
      planTitle: planTitle,
      productId: productId,
      platform: platform,
      state: state,
      expiresAt: expiresAt,
      graceUntil: graceUntil,
      autoRenewing: autoRenewing,
      willRenew: willRenew,
      isIntroOffer: isIntroOffer,
      needsPaymentFix: needsPaymentFix,
      isPending: isPending,
      manageUrl: manageUrl,
    );
  }

  @override
  List<Object?> get props => [
        isPremium,
        enforceCaps,
        uniquePerTopicLimit,
        customTopicsUnlimited,
        premiumCosmetics,
        devToggleAllowed,
        premiumProductId,
        billingMode,
        stubPurchaseAllowed,
        planCode,
        planTitle,
        productId,
        platform,
        state,
        expiresAt,
        graceUntil,
        autoRenewing,
        willRenew,
        isIntroOffer,
        needsPaymentFix,
        isPending,
        manageUrl,
      ];
}
