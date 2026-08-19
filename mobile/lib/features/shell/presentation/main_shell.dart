import 'dart:async';
import 'dart:math' as math;
import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:speedquiz/core/feedback/audio_service.dart';
import 'package:speedquiz/core/feedback/haptics.dart';
import 'package:speedquiz/core/i18n/l10n.dart';
import 'package:speedquiz/core/push/local_notifications.dart';
import 'package:speedquiz/core/push/push_service.dart';
import 'package:speedquiz/core/routing/app_router.dart';
import 'package:speedquiz/core/theme/app_motion.dart';
import 'package:speedquiz/core/theme/app_theme.dart';
import 'package:speedquiz/features/multiplayer/presentation/inbox_channel.dart';
import 'package:speedquiz/features/multiplayer/presentation/multiplayer_providers.dart';
import 'package:speedquiz/features/multiplayer/presentation/widgets/notification_popup.dart';
import 'package:speedquiz/shared/widgets/sq_widgets.dart';

/// Bottom-tab shell. The bar floats over the content with a frosted blur so
/// screens can scroll underneath it.
class MainShell extends ConsumerStatefulWidget {
  const MainShell({super.key, required this.child});

  final Widget child;

  /// Height of the floating bar itself.
  static const double barHeight = 64;

  /// Bottom padding a scrolling tab needs so its last item clears the
  /// floating bar *and* the system navigation area.
  ///
  /// The app draws edge-to-edge, so the gesture pill / 3-button bar sits on
  /// top of us — the full inset has to be reserved, not half of it.
  static double contentBottomPadding(BuildContext context) {
    return barHeight + MediaQuery.paddingOf(context).bottom + AppSpacing.lg;
  }

  /// Index of the tab back always falls through to.
  static const _homeIndex = 0;

  /// Labels are resolved per build rather than stored, so switching language
  /// relabels the bar in place.
  static List<_ShellTab> _tabsFor(SqStrings l10n) => <_ShellTab>[
        _ShellTab(
          location: Routes.home,
          label: l10n.tabHome,
          icon: Icons.home_outlined,
          selectedIcon: Icons.home_rounded,
        ),
        _ShellTab(
          location: Routes.explore,
          label: l10n.tabExplore,
          icon: Icons.explore_outlined,
          selectedIcon: Icons.explore_rounded,
        ),
        _ShellTab(
          location: Routes.battle,
          label: l10n.battleTab,
          icon: Icons.sports_esports_outlined,
          selectedIcon: Icons.sports_esports_rounded,
        ),
        _ShellTab(
          location: Routes.leaderboard,
          label: l10n.tabRanks,
          icon: Icons.leaderboard_outlined,
          selectedIcon: Icons.leaderboard_rounded,
        ),
        _ShellTab(
          location: Routes.profile,
          label: l10n.tabProfile,
          icon: Icons.person_outline_rounded,
          selectedIcon: Icons.person_rounded,
        ),
      ];

  /// Route order, for index lookups that must not depend on a BuildContext.
  static const _tabLocations = <String>[
    Routes.home,
    Routes.explore,
    Routes.battle,
    Routes.leaderboard,
    Routes.profile,
  ];

  static int _indexForLocation(String location) {
    for (var i = 0; i < _tabLocations.length; i++) {
      if (location.startsWith(_tabLocations[i])) return i;
    }
    return 0;
  }

  @override
  ConsumerState<MainShell> createState() => _MainShellState();
}

class _MainShellState extends ConsumerState<MainShell> {
  /// Tabs visited before the current one, oldest first. Android back unwinds
  /// this the way every other tabbed app on the store does — it must not drop
  /// the player straight out to the launcher.
  final List<int> _history = [];

  /// Deepest sensible history; beyond this, back just heads for Home.
  static const _maxHistory = 6;

  int _index = 0;

  /// Set while *we* are the ones changing tabs, so unwinding the history does
  /// not push the tab we just left back onto it.
  bool _unwinding = false;

  DateTime? _exitArmedAt;

  /// Refreshes the social counts when the app comes back to the foreground.
  ///
  /// This, plus the refresh on mount and the inbox channel below, is what
  /// replaces a background poller: the count only has to be right at the moment
  /// someone can see it, and coming back from the launcher is exactly that
  /// moment — it is also when a push they just tapped, or ignored, has changed
  /// it.
  late final AppLifecycleListener _lifecycle = AppLifecycleListener(
    onResume: () {
      ref.invalidate(socialSummaryProvider);
      // A socket almost never survives being backgrounded. Skip the backoff:
      // the player is looking at the screen right now.
      ref.read(inboxChannelProvider).reconnectNow();
    },
  );

