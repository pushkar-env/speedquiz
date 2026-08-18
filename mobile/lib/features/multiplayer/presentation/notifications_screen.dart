import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';
import 'package:speedquiz/core/i18n/l10n.dart';
import 'package:speedquiz/core/push/push_service.dart';
import 'package:speedquiz/core/routing/app_router.dart';
import 'package:speedquiz/core/theme/app_theme.dart';
import 'package:speedquiz/features/multiplayer/data/multiplayer_repository.dart';
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
          // Separate from "mark all read", which is the reason both exist:
          // one silences the badge, the other empties the list. Offering only
          // the first leaves a read inbox nobody can tidy.
          if ((inbox.valueOrNull?.items.length ?? 0) > 0)
            IconButton(
              tooltip: l10n.notificationsClear,
              icon: const Icon(Icons.delete_sweep_rounded),
              onPressed: () => _clear(context, ref),
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
                    // Unread rows are lifted out of the list into their own
                    // cards. A dot on the right of a row inside one flat
                    // surface is the sort of highlight that gets scrolled
                    // past — and a challenge with a clock on it is the one
                    // thing here that must not be.
                    for (final notification
                        in data.items.where((n) => n.isUnread)) ...[
                      _NotificationRow(notification: notification, standout: true),
                      const SizedBox(height: AppSpacing.sm),
                    ],
                    if (data.items.any((n) => !n.isUnread))
                      SqSurface(
                        child: Column(
                          children: [
                            for (final notification
                                in data.items.where((n) => !n.isUnread))
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

/// Empty the inbox, after asking.
///
/// Confirmed because it is not undoable and not obviously scoped — the button
/// sits next to "mark all read", and the two are one tap apart.
Future<void> _clear(BuildContext context, WidgetRef ref) async {
  final l10n = context.l10n;
  final confirmed = await showSqConfirm(
    context,
    title: l10n.notificationsClearTitle,
    message: l10n.notificationsClearBody,
    confirmLabel: l10n.notificationsClear,
    cancelLabel: l10n.cancel,
    tone: SqDialogTone.danger,
  );
  if (!confirmed || !context.mounted) return;

  try {
    await ref.read(socialRepositoryProvider).clearNotifications();
  } catch (error) {
    if (context.mounted) {
      SqToast.error(context, context.l10n.matchError(errorCodeOf(error)));
    }
    return;
  }
  ref
    ..invalidate(notificationsProvider)
    ..invalidate(socialSummaryProvider);
  if (context.mounted) SqToast.success(context, l10n.notificationsCleared);
}

class _NotificationRow extends ConsumerWidget {
  const _NotificationRow({required this.notification, this.standout = false});

  final AppNotification notification;

  /// Draw it as its own highlighted card rather than a row in the list.
  final bool standout;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final l10n = context.l10n;
    final actor = notification.actor?.label ?? l10n.player;
    // Two kinds have someone waiting on an answer, so those get the accent
    // treatment and inline actions. The rest are read and, at most, opened.
    final isChallenge = notification.type == AppNotificationType.matchInvite &&
        notification.matchId != null;
    final isFriendRequest =
        notification.type == AppNotificationType.friendRequest &&
            notification.requestId != null;

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

    final row = SqPressable(
      onTap: () => _open(context, ref),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: AppSpacing.sm),
        child: Column(
          children: [
            Row(
              children: [
                SqAvatar(
                  name: actor,
                  seed: notification.actor?.userId ?? notification.id,
                  avatarId: notification.actor?.avatarId,
                  size: 40,
                  ring: standout,
                ),
                const SizedBox(width: AppSpacing.md),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        text,
                        style: theme.textTheme.bodyLarge?.copyWith(
                          fontWeight:
                              standout ? FontWeight.w800 : FontWeight.w600,
                        ),
                      ),
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
            if ((isChallenge || isFriendRequest) && standout) ...[
              const SizedBox(height: AppSpacing.sm),
              Row(
                children: [
                  Expanded(
                    child: SqButton(
                      label: l10n.lobbyAccept,
                      height: 44,
                      onPressed: () => isChallenge
                          ? _respond(context, ref, accept: true)
                          : _respondToRequest(context, ref, accept: true),
                    ),
                  ),
                  const SizedBox(width: AppSpacing.sm),
                  Expanded(
                    child: SqGhostButton(
                      label: isChallenge
                          ? l10n.lobbyDecline
                          : l10n.notificationIgnore,
                      onPressed: () => isChallenge
                          ? _respond(context, ref, accept: false)
                          : _respondToRequest(context, ref, accept: false),
                    ),
                  ),
                ],
              ),
            ],
          ],
        ),
      ),
    );

    if (!standout) return row;
    return SqSurface(highlighted: true, child: row);
  }

  Future<void> _markRead(WidgetRef ref) async {
    if (!notification.isUnread) return;
    await ref
        .read(socialRepositoryProvider)
        .markNotificationsRead(id: notification.id);
    ref
      ..invalidate(notificationsProvider)
      ..invalidate(socialSummaryProvider);
  }

  Future<void> _open(BuildContext context, WidgetRef ref) async {
    await _markRead(ref);
    final link = notification.deepLink;
    if (link != null && link.isNotEmpty && context.mounted) {
      context.push(link);
    }
  }

  /// Answer a friend request without opening the requests screen first.
  Future<void> _respondToRequest(
    BuildContext context,
    WidgetRef ref, {
    required bool accept,
  }) async {
    final requestId = notification.requestId;
    if (requestId == null) return;

    await _markRead(ref);
    final repository = ref.read(socialRepositoryProvider);
    try {
      if (accept) {
        await repository.acceptRequest(requestId);
      } else {
        await repository.declineRequest(requestId);
      }
    } catch (error) {
      if (context.mounted) {
        SqToast.error(context, context.l10n.matchError(errorCodeOf(error)));
      }
      return;
    }
    ref
      ..invalidate(friendRequestsProvider)
      ..invalidate(friendsProvider);
  }

  /// Answer a challenge without opening it first.
  ///
  /// Accepting walks straight into the match, because the point of accepting a
  /// challenge is to play it — and someone is sitting in a lobby waiting.
  Future<void> _respond(
    BuildContext context,
    WidgetRef ref, {
    required bool accept,
  }) async {
    final matchId = notification.matchId;
    if (matchId == null) return;

    await _markRead(ref);
    try {
      await ref.read(multiplayerRepositoryProvider).respond(matchId, accept: accept);
    } catch (error) {
      if (context.mounted) {
        SqToast.error(context, context.l10n.matchError(errorCodeOf(error)));
      }
      return;
    }
    ref.invalidate(matchListProvider);
    if (!context.mounted) return;
    if (accept) context.push(Routes.matchPath(matchId));
  }
}
