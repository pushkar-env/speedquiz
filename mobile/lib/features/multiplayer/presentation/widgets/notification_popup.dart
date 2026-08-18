import 'dart:async';
import 'dart:collection';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:speedquiz/core/feedback/audio_service.dart';
import 'package:speedquiz/core/feedback/haptics.dart';
import 'package:speedquiz/core/i18n/l10n.dart';
import 'package:speedquiz/core/routing/app_router.dart';
import 'package:speedquiz/core/theme/app_motion.dart';
import 'package:speedquiz/core/theme/app_theme.dart';
import 'package:speedquiz/features/multiplayer/data/multiplayer_repository.dart';
import 'package:speedquiz/features/multiplayer/domain/multiplayer_models.dart';
import 'package:speedquiz/features/multiplayer/presentation/inbox_channel.dart';
import 'package:speedquiz/features/multiplayer/presentation/multiplayer_providers.dart';
import 'package:speedquiz/features/multiplayer/presentation/notifications_screen.dart';
import 'package:speedquiz/features/social/data/social_repository.dart';
import 'package:speedquiz/shared/widgets/sq_avatar.dart';
import 'package:speedquiz/shared/widgets/sq_button.dart';
import 'package:speedquiz/shared/widgets/sq_press.dart';
import 'package:speedquiz/shared/widgets/sq_toast.dart';

/// A notification reduced to what a banner needs to draw and act on.
///
/// Built from the live socket event rather than from the stored row, because
/// the whole point of the banner is that it appears before anything has been
/// fetched. Nothing here is server-written prose — the copy is resolved from
/// the type at draw time, so a banner reads in the language the app is set to
/// right now.
@immutable
class NotificationBrief {
  const NotificationBrief({
    required this.type,
    required this.actorName,
    this.notificationId,
    this.actorUserId,
    this.matchId,
    this.requestId,
    this.deepLink,
    this.payload = const {},
    this.titleOverride,
    this.bodyOverride,
  });

  factory NotificationBrief.fromEvent(
    InboxEvent event, {
    required String fallbackActor,
  }) {
    return NotificationBrief(
      type: event.type,
      actorName: event.actorName ?? fallbackActor,
      notificationId: event.notificationId,
      actorUserId: event.actorUserId,
      matchId: event.matchId,
      requestId: event.requestId,
      deepLink: event.deepLink,
      payload: event.payload,
    );
  }

  /// A push that arrived with the app open and the inbox socket down.
  ///
  /// The socket is the path that carries structure — who, which match, which
  /// request. A push carries prose the server already rendered in the language
  /// this device registered, so that prose is used verbatim rather than
  /// rebuilt from a type and an actor we do not have. Returns null when there
  /// is nothing to say, which is every data-only message.
  static NotificationBrief? fromPush({
    required String? type,
    required String? title,
    required String? body,
    required String? deepLink,
    required String fallbackActor,
  }) {
    if (body == null || body.isEmpty) return null;
    return NotificationBrief(
      type: appNotificationTypeFromWire(type),
      actorName: fallbackActor,
      deepLink: deepLink,
      titleOverride: title,
      bodyOverride: body,
    );
  }

  final AppNotificationType type;
  final String actorName;
  final String? notificationId;
  final String? actorUserId;
  final String? matchId;
  final String? requestId;
  final String? deepLink;
  final Map<String, dynamic> payload;

  /// Server-rendered copy, set only on the push fallback. See [fromPush].
  final String? titleOverride;
  final String? bodyOverride;

  String get topicName {
    final topic = payload['topic_name'];
    return topic is String ? topic : '';
  }

  /// Headline. Short enough to survive one line at 135% text scale.
  String title(SqStrings l10n) => titleOverride ?? switch (type) {
        AppNotificationType.friendRequest => l10n.notificationTitleFriendRequest,
        AppNotificationType.friendAccepted =>
          l10n.notificationTitleFriendAccepted,
        AppNotificationType.matchInvite => l10n.lobbyChallengeTitle,
        AppNotificationType.matchYourTurn => l10n.notificationTitleYourTurn,
        AppNotificationType.matchResult => l10n.notificationTitleMatchResult,
        AppNotificationType.matchExpiring => l10n.notificationTitleExpiring,
      };

