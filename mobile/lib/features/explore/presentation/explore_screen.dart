import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:speedquiz/core/config/app_config.dart';
import 'package:speedquiz/core/network/dio_client.dart';
import 'package:speedquiz/core/theme/app_theme.dart';
import 'package:speedquiz/shared/widgets/sq_button.dart';

class TopicItem {
  TopicItem({
    required this.id,
    required this.name,
    required this.icon,
    required this.questionCount,
  });

  final String id;
  final String name;
  final String icon;
  final int questionCount;

  factory TopicItem.fromJson(Map<String, dynamic> json) {
    return TopicItem(
      id: json['id'] as String,
      name: json['name'] as String,
      icon: json['icon'] as String? ?? '✨',
      questionCount: json['question_count'] as int? ?? 0,
    );
  }
}

final topicsProvider = FutureProvider<List<TopicItem>>((ref) async {
  final dio = ref.watch(dioProvider);
  final response = await dio.get('${AppConfig.apiPrefix}/topics');
  final items = (response.data['items'] as List<dynamic>)
      .map((e) => TopicItem.fromJson(e as Map<String, dynamic>))
      .toList();
  return items;
});

class ExploreScreen extends ConsumerWidget {
  const ExploreScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final topics = ref.watch(topicsProvider);
    final theme = Theme.of(context);
    final dark = theme.brightness == Brightness.dark;

    return Scaffold(
      body: SafeArea(
        child: topics.when(
          loading: () => const Center(
            child: CircularProgressIndicator(color: AppColors.accent),
          ),
          error: (error, _) => Padding(
            padding: const EdgeInsets.all(AppSpacing.lg),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Text(
                  error is DioException
                      ? 'Could not load topics. Is the API running?'
                      : error.toString(),
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: AppSpacing.md),
                SqButton(
                  label: 'Retry',
                  onPressed: () => ref.invalidate(topicsProvider),
                ),
              ],
            ),
          ),
          data: (items) {
            final ready = items.where((t) => t.questionCount > 0).toList();
            final rest = items.where((t) => t.questionCount == 0).toList();
            return CustomScrollView(
              slivers: [
                SliverToBoxAdapter(
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(
                      AppSpacing.lg,
                      AppSpacing.md,
                      AppSpacing.lg,
                      AppSpacing.sm,
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'Explore',
                          style: theme.textTheme.headlineMedium?.copyWith(
                            fontWeight: FontWeight.w800,
                          ),
                        ),
                        const SizedBox(height: 4),
                        Text(
                          'Browse topics and launch a run',
                          style: theme.textTheme.bodyMedium,
                        ),
                      ],
                    ),
                  ),
                ),
                if (ready.isNotEmpty) ...[
                  SliverToBoxAdapter(
                    child: Padding(
                      padding: const EdgeInsets.fromLTRB(
                        AppSpacing.lg,
                        AppSpacing.md,
                        AppSpacing.lg,
                        AppSpacing.sm,
                      ),
                      child: Text(
                        'Ready to play',
                        style: theme.textTheme.titleLarge,
                      ),
                    ),
                  ),
                  _topicGrid(ready, theme, dark),
                ],
                if (rest.isNotEmpty) ...[
                  SliverToBoxAdapter(
                    child: Padding(
                      padding: const EdgeInsets.fromLTRB(
                        AppSpacing.lg,
                        AppSpacing.lg,
                        AppSpacing.lg,
                        AppSpacing.sm,
                      ),
                      child: Text(
                        'Coming soon',
                        style: theme.textTheme.titleLarge,
                      ),
                    ),
                  ),
                  _topicGrid(rest, theme, dark, muted: true),
                ],
                const SliverToBoxAdapter(child: SizedBox(height: AppSpacing.xxl)),
              ],
            );
          },
        ),
      ),
    );
  }

  Widget _topicGrid(
    List<TopicItem> items,
    ThemeData theme,
    bool dark, {
    bool muted = false,
  }) {
    return SliverPadding(
      padding: const EdgeInsets.symmetric(horizontal: AppSpacing.lg),
      sliver: SliverGrid(
        gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
          crossAxisCount: 2,
          mainAxisSpacing: 12,
          crossAxisSpacing: 12,
          childAspectRatio: 1.15,
        ),
        delegate: SliverChildBuilderDelegate(
          (context, index) {
            final topic = items[index];
            return Material(
              color: dark ? AppColors.surfaceDark : AppColors.surfaceLight,
              borderRadius: BorderRadius.circular(AppRadii.md),
              child: InkWell(
                borderRadius: BorderRadius.circular(AppRadii.md),
                onTap: muted
                    ? null
                    : () => context.push(
                          '/quiz/setup',
                          extra: {
                            'topicId': topic.id,
                            'topicName': topic.name,
                          },
                        ),
                child: Container(
                  padding: const EdgeInsets.all(AppSpacing.md),
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(AppRadii.md),
                    border: Border.all(
                      color: dark ? AppColors.borderDark : AppColors.borderLight,
                    ),
                  ),
                  child: Opacity(
                    opacity: muted ? 0.55 : 1,
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(topic.icon, style: const TextStyle(fontSize: 30)),
                        const Spacer(),
                        Text(
                          topic.name,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.titleMedium?.copyWith(
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                        const SizedBox(height: 4),
                        Text(
                          muted
                              ? 'Bank filling…'
                              : '${topic.questionCount} ready',
                          style: theme.textTheme.bodySmall,
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            );
          },
          childCount: items.length,
        ),
      ),
    );
  }
}
