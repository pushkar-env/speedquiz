import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:speedquiz/core/theme/app_theme.dart';
import 'package:speedquiz/features/leaderboard/data/leaderboard_repository.dart';
import 'package:speedquiz/features/leaderboard/domain/leaderboard_models.dart';
import 'package:speedquiz/shared/widgets/sq_button.dart';

class LeaderboardScreen extends ConsumerStatefulWidget {
  const LeaderboardScreen({super.key});

  @override
  ConsumerState<LeaderboardScreen> createState() => _LeaderboardScreenState();
}

class _LeaderboardScreenState extends ConsumerState<LeaderboardScreen>
    with SingleTickerProviderStateMixin {
  late final TabController _tabs;

  @override
  void initState() {
    super.initState();
    _tabs = TabController(length: 2, vsync: this);
  }

  @override
  void dispose() {
    _tabs.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Scaffold(
      body: SafeArea(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(
                AppSpacing.lg,
                AppSpacing.lg,
                AppSpacing.lg,
                0,
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Leaderboard',
                    style: theme.textTheme.headlineMedium?.copyWith(
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    'Climb the weekly ranks and today’s daily board',
                    style: theme.textTheme.bodyMedium,
                  ),
                  const SizedBox(height: AppSpacing.md),
                  TabBar(
                    controller: _tabs,
                    labelColor: AppColors.accent,
                    unselectedLabelColor:
                        theme.colorScheme.onSurface.withValues(alpha: 0.55),
                    indicatorColor: AppColors.accent,
                    tabs: const [
                      Tab(text: 'Weekly'),
                      Tab(text: 'Daily'),
                    ],
                  ),
                ],
              ),
            ),
            Expanded(
              child: TabBarView(
                controller: _tabs,
                children: const [
                  _BoardTab(scope: 'weekly'),
                  _BoardTab(scope: 'daily'),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _BoardTab extends ConsumerWidget {
  const _BoardTab({required this.scope});

  final String scope;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final async = ref.watch(leaderboardProvider(scope));
    final theme = Theme.of(context);
    final dark = theme.brightness == Brightness.dark;

    return async.when(
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (err, _) => Padding(
        padding: const EdgeInsets.all(AppSpacing.lg),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Text('Could not load ranks', style: theme.textTheme.titleMedium),
            const SizedBox(height: 8),
            SqButton(
              label: 'RETRY',
              onPressed: () => ref.invalidate(leaderboardProvider(scope)),
            ),
          ],
        ),
      ),
      data: (board) {
        return RefreshIndicator(
          onRefresh: () async {
            ref.invalidate(leaderboardProvider(scope));
            await ref.read(leaderboardProvider(scope).future);
          },
          child: ListView(
            padding: const EdgeInsets.all(AppSpacing.lg),
            children: [
              if (board.me.score != null) ...[
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.all(AppSpacing.md),
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(AppRadii.md),
                    color: AppColors.accent.withValues(alpha: 0.12),
                    border: Border.all(
                      color: AppColors.accent.withValues(alpha: 0.3),
                    ),
                  ),
                  child: Row(
                    children: [
                      Text(
                        board.me.rank != null ? '#${board.me.rank}' : '—',
                        style: theme.textTheme.titleLarge?.copyWith(
                          fontWeight: FontWeight.w800,
                          color: AppColors.accent,
                        ),
                      ),
                      const SizedBox(width: AppSpacing.md),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              board.me.username ?? 'You',
                              style: theme.textTheme.titleMedium?.copyWith(
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                            Text(
                              'Your best · ${board.periodKey}',
                              style: theme.textTheme.bodyMedium,
                            ),
                          ],
                        ),
                      ),
                      Text(
                        formatScore(board.me.score ?? 0),
                        style: theme.textTheme.titleLarge?.copyWith(
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: AppSpacing.lg),
              ],
              if (board.items.isEmpty)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 48),
                  child: Column(
                    children: [
                      Text(
                        'No ranks yet',
                        style: theme.textTheme.titleLarge?.copyWith(
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      const SizedBox(height: 8),
                      Text(
                        scope == 'daily'
                            ? 'Finish today’s challenge to claim the board.'
                            : 'Play a run this week to appear here.',
                        textAlign: TextAlign.center,
                        style: theme.textTheme.bodyMedium,
                      ),
                    ],
                  ),
                )
              else
                ...board.items.map(
                  (entry) => Padding(
                    padding: const EdgeInsets.only(bottom: 10),
                    child: _RankRow(entry: entry, dark: dark),
                  ),
                ),
            ],
          ),
        );
      },
    );
  }
}

class _RankRow extends StatelessWidget {
  const _RankRow({required this.entry, required this.dark});

  final LeaderboardEntry entry;
  final bool dark;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(AppRadii.md),
        color: entry.isMe
            ? AppColors.accent.withValues(alpha: 0.1)
            : (dark ? AppColors.surfaceDark : AppColors.surfaceLight),
        border: Border.all(
          color: entry.isMe
              ? AppColors.accent.withValues(alpha: 0.35)
              : (dark ? AppColors.borderDark : AppColors.borderLight),
        ),
      ),
      child: Row(
        children: [
          SizedBox(
            width: 36,
            child: Text(
              '#${entry.rank}',
              style: theme.textTheme.titleMedium?.copyWith(
                fontWeight: FontWeight.w800,
              ),
            ),
          ),
          Expanded(
            child: Text(
              entry.username,
              style: theme.textTheme.titleMedium?.copyWith(
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
          Text(
            formatScore(entry.score),
            style: theme.textTheme.titleMedium?.copyWith(
              fontWeight: FontWeight.w800,
            ),
          ),
        ],
      ),
    );
  }
}