  /// The detail line — who, and what about.
  String body(SqStrings l10n) => bodyOverride ?? switch (type) {
        AppNotificationType.friendRequest =>
          l10n.notificationFriendRequest(actorName),
        AppNotificationType.friendAccepted =>
          l10n.notificationFriendAccepted(actorName),
        AppNotificationType.matchInvite =>
          l10n.notificationMatchInvite(actorName, topicName),
        AppNotificationType.matchYourTurn =>
          l10n.notificationYourTurn(actorName),
        AppNotificationType.matchResult =>
          l10n.notificationMatchResult(actorName),
        AppNotificationType.matchExpiring =>
          l10n.notificationYourTurn(actorName),
      };

  String get glyph => switch (type) {
        AppNotificationType.friendRequest => '👋',
        AppNotificationType.friendAccepted => '🤝',
        AppNotificationType.matchInvite => '⚔️',
        AppNotificationType.matchYourTurn => '⏳',
        AppNotificationType.matchResult => '🏁',
        AppNotificationType.matchExpiring => '⌛',
      };

  /// How long this sits on screen before retiring itself.
  ///
  /// A challenge gets double: there is a player in a lobby on the other end of
  /// it, and it is the only kind whose value goes to zero if it is missed.
  Duration get dwell => type == AppNotificationType.matchInvite
      ? const Duration(seconds: 12)
      : const Duration(seconds: 6);

  /// Where tapping the card goes, if anywhere.
  String? get target {
    final link = deepLink;
    if (link != null && link.isNotEmpty) return link;
    final id = matchId;
    return id == null ? null : Routes.matchPath(id);
  }
}

/// The in-app heads-up banner.
///
/// Why a banner and not a dialog
/// -----------------------------
/// Every notification now surfaces the moment it lands, including the ones
/// that used to get a one-line toast with no way to act on them. A modal for
/// each would be worse than the toast was: it steals focus, and dropping one
/// over a running round clock is how someone loses a game they were winning.
/// This is what the OS does for the same problem — top-anchored, non-blocking,
/// self-retiring, and closable by the player at any point.
///
/// One at a time, with the rest queued. Two banners arriving together used to
/// mean two stacked modals; here the second waits its turn, and a burst beyond
/// [_maxQueued] is dropped on the floor rather than held against the player as
/// a queue they have to sit through — the inbox has all of it anyway.
abstract final class NotificationPopup {
  static const _maxQueued = 3;

  static final Queue<NotificationBrief> _pending = Queue<NotificationBrief>();
  static OverlayEntry? _entry;

  /// Set while the banner is animating itself out, so a queued one does not
  /// get inserted on top of the one leaving.
  static bool _closing = false;

  static bool get isShowing => _entry != null;

  static void show(BuildContext context, NotificationBrief brief) {
    final overlay = Overlay.maybeOf(context, rootOverlay: true);
    if (overlay == null) return;

    if (_entry != null || _closing) {
      // Same notification twice — a socket reconnect replaying, or a push
      // racing the socket — is one banner, not two.
      if (_pending.any((queued) => _isSame(queued, brief))) return;
      if (_pending.length >= _maxQueued) return;
      _pending.add(brief);
      return;
    }

    _insert(overlay, brief);
  }

  /// Drop everything on the floor — for signing out, where the queue belongs
  /// to an account that has left.
  static void clear() {
    _pending.clear();
    _entry?.remove();
    _entry = null;
    _closing = false;
  }

  static bool _isSame(NotificationBrief a, NotificationBrief b) {
    if (a.notificationId != null && b.notificationId != null) {
      return a.notificationId == b.notificationId;
    }
    return a.type == b.type &&
        a.matchId == b.matchId &&
        a.actorUserId == b.actorUserId;
  }

