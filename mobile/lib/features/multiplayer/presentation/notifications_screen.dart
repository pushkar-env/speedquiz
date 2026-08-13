import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';
import 'package:speedquiz/core/i18n/l10n.dart';
import 'package:speedquiz/core/push/push_service.dart';
import 'package:speedquiz/core/theme/app_theme.dart';
import 'package:speedquiz/features/multiplayer/domain/multiplayer_models.dart';
import 'package:speedquiz/features/multiplayer/presentation/multiplayer_providers.dart';
import 'package:speedquiz/features/social/data/social_repository.dart';
import 'package:speedquiz/shared/widgets/sq_widgets.dart';

final notificationsProvider = FutureProvider.autoDispose<
    ({List<AppNotification> items, int unreadCount})>((ref) {
  return ref.watch(socialRepositoryProvider).fetchNotifications();
});

/// The in-app inbox.
///
/// Rows are rendered from a type plus a payload, never from server-written
/// prose — so the inbox reads in whatever language the app is set to right
/// now, including after the player switches it. Push notifications are the
/// exception and are written server-side, because the OS renders those with
/// the app closed.
class NotificationsScreen extends ConsumerWidget {
  const NotificationsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = context.l10n;
    final inbox = ref.watch(notificationsProvider);
    final pushOff = !ref.watch(pushServiceProvider).isConfigured;

    return Scaffold(
      backgroundColor: context.sq.background,
      appBar: AppBar(
        title: Text(l10n.notificationsTitle),
        actions: [
          if ((inbox.valueOrNull?.unreadCount ?? 0) > 0)
            TextButton(
              onPressed: () async {
                await ref
                    .read(socialRepositoryProvider)
                    .markNotificationsRead();
                ref
                  ..invalidate(notificationsProvider)
                  ..invalidate(socialSummaryProvider);
              },
              child: Text(l10n.notificationsMarkRead),
            ),
        ],
      ),
      body: SqBackdrop(
        child: SafeArea(
          child: RefreshIndicator(
            onRefresh: () async => ref.invalidate(notificationsProvider),
            child: inbox.when(
              loading: () => const Center(child: CircularProgressIndicator()),
              error: (error, _) => ListView(
                padding: const EdgeInsets.all(AppSpacing.md),
                children: [
                  SqErrorState(
                    message: l10n.matchError(errorCodeOf(error)),
                    onRetry: () => ref.invalidate(notificationsProvider),
                  ),
                ],
              ),
              data: (data) {
                if (data.items.isEmpty) {
                  return ListView(
                    padding: const EdgeInsets.all(AppSpacing.md),
                    children: [
                      SqEmptyState(
                        icon: '🔔',
                        title: l10n.notificationsEmpty,
                        message: l10n.notificationsEmptyBody,
                      ),
                    ],
                  );
                }
                return ListView(
                  padding: const EdgeInsets.all(AppSpacing.md),
                  children: [
                    if (pushOff) ...[
                      SqSurface(
                        child: Row(
                          children: [
                            const Icon(Icons.notifications_off_rounded, size: 18),
                            const SizedBox(width: AppSpacing.sm),
                            Expanded(
                              child: Text(
                                l10n.notificationsPushDisabled,
                                style: Theme.of(context).textTheme.bodySmall,
                              ),
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(height: AppSpacing.md),
                    ],
                    SqSurface(
                      child: Column(
                        children: [
                          for (final notification in data.items)
                            _NotificationRow(notification: notification),
                        ],
                      ),
                    ),
                  ],
                );
              },
            ),
          ),
        ),
      ),
    );
  }
}

class _NotificationRow extends ConsumerWidget {
  const _NotificationRow({required this.notification});

  final AppNotification notification;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final l10n = context.l10n;
    final actor = notification.actor?.label ?? l10n.player;

    final text = switch (notification.type) {
      AppNotificationType.friendRequest => l10n.notificationFriendRequest(actor),
      AppNotificationType.friendAccepted => l10n.notificationFriendAccepted(actor),
      AppNotificationType.matchInvite => l10n.notificationMatchInvite(
          actor,
          notification.payload['topic_name'] as String? ?? '',
        ),
      AppNotificationType.matchYourTurn => l10n.notificationYourTurn(actor),
      AppNotificationType.matchResult => l10n.notificationMatchResult(actor),
      AppNotificationType.matchExpiring => l10n.notificationYourTurn(actor),
    };

    return SqPressable(
      onTap: () async {
        final repository = ref.read(socialRepositoryProvider);
        if (notification.isUnread) {
          await repository.markNotificationsRead(id: notification.id);
          ref
            ..invalidate(notificationsProvider)
            ..invalidate(socialSummaryProvider);
        }
        final link = notification.deepLink;
        if (link != null && link.isNotEmpty && context.mounted) {
          context.push(link);
        }
      },
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: AppSpacing.sm),
        child: Row(
          children: [
            SqAvatar(
              name: actor,
              seed: notification.actor?.userId ?? notification.id,
              avatarId: notification.actor?.avatarId,
              size: 40,
            ),
            const SizedBox(width: AppSpacing.md),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(text, style: theme.textTheme.bodyLarge),
                  const SizedBox(height: 2),
                  Text(
                    DateFormat.MMMd().add_jm().format(
                          notification.createdAt.toLocal(),
                        ),
                    style: theme.textTheme.bodySmall,
                  ),
                ],
              ),
            ),
            if (notification.isUnread)
              Container(
                width: 9,
                height: 9,
                decoration: const BoxDecoration(
                  color: AppColors.accent,
                  shape: BoxShape.circle,
                ),
              ),
          ],
        ),
      ),
    );
  }
}