  StreamSubscription<PushAlert>? _push;

  @override
  void initState() {
    super.initState();
    _lifecycle;
    _push = ref.read(pushServiceProvider).foregroundMessages.listen(_onPush);
  }

  @override
  void dispose() {
    unawaited(_push?.cancel());
    _lifecycle.dispose();
    super.dispose();
  }

  /// A push that arrived with the app open.
  ///
  /// Only acted on when the inbox socket is down. With it up, the same event
  /// has already been delivered over the socket and handled below — reacting to
  /// both would show the player two banners for one thing.
  void _onPush(PushAlert alert) {
    if (!mounted) return;
    if (ref.read(inboxChannelProvider).isConnected) return;

    ref.invalidate(socialSummaryProvider);
    final brief = NotificationBrief.fromPush(
      type: alert.type,
      title: alert.title,
      body: alert.body,
      deepLink: alert.deepLink,
      fallbackActor: context.l10n.player,
    );
    if (brief == null) return;
    NotificationPopup.show(context, brief);
  }

  /// Surface something that just arrived.
  ///
  /// Every type gets the same banner now. It used to be a modal for a
  /// challenge and a one-line toast for everything else, which meant a friend
  /// request announced itself with prose the player could not act on and a
  /// result announced itself not at all — while the one kind that did get a
  /// dialog got it thrown over whatever they were doing.
  ///
  /// [NotificationPopup] is top-anchored, non-blocking and closable, so it is
  /// safe to raise from anywhere in the app including a live round; the two
  /// kinds someone is waiting on an answer to carry their buttons inline. It
  /// goes into the *root* overlay, which is why it appears over the match
  /// screen and the friends list too, not only over a tab.
  void _onInboxEvent(InboxEvent event) {
    if (!mounted) return;
    final brief =
        NotificationBrief.fromEvent(event, fallbackActor: context.l10n.player);

    if (_isForeground) {
      NotificationPopup.show(context, brief);
      return;
    }
    _postToSystemTray(brief);
  }

  bool get _isForeground =>
      WidgetsBinding.instance.lifecycleState == AppLifecycleState.resumed;

  /// The app is not on screen, so a banner would be shown to nobody.
  ///
  /// Only when this build has no Firebase project. With one, the server has
  /// already sent the same event as a push and Android has already drawn it in
  /// the tray — posting our own as well is how a player ends up with two
  /// notifications for one challenge. Without one, the socket is the only
  /// thing that knows, and staying silent means the event is simply lost until
  /// they next open the app.
  ///
  /// Same channel the push would have used, so silencing it in system settings
  /// silences both.
  void _postToSystemTray(NotificationBrief brief) {
    if (ref.read(pushServiceProvider).isConfigured) return;
    final l10n = context.l10n;
    unawaited(
      ref.read(localNotificationServiceProvider).showNow(
            // Keyed to the notification, so the same event arriving twice
            // replaces its own entry rather than stacking a duplicate.
            id: brief.notificationId.hashCode,
            title: brief.title(l10n),
            body: brief.body(l10n),
            deepLink: brief.target,
          ),
    );
  }

  void _goTab(int i) {
    context.go(MainShell._tabLocations[i]);
  }

  void _select(int i) {
    if (i == _index) return;
    Haptics.tap();
    Sound.tap();
    _goTab(i);
  }

  /// System back. Walks back through visited tabs, then asks before exiting.
  void _handleBack() {
    if (_history.isNotEmpty) {
      _unwinding = true;
      _goTab(_history.removeLast());
      return;
    }
    if (_index != MainShell._homeIndex) {
      _unwinding = true;
      _goTab(MainShell._homeIndex);
      return;
    }

    // On Home with nothing to unwind: confirm rather than vanish.
    final now = DateTime.now();
    final armed = _exitArmedAt;
    if (armed != null && now.difference(armed) < const Duration(seconds: 2)) {
      SystemNavigator.pop();
      return;
    }
    _exitArmedAt = now;
    Haptics.tap();
    SqToast.show(
      context,
      context.l10n.pressBackAgainToExit,
      duration: const Duration(milliseconds: 1900),
    );
  }

