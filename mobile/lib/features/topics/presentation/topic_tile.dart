import 'package:flutter/material.dart';
import 'package:speedquiz/core/theme/app_motion.dart';
import 'package:speedquiz/core/theme/app_theme.dart';
import 'package:speedquiz/features/topics/data/topics_repository.dart';
import 'package:speedquiz/shared/widgets/sq_widgets.dart';

/// How well stocked a topic's question bank is, shown as a small meter so the
/// grid communicates depth at a glance instead of raw numbers.
enum TopicDepth { thin, solid, deep }

TopicDepth topicDepth(int questionCount) {
  if (questionCount >= 500) return TopicDepth.deep;
  if (questionCount >= 120) return TopicDepth.solid;
  return TopicDepth.thin;
}

/// Square-ish grid tile. The single topic card used everywhere in the app.
class TopicTile extends StatelessWidget {
  const TopicTile({
    super.key,
    required this.topic,
    required this.onTap,
    this.muted = false,
    this.selected = false,
  });

  final TopicItem topic;
  final VoidCallback? onTap;
  final bool muted;
  final bool selected;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final p = theme.sq;
    final depth = topicDepth(topic.questionCount);

    return Opacity(
      opacity: muted ? 0.6 : 1,
      child: SqPressable(
        onTap: onTap,
        enabled: onTap != null,
        pressedScale: 0.96,
        semanticLabel: topic.name,
        child: AnimatedContainer(
          duration: AppMotion.fast,
          curve: AppMotion.standard,
          padding: const EdgeInsets.all(AppSpacing.md),
          decoration: BoxDecoration(
            color: selected ? p.accentWash(0.12) : p.surface,
            borderRadius: BorderRadius.circular(AppRadii.md),
            border: Border.all(
              color: selected ? p.accent : p.border,
              width: selected ? 1.5 : 1,
            ),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Text(topic.icon, style: const TextStyle(fontSize: 26)),
                  const Spacer(),
                  if (selected)
                    Icon(
                      Icons.check_circle_rounded,
                      size: 18,
                      color: p.accent,
                    )
                  else if (!muted && topic.isTrending)
                    const Text('🔥', style: TextStyle(fontSize: 13)),
                ],
              ),
              const Spacer(),
              Text(
                topic.name,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.titleSmall,
              ),
              const SizedBox(height: 6),
              if (muted)
                Row(
                  children: [
                    Icon(
                      Icons.hourglass_bottom_rounded,
                      size: 12,
                      color: p.textFaint,
                    ),
                    const SizedBox(width: 5),
                    Flexible(
                      child: Text(
                        'Coming soon',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.labelSmall?.copyWith(
                          color: p.textFaint,
                        ),
                      ),
                    ),
                  ],
                )
              else
                TopicDepthMeter(depth: depth, count: topic.questionCount),
            ],
          ),
        ),
      ),
    );
  }
}

/// Three-segment meter plus a compact count.
class TopicDepthMeter extends StatelessWidget {
  const TopicDepthMeter({
    super.key,
    required this.depth,
    required this.count,
  });

  final TopicDepth depth;
  final int count;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final p = theme.sq;
    final filled = switch (depth) {
      TopicDepth.thin => 1,
      TopicDepth.solid => 2,
      TopicDepth.deep => 3,
    };
    final tint = switch (depth) {
      TopicDepth.thin => p.textFaint,
      TopicDepth.solid => p.accent,
      TopicDepth.deep => AppColors.gold,
    };

    return Row(
      children: [
        for (var i = 0; i < 3; i++) ...[
          if (i > 0) const SizedBox(width: 3),
          Container(
            width: 12,
            height: 4,
            decoration: BoxDecoration(
              color: i < filled ? tint : p.border,
              borderRadius: BorderRadius.circular(AppRadii.pill),
            ),
          ),
        ],
        const SizedBox(width: 8),
        Flexible(
          child: Text(
            formatCompact(count),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: theme.textTheme.labelSmall?.copyWith(color: p.textFaint),
          ),
        ),
      ],
    );
  }
}

/// Wider card used for trending / featured rails.
class TopicFeatureCard extends StatelessWidget {
  const TopicFeatureCard({
    super.key,
    required this.topic,
    required this.onTap,
  });

  final TopicItem topic;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final p = theme.sq;

    return SqPressable(
      onTap: onTap,
      pressedScale: 0.96,
      semanticLabel: topic.name,
      child: Container(
        width: 172,
        padding: const EdgeInsets.all(AppSpacing.md),
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [
              p.accentWash(p.isDark ? 0.16 : 0.10),
              p.surface,
            ],
          ),
          borderRadius: BorderRadius.circular(AppRadii.md),
          border: Border.all(color: p.accentWash(0.3)),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Text(topic.icon, style: const TextStyle(fontSize: 28)),
                const Spacer(),
                const SqBadge(
                  label: 'HOT',
                  color: AppColors.gold,
                  dense: true,
                ),
              ],
            ),
            const Spacer(),
            Text(
              topic.name,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.titleSmall,
            ),
            const SizedBox(height: 4),
            Text(
              '${formatCompact(topic.questionCount)} questions',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.labelSmall?.copyWith(color: p.textFaint),
            ),
          ],
        ),
      ),
    );
  }
}
