import 'package:flutter/material.dart';
import 'package:speedquiz/core/routing/app_router.dart';
import 'package:speedquiz/core/routing/nav.dart';
import 'package:speedquiz/core/i18n/l10n.dart';
import 'package:speedquiz/core/theme/app_theme.dart';
import 'package:speedquiz/features/entitlements/presentation/premium_offer.dart';
import 'package:speedquiz/features/profile/presentation/widgets/profile_widgets.dart';
import 'package:speedquiz/shared/widgets/sq_widgets.dart';

/// Mid-game paywall. Shown as a sheet so the player keeps their context.
Future<void> showPremiumPaywall(BuildContext context, {String? reason}) {
  return showSqSheet<void>(
    context,
    builder: (sheetContext) => Padding(
      padding: EdgeInsets.fromLTRB(
        AppSpacing.lg,
        AppSpacing.md,
        AppSpacing.lg,
        AppSpacing.lg + MediaQuery.paddingOf(sheetContext).bottom,
      ),
      child: SingleChildScrollView(
        child: PremiumOffer(
          reason: reason,
          onDone: () => Navigator.of(sheetContext).pop(),
        ),
      ),
    ),
  );
}

/// Full-screen premium page, reachable from Profile.
class PremiumScreen extends StatelessWidget {
  const PremiumScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.transparent,
      body: SqBackdrop(
        colors: const [AppColors.gold, AppColors.magenta, AppColors.accent],
        child: SafeArea(
          child: Column(
            children: [
              SubScreenHeader(
                title: context.l10n.profilePremium,
                subtitle: context.l10n.premiumUnlockEverything,
              ),
              Expanded(
                child: SingleChildScrollView(
                  padding: const EdgeInsets.fromLTRB(
                    AppSpacing.lg,
                    AppSpacing.md,
                    AppSpacing.lg,
                    AppSpacing.xxl,
                  ),
                  child: PremiumOffer(
                    onDone: () => context.popOrGo(Routes.profile),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