  @override
  Widget build(BuildContext context) {
    // Listened to here rather than on any one screen because the point is that
    // a challenge reaches the player wherever they are in the app. This is also
    // what holds the inbox socket open — it lives exactly as long as the shell.
    ref.listen(inboxEventsProvider, (_, next) {
      final event = next.valueOrNull;
      if (event != null) _onInboxEvent(event);
    });

    final location = GoRouterState.of(context).uri.path;
    final index = MainShell._indexForLocation(location);

    // Bookkeeping, not state: the tab is owned by the router, so every route
    // change is observed here rather than only in the tab bar's callback —
    // screens jump between tabs directly too (Home's "ALL" opens Explore).
    if (index != _index) {
      if (_unwinding) {
        _unwinding = false;
      } else {
        _history.add(_index);
        if (_history.length > _maxHistory) _history.removeAt(0);
      }
      _index = index;
      _exitArmedAt = null;
    }

    final p = context.sq;

    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _handleBack();
      },
      child: Scaffold(
        backgroundColor: p.background,
        extendBody: true,
        body: widget.child,
        // No counts on the bar. A badge on a tab says "something is somewhere
        // in here" and leaves the player to find it; the same number on the
        // control that actually opens the thing — the inbox bell on Home, the
        // friends button in Battle — says where. Two of them competing for the
        // same glance is one too many.
        bottomNavigationBar: _FloatingNavBar(
          tabs: MainShell._tabsFor(context.l10n),
          index: index,
          onSelect: _select,
        ),
      ),
    );
  }
}

class _ShellTab {
  const _ShellTab({
    required this.location,
    required this.label,
    required this.icon,
    required this.selectedIcon,
  });

  final String location;
  final String label;
  final IconData icon;
  final IconData selectedIcon;
}

class _FloatingNavBar extends StatelessWidget {
  const _FloatingNavBar({
    required this.tabs,
    required this.index,
    required this.onSelect,
  });

  final List<_ShellTab> tabs;
  final int index;
  final ValueChanged<int> onSelect;

