import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:speedquiz/core/i18n/l10n.dart';
import 'package:speedquiz/core/routing/app_router.dart';
import 'package:speedquiz/core/theme/app_theme.dart';
import 'package:speedquiz/features/multiplayer/data/multiplayer_repository.dart';
import 'package:speedquiz/features/multiplayer/presentation/multiplayer_providers.dart';
import 'package:speedquiz/features/topics/data/topics_repository.dart';
import 'package:speedquiz/shared/widgets/sq_widgets.dart';

/// Challenge one player, optionally picking the topic first.
///
/// One path for every entry point — the friends list, and a rematch off the
/// back of a result. They were separate before, which is how a rematch would
/// have ended up with its own topic sheet that looked almost but not quite
/// like the one the player already knew.
///
/// The opponent is *invited*, never enrolled: they get a notification, and the
/// match only begins when they accept it. That is what makes a rematch mutual
/// rather than something one player can inflict on another — and it is the
/// same mechanism as any other challenge, so a rematch offer that arrives
/// while they are on Home behaves exactly like a fresh one and opens straight
/// into the match when tapped.
///
/// Pass [topicId] to skip the picker, which is what a rematch does: "again"
/// means the same quiz, and asking which one would be asking a question the
/// word already answered.
Future<void> startChallenge(
  BuildContext context,
  WidgetRef ref, {
  required String opponentUserId,
  String? topicId,
  bool replaceCurrentRoute = false,
}) async {
  final chosen = topicId ?? await _pickTopic(context, ref);
  if (chosen == null || !context.mounted) return;

  final router = GoRouter.of(context);
  try {
    final match = await ref.read(multiplayerRepositoryProvider).createChallenge(
          topicId: chosen,
          opponentUserId: opponentUserId,
        );
    // The challenge is sent either way; what follows only makes sense if the
    // caller is still on screen. A `WidgetRef` outlives nothing — using one
    // after its widget has gone throws, and the player navigating away mid
    // request is an ordinary thing to do.
    if (!context.mounted) return;
    ref
      ..invalidate(matchListProvider)
      ..invalidate(socialSummaryProvider);
    if (replaceCurrentRoute) {
      // A rematch launched from a result replaces it. Pushing would leave the
      // finished match underneath, so backing out of the new lobby would land
      // on the old scoreboard.
      router.pushReplacement(Routes.matchPath(match.id));
    } else {
      router.push(Routes.matchPath(match.id));
    }
  } catch (error) {
    if (!context.mounted) return;
    SqToast.error(context, context.l10n.matchError(errorCodeOf(error)));
  }
}

/// The topic sheet.
///
/// Only playable topics are offered — challenging someone to an empty bank
/// fails server-side, and a list that can refuse you is worse than a shorter
/// one.
Future<String?> _pickTopic(BuildContext context, WidgetRef ref) async {
  final topics = (await ref.read(topicsProvider.future))
      .where((topic) => topic.isPlayable)
      .toList(growable: false);
  if (!context.mounted) return null;
  if (topics.isEmpty) {
    SqToast.warning(context, context.l10n.homeNoTopicReady);
    return null;
  }

  return showModalBottomSheet<String>(
    context: context,
    backgroundColor: Colors.transparent,
    isScrollControlled: true,
    builder: (sheetContext) => SqSheetShell(
      child: SizedBox(
        height: MediaQuery.sizeOf(sheetContext).height * 0.6,
        child: ListView(
          children: [
            SqSectionHeader(title: sheetContext.l10n.setupPickATopic),
            const SizedBox(height: AppSpacing.sm),
            for (final topic in topics)
              ListTile(
                leading: Text(
                  topic.icon,
                  style: const TextStyle(fontSize: 20),
                ),
                title: Text(topic.name),
                onTap: () => Navigator.of(sheetContext).pop(topic.id),
              ),
          ],
        ),
      ),
    ),
  );
}