  static void _insert(OverlayState overlay, NotificationBrief brief) {
    late final OverlayEntry entry;
    entry = OverlayEntry(
      builder: (context) => _Banner(
        brief: brief,
        onRetire: () {
          if (_entry != entry) return;
          _closing = true;
          entry.remove();
          _entry = null;
          _closing = false;
          if (_pending.isEmpty) return;
          final next = _pending.removeFirst();
          // A beat between banners, so the second reads as a new arrival
          // rather than the first one changing its mind.
          Future<void>.delayed(const Duration(milliseconds: 180), () {
            if (_entry != null || !overlay.mounted) return;
            _insert(overlay, next);
          });
        },
      ),
    );
    _entry = entry;
    overlay.insert(entry);
  }
}

class _Banner extends StatefulWidget {
  const _Banner({required this.brief, required this.onRetire});

  final NotificationBrief brief;
  final VoidCallback onRetire;

  @override
  State<_Banner> createState() => _BannerState();
}

class _BannerState extends State<_Banner>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: AppMotion.normal,
    reverseDuration: AppMotion.fast,
  );

  /// Built once. A `CurvedAnimation` created inside `build` registers a
  /// listener on every rebuild and never releases them.
  late final Animation<double> _curved = CurvedAnimation(
    parent: _controller,
    curve: Curves.easeOutBack,
    reverseCurve: AppMotion.exit,
  );

  Timer? _dwell;

  /// Vertical drag offset while the player is flicking it away.
  double _drag = 0;

  /// Set once an action has been taken, so the retire animation cannot fire
  /// a second dismissal on top of an in-flight request.
  bool _spent = false;

  /// Riverpod, decoupled from this widget's lifetime.
  ///
  /// Every action here animates the card away and *then* waits on a request,
  /// so the continuation runs against a disposed `State` — and a disposed
  /// `WidgetRef` throws on use. The container behind it does not go anywhere,
  /// which is what lets an accepted challenge still invalidate the match list
  /// after the banner that accepted it has left the tree.
  late final ProviderContainer _providers =
      ProviderScope.containerOf(context, listen: false);

  /// Captured for the same reason: `widget` is unreadable once the element
  /// unmounts.
  late final VoidCallback _onRetire = widget.onRetire;

  @override
  void initState() {
    super.initState();
    _controller.forward();
    Haptics.tap();
    if (widget.brief.type == AppNotificationType.matchInvite) {
      // The one arrival worth hearing across the room.
      Sound.play(Sfx.finish);
    }
    _armDwell();
  }

  void _armDwell() {
    _dwell?.cancel();
    _dwell = Timer(widget.brief.dwell, _retire);
  }

  void _holdDwell() => _dwell?.cancel();

  @override
  void dispose() {
    _dwell?.cancel();
    _controller.dispose();
    super.dispose();
  }

  /// Slide out and take the entry with it.
  Future<void> _retire() async {
    _dwell?.cancel();
    if (!mounted) {
      _onRetire();
      return;
    }
    await _controller.reverse();
    _onRetire();
  }

  /// Everything the player can do here first marks the row read: they have
  /// demonstrably seen it, and leaving the bell counting it would be a lie.
  Future<void> _markRead() async {
    final id = widget.brief.notificationId;
    if (id == null) return;
    try {
      await _providers
          .read(socialRepositoryProvider)
          .markNotificationsRead(id: id);
    } catch (_) {
      // The count self-corrects on the next summary fetch. Losing a banner
      // action because the read receipt failed would be the worse trade.
      return;
    }
    _providers
      ..invalidate(socialSummaryProvider)
      ..invalidate(notificationsProvider);
  }

  void _dismiss() {
    Haptics.tap();
    unawaited(_retire());
  }

  /// Tap on the body: read it, go where it points.
  Future<void> _open() async {
    if (_spent) return;
    _spent = true;
    final target = widget.brief.target;
    final router = GoRouter.of(context);
    unawaited(_markRead());
    await _retire();
    if (target != null && target.isNotEmpty) router.push(target);
  }

  /// A context that outlives this banner.
  ///
  /// Every action below animates the card away *before* its request settles,
  /// so by the time there is an error to report this widget is gone and its
  /// own context is dead. The root navigator's is not, and it sits under the
  /// same `ScaffoldMessenger`, `Theme` and `Localizations`.
  BuildContext get _host => Navigator.of(context, rootNavigator: true).context;

  Future<void> _respondToChallenge({required bool accept}) async {
    final matchId = widget.brief.matchId;
    if (matchId == null || _spent) return;
    _spent = true;

    final router = GoRouter.of(context);
    final host = _host;
    unawaited(_markRead());
    await _retire();

    try {
      await _providers
          .read(multiplayerRepositoryProvider)
          .respond(matchId, accept: accept);
    } catch (error) {
      if (host.mounted) {
        SqToast.error(host, host.l10n.matchError(errorCodeOf(error)));
      }
      return;
    }
    _providers
      ..invalidate(matchListProvider)
      ..invalidate(socialSummaryProvider);
    if (accept) router.push(Routes.matchPath(matchId));
  }

  Future<void> _respondToFriendRequest({required bool accept}) async {
    final requestId = widget.brief.requestId;
    if (requestId == null || _spent) return;
    _spent = true;

    final host = _host;
    final repository = _providers.read(socialRepositoryProvider);
    unawaited(_markRead());
    await _retire();

    try {
      if (accept) {
        await repository.acceptRequest(requestId);
      } else {
        await repository.declineRequest(requestId);
      }
    } catch (error) {
      if (host.mounted) {
        SqToast.error(host, host.l10n.matchError(errorCodeOf(error)));
      }
      return;
    }
    _providers
      ..invalidate(friendRequestsProvider)
      ..invalidate(friendsProvider)
      ..invalidate(socialSummaryProvider);
    if (accept && host.mounted) {
      SqToast.success(
        host,
        host.l10n.notificationFriendAccepted(widget.brief.actorName),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final brief = widget.brief;

    return Positioned(
      top: MediaQuery.paddingOf(context).top + AppSpacing.sm,
      left: AppSpacing.md,
      right: AppSpacing.md,
      child: AnimatedBuilder(
        animation: _curved,
        builder: (context, child) {
          final t = _curved.value.clamp(0.0, 1.0);
          return Transform.translate(
            // Enters from above its own resting place; `_drag` rides on top so
            // a flick upward keeps following the finger.
            offset: Offset(0, -110 * (1 - t) + _drag),
            child: Opacity(opacity: t, child: child),
          );
        },
        child: Material(
          color: Colors.transparent,
          child: Listener(
            // The countdown is the player's, not the animation's: a finger on
            // the card means they are reading it.
            onPointerDown: (_) => _holdDwell(),
            onPointerUp: (_) => _armDwell(),
            onPointerCancel: (_) => _armDwell(),
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onVerticalDragUpdate: (details) {
                // Upward only, and it stiffens as it goes so the card does not
                // fly off the top on a stray scroll.
                setState(() {
                  _drag = (_drag + details.delta.dy).clamp(-140.0, 12.0);
                });
              },
              onVerticalDragEnd: (details) {
                final flicked = details.primaryVelocity != null &&
                    details.primaryVelocity! < -420;
                if (flicked || _drag < -46) {
                  _dismiss();
                } else {
                  setState(() => _drag = 0);
                }
              },
              child: _Card(
                brief: brief,
                onOpen: _open,
                onDismiss: _dismiss,
                onChallenge: brief.matchId == null ? null : _respondToChallenge,
                onFriendRequest:
                    brief.requestId == null ? null : _respondToFriendRequest,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// The card itself. Split out so the gesture layer above stays readable.
class _Card extends StatelessWidget {
  const _Card({
    required this.brief,
    required this.onOpen,
    required this.onDismiss,
    this.onChallenge,
    this.onFriendRequest,
  });

  final NotificationBrief brief;
  final VoidCallback onOpen;
  final VoidCallback onDismiss;
  final Future<void> Function({required bool accept})? onChallenge;
  final Future<void> Function({required bool accept})? onFriendRequest;

  /// Inline accept/decline, for the two kinds where somebody is waiting on an
  /// answer. Everything else is informational and gets the card tap.
  Future<void> Function({required bool accept})? get _responder =>
      switch (brief.type) {
        AppNotificationType.matchInvite => onChallenge,
        AppNotificationType.friendRequest => onFriendRequest,
        _ => null,
      };

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final p = theme.sq;
    final l10n = context.l10n;
    final responder = _responder;
    final accent = brief.type == AppNotificationType.matchInvite
        ? AppColors.danger
        : p.accent;

    return Container(
      decoration: BoxDecoration(
        color: p.surfaceElevated,
        borderRadius: BorderRadius.circular(AppRadii.md),
        border: Border.all(color: accent.withValues(alpha: 0.45)),
        boxShadow: [
          ...AppShadows.lifted(p),
          ...AppShadows.glow(accent, strength: 0.18),
        ],
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          SqPressable(
            onTap: onOpen,
            pressedScale: 0.99,
            haptic: false,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(
                AppSpacing.md,
                AppSpacing.md,
                AppSpacing.sm,
                AppSpacing.sm,
              ),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  SqAvatar(
                    name: brief.actorName,
                    seed: brief.actorUserId ?? brief.notificationId,
                    size: 40,
                    ring: true,
                  ),
                  const SizedBox(width: AppSpacing.md),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            Text(
                              brief.glyph,
                              style: const TextStyle(fontSize: 13),
                            ),
                            const SizedBox(width: 6),
                            Flexible(
                              child: Text(
                                brief.title(l10n),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: theme.textTheme.labelMedium?.copyWith(
                                  color: accent,
                                  fontWeight: FontWeight.w800,
                                  letterSpacing: 0.6,
                                ),
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 3),
                        Text(
                          brief.body(l10n),
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.bodyMedium?.copyWith(
                            color: p.textPrimary,
                            fontWeight: FontWeight.w600,
                            height: 1.25,
                          ),
                        ),
                      ],
                    ),
                  ),
                  // Always present, on every type: the player closes this, it
                  // does not close only on its own terms.
                  Semantics(
                    button: true,
                    label: l10n.close,
                    child: IconButton(
                      onPressed: onDismiss,
                      visualDensity: VisualDensity.compact,
                      padding: EdgeInsets.zero,
                      constraints: const BoxConstraints(
                        minWidth: 34,
                        minHeight: 34,
                      ),
                      icon: Icon(
                        Icons.close_rounded,
                        size: 18,
                        color: p.textFaint,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
          if (responder != null)
            Padding(
              padding: const EdgeInsets.fromLTRB(
                AppSpacing.md,
                0,
                AppSpacing.md,
                AppSpacing.md,
              ),
              child: Row(
                children: [
                  Expanded(
                    child: SqButton(
                      label: l10n.lobbyAccept,
                      height: 42,
                      onPressed: () => responder(accept: true),
                    ),
                  ),
                  const SizedBox(width: AppSpacing.sm),
                  Expanded(
                    child: SqGhostButton(
                      label: brief.type == AppNotificationType.friendRequest
                          ? l10n.notificationIgnore
                          : l10n.lobbyDecline,
                      onPressed: () => responder(accept: false),
                    ),
                  ),
                ],
              ),
            )
          else
            // A hairline countdown, so a card that vanishes on its own does not
            // look like it was dismissed by something the player did.
            _DwellBar(duration: brief.dwell, color: accent),
        ],
      ),
    );
  }
}

class _DwellBar extends StatefulWidget {
  const _DwellBar({required this.duration, required this.color});

  final Duration duration;
  final Color color;

  @override
  State<_DwellBar> createState() => _DwellBarState();
}

class _DwellBarState extends State<_DwellBar>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: widget.duration,
  )..forward();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (MediaQuery.disableAnimationsOf(context)) {
      return const SizedBox(height: AppSpacing.sm);
    }
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        AppSpacing.md,
        0,
        AppSpacing.md,
        AppSpacing.sm,
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(AppRadii.pill),
        child: AnimatedBuilder(
          animation: _controller,
          builder: (context, _) => LinearProgressIndicator(
            value: 1 - _controller.value,
            minHeight: 2,
            backgroundColor: widget.color.withValues(alpha: 0.12),
            valueColor: AlwaysStoppedAnimation(
              widget.color.withValues(alpha: 0.55),
            ),
          ),
        ),
      ),
    );
  }
}
