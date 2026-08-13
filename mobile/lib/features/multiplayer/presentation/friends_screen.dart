import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:share_plus/share_plus.dart';
import 'package:speedquiz/core/i18n/l10n.dart';
import 'package:speedquiz/core/routing/app_router.dart';
import 'package:speedquiz/core/theme/app_theme.dart';
import 'package:speedquiz/features/multiplayer/data/multiplayer_repository.dart';
import 'package:speedquiz/features/multiplayer/domain/multiplayer_models.dart';
import 'package:speedquiz/features/multiplayer/presentation/multiplayer_providers.dart';
import 'package:speedquiz/features/multiplayer/presentation/widgets/battle_widgets.dart';
import 'package:speedquiz/features/topics/data/topics_repository.dart';
import 'package:speedquiz/shared/widgets/sq_widgets.dart';

/// Friends, requests and search — the whole social graph on one screen.
class FriendsScreen extends ConsumerStatefulWidget {
  const FriendsScreen({super.key});

  @override
  ConsumerState<FriendsScreen> createState() => _FriendsScreenState();
}

class _FriendsScreenState extends ConsumerState<FriendsScreen>
    with SingleTickerProviderStateMixin {
  late final TabController _tabs = TabController(length: 2, vsync: this);
  final _searchController = TextEditingController();
  String _query = '';

  @override
  void dispose() {
    _tabs.dispose();
    _searchController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final requests = ref.watch(friendRequestsProvider);
    final pendingCount = requests.valueOrNull?.incoming.length ?? 0;

    return Scaffold(
      backgroundColor: context.sq.background,
      appBar: AppBar(
        title: Text(l10n.friendsTitle),
        bottom: TabBar(
          controller: _tabs,
          tabs: [
            Tab(text: l10n.friendsTab),
            Tab(
              text: pendingCount > 0
                  ? '${l10n.friendsRequestsTab} ($pendingCount)'
                  : l10n.friendsRequestsTab,
            ),
          ],
        ),
      ),
      body: SqBackdrop(
        child: SafeArea(
          child: Column(
            children: [
              Padding(
                padding: const EdgeInsets.all(AppSpacing.md),
                child: TextField(
                  controller: _searchController,
                  onChanged: (value) => setState(() => _query = value),
                  textInputAction: TextInputAction.search,
                  decoration: InputDecoration(
                    hintText: l10n.friendsSearchHint,
                    prefixIcon: const Icon(Icons.search_rounded),
                    suffixIcon: _query.isEmpty
                        ? null
                        : IconButton(
                            icon: const Icon(Icons.close_rounded),
                            onPressed: () {
                              _searchController.clear();
                              setState(() => _query = '');
                            },
                          ),
                  ),
                ),
              ),
              Expanded(
                child: _query.trim().length >= 2
                    ? _SearchResults(query: _query)
                    : TabBarView(
                        controller: _tabs,
                        children: const [_FriendsTab(), _RequestsTab()],
                      ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _FriendsTab extends ConsumerWidget {
  const _FriendsTab();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = context.l10n;
    final friends = ref.watch(friendsProvider);

    return RefreshIndicator(
      onRefresh: () async => ref.invalidate(friendsProvider),
      child: friends.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (error, _) => ListView(
          padding: const EdgeInsets.all(AppSpacing.md),
          children: [
            SqErrorState(
              message: l10n.matchError(errorCodeOf(error)),
              onRetry: () => ref.invalidate(friendsProvider),
            ),
          ],
        ),
        data: (items) => ListView(
          padding: const EdgeInsets.fromLTRB(
            AppSpacing.md,
            0,
            AppSpacing.md,
            AppSpacing.xl,
          ),
          children: [
            const _FriendCodeCard(),
            const SizedBox(height: AppSpacing.md),
            if (items.isEmpty)
              SqEmptyState(
                icon: '👥',
                title: l10n.friendsNoFriends,
                message: l10n.friendsNoFriendsBody,
              )
            else ...[
              SqSectionHeader(title: l10n.friendsCount(items.length)),
              const SizedBox(height: AppSpacing.sm),
              SqSurface(
                child: Column(
                  children: [
                    for (final friend in items) _FriendRow(friend: friend),
                  ],
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _FriendRow extends ConsumerWidget {
  const _FriendRow({required this.friend});

  final Friend friend;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = context.l10n;
    final record = friend.headToHead;
    final subtitle = record.played == 0
        ? (friend.isOnline ? l10n.friendsOnline : null)
        : l10n.friendsHeadToHead(record.wins, record.losses);

    return PlayerTile(
      player: friend.player,
      isOnline: friend.isOnline,
      subtitle: subtitle,
      onTap: () => _showActions(context, ref),
      trailing: SqBadge(
        label: friend.openMatchId != null
            ? l10n.battleContinue
            : l10n.friendsChallenge,
        dense: true,
      ),
    );
  }

  Future<void> _showActions(BuildContext context, WidgetRef ref) async {
    final l10n = context.l10n;
    await showModalBottomSheet<void>(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (sheetContext) => SqSheetShell(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            PlayerTile(player: friend.player, isOnline: friend.isOnline),
            const SizedBox(height: AppSpacing.md),
            SqButton(
              label: friend.openMatchId != null
                  ? l10n.battleContinue
                  : l10n.friendsChallenge,
              onPressed: () {
                Navigator.of(sheetContext).pop();
                if (friend.openMatchId != null) {
                  context.push(Routes.matchPath(friend.openMatchId!));
                } else {
                  _challenge(context, ref);
                }
              },
            ),
            const SizedBox(height: AppSpacing.sm),
            SqGhostButton(
              label: l10n.friendsRemove,
              onPressed: () async {
                Navigator.of(sheetContext).pop();
                await _confirmRemove(context, ref);
              },
            ),
            const SizedBox(height: AppSpacing.sm),
            SqGhostButton(
              label: l10n.friendsBlock,
              onPressed: () async {
                Navigator.of(sheetContext).pop();
                await _confirmBlock(context, ref);
              },
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _challenge(BuildContext context, WidgetRef ref) async {
    // A challenge needs a topic. Reuse the catalog rather than inventing a
    // second picker: the player already knows this list. Only playable topics
    // are offered — challenging someone to an empty bank fails server-side.
    final topics = (await ref.read(topicsProvider.future))
        .where((topic) => topic.isPlayable)
        .toList(growable: false);
    if (!context.mounted || topics.isEmpty) return;

    final topicId = await showModalBottomSheet<String>(
      context: context,
      backgroundColor: Colors.transparent,
      isScrollControlled: true,
      builder: (sheetContext) => SqSheetShell(
        child: SizedBox(
          height: MediaQuery.sizeOf(sheetContext).height * 0.6,
          child: ListView(
            children: [
              SqSectionHeader(title: context.l10n.setupPickATopic),
              const SizedBox(height: AppSpacing.sm),
              for (final topic in topics)
                ListTile(
                  title: Text(topic.name),
                  onTap: () => Navigator.of(sheetContext).pop(topic.id),
                ),
            ],
          ),
        ),
      ),
    );
    if (topicId == null || !context.mounted) return;

    try {
      final match = await ref.read(multiplayerRepositoryProvider).createChallenge(
            topicId: topicId,
            opponentUserId: friend.player.userId,
          );
      if (!context.mounted) return;
      ref.invalidate(matchListProvider);
      context.push(Routes.matchPath(match.id));
    } catch (error) {
      if (!context.mounted) return;
      SqToast.error(context, context.l10n.matchError(errorCodeOf(error)));
    }
  }

  Future<void> _confirmRemove(BuildContext context, WidgetRef ref) async {
    final l10n = context.l10n;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => SqDialog(
        title: l10n.friendsRemoveTitle,
        message: l10n.friendsRemoveBody(friend.player.label),
        tone: SqDialogTone.danger,
        primaryLabel: l10n.friendsRemoveConfirm,
        onPrimary: () => Navigator.of(dialogContext).pop(true),
        secondaryLabel: l10n.cancel,
        onSecondary: () => Navigator.of(dialogContext).pop(false),
      ),
    );
    if (confirmed != true) return;
    await ref.read(socialActionsProvider).unfriend(friend.player.userId);
  }

  Future<void> _confirmBlock(BuildContext context, WidgetRef ref) async {
    final l10n = context.l10n;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => SqDialog(
        title: l10n.friendsBlockTitle,
        message: l10n.friendsBlockBody,
        tone: SqDialogTone.danger,
        primaryLabel: l10n.friendsBlock,
        onPrimary: () => Navigator.of(dialogContext).pop(true),
        secondaryLabel: l10n.cancel,
        onSecondary: () => Navigator.of(dialogContext).pop(false),
      ),
    );
    if (confirmed != true) return;
    await ref.read(socialActionsProvider).block(friend.player.userId);
  }
}

class _RequestsTab extends ConsumerWidget {
  const _RequestsTab();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = context.l10n;
    final requests = ref.watch(friendRequestsProvider);
    final actions = ref.read(socialActionsProvider);

    return requests.when(
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (error, _) => SqErrorState(
        message: l10n.matchError(errorCodeOf(error)),
        onRetry: () => ref.invalidate(friendRequestsProvider),
      ),
      data: (data) {
        if (data.incoming.isEmpty && data.outgoing.isEmpty) {
          return SqEmptyState(
            icon: '📭',
            title: l10n.friendsNoRequests,
            message: l10n.friendsNoFriendsBody,
          );
        }
        return ListView(
          padding: const EdgeInsets.fromLTRB(
            AppSpacing.md,
            0,
            AppSpacing.md,
            AppSpacing.xl,
          ),
          children: [
            if (data.incoming.isNotEmpty) ...[
              SqSectionHeader(title: l10n.friendsIncoming),
              const SizedBox(height: AppSpacing.sm),
              SqSurface(
                child: Column(
                  children: [
                    for (final request in data.incoming)
                      PlayerTile(
                        player: request.player,
                        trailing: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            IconButton(
                              icon: const Icon(
                                Icons.check_circle_rounded,
                                color: AppColors.success,
                              ),
                              tooltip: l10n.friendsAccept,
                              onPressed: () => actions.accept(request.id),
                            ),
                            IconButton(
                              icon: const Icon(Icons.cancel_rounded),
                              tooltip: l10n.friendsDecline,
                              onPressed: () => actions.decline(request.id),
                            ),
                          ],
                        ),
                      ),
                  ],
                ),
              ),
              const SizedBox(height: AppSpacing.lg),
            ],
            if (data.outgoing.isNotEmpty) ...[
              SqSectionHeader(title: l10n.friendsOutgoing),
              const SizedBox(height: AppSpacing.sm),
              SqSurface(
                child: Column(
                  children: [
                    for (final request in data.outgoing)
                      PlayerTile(
                        player: request.player,
                        subtitle: l10n.friendsRequestPending,
                        trailing: TextButton(
                          onPressed: () => actions.cancelRequest(request.id),
                          child: Text(l10n.friendsCancelRequest),
                        ),
                      ),
                  ],
                ),
              ),
            ],
          ],
        );
      },
    );
  }
}

class _SearchResults extends ConsumerWidget {
  const _SearchResults({required this.query});

  final String query;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = context.l10n;
    final results = ref.watch(playerSearchProvider(query));
    final actions = ref.read(socialActionsProvider);

    return results.when(
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (error, _) => SqErrorState(message: l10n.matchError(errorCodeOf(error))),
      data: (data) {
        if (data.players.isEmpty) {
          return SqEmptyState(
            icon: '🔍',
            title: l10n.friendsSearchEmpty,
            message: l10n.friendsCodeHint,
          );
        }
        return ListView(
          padding: const EdgeInsets.fromLTRB(
            AppSpacing.md,
            0,
            AppSpacing.md,
            AppSpacing.xl,
          ),
          children: [
            SqSurface(
              child: Column(
                children: [
                  for (final player in data.players)
                    _SearchRow(
                      player: player,
                      relationship: data.relationships[player.userId],
                      onAdd: () async {
                        try {
                          await actions.sendRequest(userId: player.userId);
                          if (!context.mounted) return;
                          SqToast.success(context, l10n.friendsRequestSent);
                        } catch (error) {
                          if (!context.mounted) return;
                          SqToast.error(
                            context,
                            l10n.matchError(errorCodeOf(error)),
                          );
                        }
                      },
                    ),
                ],
              ),
            ),
          ],
        );
      },
    );
  }
}

class _SearchRow extends StatelessWidget {
  const _SearchRow({
    required this.player,
    required this.relationship,
    required this.onAdd,
  });

  final PlayerBrief player;
  final String? relationship;
  final VoidCallback onAdd;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;

    final trailing = switch (relationship) {
      'friends' => SqBadge(
          label: l10n.friendsAlreadyFriends,
          color: AppColors.success,
          dense: true,
        ),
      'request_sent' => SqBadge(label: l10n.friendsRequestPending, dense: true),
      'request_received' => SqBadge(label: l10n.friendsIncoming, dense: true),
      _ => IconButton(
          icon: const Icon(Icons.person_add_alt_1_rounded),
          tooltip: l10n.friendsAdd,
          onPressed: onAdd,
        ),
    };

    return PlayerTile(player: player, trailing: trailing);
  }
}

class _FriendCodeCard extends ConsumerWidget {
  const _FriendCodeCard();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final l10n = context.l10n;
    final status = ref.watch(usernameStatusProvider);

    return status.when(
      loading: () => const SqShimmer(
        child: SizedBox(height: 96, width: double.infinity),
      ),
      error: (_, _) => const SizedBox.shrink(),
      data: (data) => SqSurface(
        highlighted: true,
        child: Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(l10n.friendsYourCode, style: theme.textTheme.bodySmall),
                  const SizedBox(height: 2),
                  SelectableText(
                    data.friendCode,
                    style: theme.textTheme.titleLarge?.copyWith(
                      letterSpacing: 3,
                      fontWeight: FontWeight.w900,
                      color: theme.sq.accent,
                    ),
                  ),
                ],
              ),
            ),
            IconButton(
              icon: const Icon(Icons.copy_rounded),
              tooltip: l10n.battleCopy,
              onPressed: () async {
                await Clipboard.setData(ClipboardData(text: data.friendCode));
                if (context.mounted) {
                  SqToast.success(context, l10n.friendsCodeCopied);
                }
              },
            ),
            IconButton(
              icon: const Icon(Icons.ios_share_rounded),
              tooltip: l10n.friendsShareCode,
              onPressed: () => SharePlus.instance.share(
                ShareParams(
                  text: '${l10n.friendsYourCode}: ${data.friendCode}',
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
