import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:go_router/go_router.dart';
import 'package:speedquiz/core/feedback/audio_service.dart';
import 'package:speedquiz/core/feedback/haptics.dart';
import 'package:speedquiz/core/routing/app_router.dart';
import 'package:speedquiz/core/theme/app_motion.dart';
import 'package:speedquiz/core/theme/app_theme.dart';
import 'package:speedquiz/shared/widgets/sq_widgets.dart';

/// Bottom-tab shell. The bar floats over the content with a frosted blur so
/// screens can scroll underneath it.
class MainShell extends StatefulWidget {
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

  static const _tabs = <_ShellTab>[
    _ShellTab(
      location: Routes.home,
      label: 'Home',
      icon: Icons.home_outlined,
      selectedIcon: Icons.home_rounded,
    ),
    _ShellTab(
      location: Routes.explore,
      label: 'Explore',
      icon: Icons.explore_outlined,
      selectedIcon: Icons.explore_rounded,
    ),
    _ShellTab(
      location: Routes.leaderboard,
      label: 'Ranks',
      icon: Icons.leaderboard_outlined,
      selectedIcon: Icons.leaderboard_rounded,
    ),
    _ShellTab(
      location: Routes.profile,
      label: 'Profile',
      icon: Icons.person_outline_rounded,
      selectedIcon: Icons.person_rounded,
    ),
  ];

  static int _indexForLocation(String location) {
    for (var i = 0; i < _tabs.length; i++) {
      if (location.startsWith(_tabs[i].location)) return i;
    }
    return 0;
  }

  @override
  State<MainShell> createState() => _MainShellState();
}

class _MainShellState extends State<MainShell> {
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

  void _goTab(int i) {
    context.go(MainShell._tabs[i].location);
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
      'Press back again to exit',
      duration: const Duration(milliseconds: 1900),
    );
  }

  @override
  Widget build(BuildContext context) {
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
        bottomNavigationBar: _FloatingNavBar(
          tabs: MainShell._tabs,
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
                AnimatedAlign(
                  duration: AppMotion.normal,
                  curve: AppMotion.emphasized,
                  alignment: Alignment(
                    tabs.length == 1 ? 0 : -1 + 2 * index / (tabs.length - 1),
                    0,
                  ),
                  child: FractionallySizedBox(
                    widthFactor: 1 / tabs.length,
                    child: Center(
                      child: Container(
                        height: 38,
                        width: 54,
                        decoration: BoxDecoration(
                          color: p.accentWash(0.16),
                          borderRadius: BorderRadius.circular(AppRadii.pill),
                          boxShadow: AppShadows.glow(
                            AppColors.accent,
                            strength: 0.16,
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
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
            // item only animates its own icon swap and a small lift.
            AnimatedSlide(
              duration: AppMotion.normal,
              curve: AppMotion.emphasized,
              offset: Offset(0, selected ? -0.06 : 0),
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 5,
                ),
                child: AnimatedSwitcher(
                  duration: AppMotion.fast,
                  transitionBuilder: (child, animation) => ScaleTransition(
                    scale: Tween<double>(begin: 0.6, end: 1).animate(animation),
                    child: FadeTransition(opacity: animation, child: child),
                  ),
                  child: Icon(
                    selected ? tab.selectedIcon : tab.icon,
                    key: ValueKey(selected),
                    size: 22,
                    color: color,
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
