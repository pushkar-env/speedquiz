import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:speedquiz/core/feedback/audio_service.dart';
import 'package:speedquiz/core/feedback/haptics.dart';
import 'package:speedquiz/core/routing/app_router.dart';
import 'package:speedquiz/core/theme/app_motion.dart';
import 'package:speedquiz/core/theme/app_theme.dart';

/// Bottom-tab shell. The bar floats over the content with a frosted blur so
/// screens can scroll underneath it.
class MainShell extends StatelessWidget {
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
    return barHeight +
        MediaQuery.paddingOf(context).bottom +
        AppSpacing.lg;
  }

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

  int _indexForLocation(String location) {
    for (var i = 0; i < _tabs.length; i++) {
      if (location.startsWith(_tabs[i].location)) return i;
    }
    return 0;
  }

  @override
  Widget build(BuildContext context) {
    final location = GoRouterState.of(context).uri.path;
    final index = _indexForLocation(location);
    final p = context.sq;

    return Scaffold(
      backgroundColor: p.background,
      extendBody: true,
      body: child,
      bottomNavigationBar: _FloatingNavBar(
        tabs: _tabs,
        index: index,
        onSelect: (i) {
          if (i == index) return;
          Haptics.tap();
          Sound.tap();
          context.go(_tabs[i].location);
        },
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
            child: Row(
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
            // The pill grows behind the active icon instead of snapping.
            AnimatedContainer(
              duration: AppMotion.normal,
              curve: AppMotion.emphasized,
              padding: EdgeInsets.symmetric(
                horizontal: selected ? 18 : 12,
                vertical: 5,
              ),
              decoration: BoxDecoration(
                color: selected ? p.accentWash(0.16) : Colors.transparent,
                borderRadius: BorderRadius.circular(AppRadii.pill),
              ),
              child: AnimatedSwitcher(
                duration: AppMotion.fast,
                transitionBuilder: (child, animation) => ScaleTransition(
                  scale: animation,
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