  @override
  Widget build(BuildContext context) {
    final p = context.sq;
    final bottomInset = MediaQuery.paddingOf(context).bottom;

    return Padding(
      // Clear the whole system inset. Halving it put the bar underneath the
      // Android 3-button navigation strip.
      padding: EdgeInsets.fromLTRB(
        AppSpacing.md,
        0,
        AppSpacing.md,
        bottomInset + AppSpacing.sm,
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(AppRadii.xl),
        child: BackdropFilter(
          filter: ImageFilter.blur(sigmaX: 18, sigmaY: 18),
          child: Container(
            height: MainShell.barHeight,
            decoration: BoxDecoration(
              color: p.surface.withValues(alpha: p.isDark ? 0.78 : 0.86),
              borderRadius: BorderRadius.circular(AppRadii.xl),
              border: Border.all(color: p.border),
              boxShadow: AppShadows.soft(p),
            ),
            child: Stack(
              children: [
                // One indicator that travels between tabs, rather than four
                // that fade independently — the movement is what sells it.
                _NavIndicator(index: index, count: tabs.length),
                Row(
                  children: [
                    for (var i = 0; i < tabs.length; i++)
                      Expanded(
                        child: _NavItem(
                          tab: tabs[i],
                          selected: i == index,
                          onTap: () => onSelect(i),
                        ),
                      ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// The travelling selection capsule.
///
/// Sized from the real item width rather than a fixed 54px, which is what made
/// the old indicator look shrunken inside its slot. It overshoots slightly on
/// arrival and squashes along the direction of travel, so switching tabs has
/// weight instead of being a linear slide.
class _NavIndicator extends StatefulWidget {
  const _NavIndicator({required this.index, required this.count});

  final int index;
  final int count;

  @override
  State<_NavIndicator> createState() => _NavIndicatorState();
}

class _NavIndicatorState extends State<_NavIndicator>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;
  late Animation<double> _position;
  late double _from = widget.index.toDouble();

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 460),
    );
    _position = AlwaysStoppedAnimation(widget.index.toDouble());
  }

  @override
  void didUpdateWidget(_NavIndicator old) {
    super.didUpdateWidget(old);
    if (old.index == widget.index) return;

    _from = _position.value;
    _position = Tween<double>(
      begin: _from,
      end: widget.index.toDouble(),
    ).animate(
      CurvedAnimation(
        parent: _controller,
        // A little overshoot on the way in reads as momentum being absorbed.
        curve: Curves.easeOutBack,
      ),
    );

    if (MediaQuery.disableAnimationsOf(context)) {
      _controller.value = 1;
    } else {
      _controller
        ..reset()
        ..forward();
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final p = context.sq;

    return Positioned.fill(
      child: IgnorePointer(
        child: LayoutBuilder(
          builder: (context, constraints) {
            final slot = constraints.maxWidth / widget.count;

            return RepaintBoundary(
              child: AnimatedBuilder(
                animation: _position,
                builder: (context, _) {
                  final at = _position.value;
                  // Stretch along the axis of travel, proportional to speed —
                  // the capsule elongates as it leaves and settles on arrival.
                  final speed = (at - _from).abs().clamp(0.0, 1.0);
                  final travel = _controller.isAnimating
                      ? math.sin(_controller.value * math.pi) * speed
                      : 0.0;
                  final width = slot * 0.82 * (1 + travel * 0.18);
                  // Tall enough to contain the icon *and* the label with real
                  // breathing room. The previous 40px sat shorter than the
                  // 44px content column, so it clipped through the label and
                  // read as vertically squashed.
                  final height =
                      (MainShell.barHeight - 12) * (1 - travel * 0.08);

                  return Stack(
                    children: [
                      Positioned(
                        left: at * slot + (slot - width) / 2,
                        top: (MainShell.barHeight - height) / 2,
                        width: width,
                        height: height,
                        child: DecoratedBox(
                          decoration: BoxDecoration(
                            gradient: LinearGradient(
                              begin: Alignment.topCenter,
                              end: Alignment.bottomCenter,
                              colors: [
                                p.accentWash(0.34),
                                p.accentWash(0.10),
                              ],
                            ),
                            borderRadius: BorderRadius.circular(AppRadii.lg),
                            border: Border.all(
                              color: AppColors.accent.withValues(alpha: 0.40),
                              width: 1.2,
                            ),
                            boxShadow: AppShadows.glow(
                              AppColors.accent,
                              strength: 0.24 + travel * 0.18,
                            ),
                          ),
                          // A bright top edge, the way a lit physical key
                          // catches light — this is what sells "premium"
                          // rather than "a coloured rectangle".
                          child: Align(
                            alignment: Alignment.topCenter,
                            child: FractionallySizedBox(
                              widthFactor: 0.55,
                              child: Container(
                                height: 2,
                                margin: const EdgeInsets.only(top: 1),
                                decoration: BoxDecoration(
                                  borderRadius:
                                      BorderRadius.circular(AppRadii.pill),
                                  gradient: LinearGradient(
                                    colors: [
                                      AppColors.accent.withValues(alpha: 0),
                                      AppColors.accent.withValues(alpha: 0.85),
                                      AppColors.accent.withValues(alpha: 0),
                                    ],
                                  ),
                                ),
                              ),
                            ),
                          ),
                        ),
                      ),
                    ],
                  );
                },
              ),
            );
          },
        ),
      ),
    );
  }
}

class _NavItem extends StatelessWidget {
  const _NavItem({
    required this.tab,
    required this.selected,
    required this.onTap,
  });

  final _ShellTab tab;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final p = theme.sq;
    final color = selected ? p.accent : p.textSecondary;

    return Semantics(
      selected: selected,
      button: true,
      label: tab.label,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onTap,
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            // The indicator itself is drawn once, behind the whole row; each
            // item only animates its own icon swap, a small lift and a scale
            // bump so the selected tab reads as raised off the bar.
            AnimatedSlide(
              duration: AppMotion.normal,
              curve: AppMotion.emphasized,
              offset: Offset(0, selected ? -0.08 : 0),
              child: AnimatedScale(
                duration: AppMotion.normal,
                curve: Curves.easeOutBack,
                scale: selected ? 1.14 : 1,
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 12,
                    vertical: 2,
                  ),
                  child: AnimatedSwitcher(
                    duration: AppMotion.fast,
                    transitionBuilder: (child, animation) => ScaleTransition(
                      scale:
                          Tween<double>(begin: 0.6, end: 1).animate(animation),
                      child: FadeTransition(opacity: animation, child: child),
                    ),
                    child: Icon(
                      key: ValueKey(selected),
                      selected ? tab.selectedIcon : tab.icon,
                      size: 22,
                      color: color,
                    ),
                  ),
                ),
              ),
            ),
            const SizedBox(height: 3),
            AnimatedDefaultTextStyle(
              duration: AppMotion.fast,
              style: theme.textTheme.labelSmall!.copyWith(
                color: color,
                fontWeight: selected ? FontWeight.w800 : FontWeight.w600,
                fontSize: 10.5,
              ),
              child: Text(tab.label),
            ),
          ],
        ),
      ),
    );
  }
}


