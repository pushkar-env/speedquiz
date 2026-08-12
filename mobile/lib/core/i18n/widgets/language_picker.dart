import 'package:flutter/material.dart';
import 'package:speedquiz/core/i18n/app_language.dart';
import 'package:speedquiz/core/theme/app_motion.dart';
import 'package:speedquiz/core/theme/app_theme.dart';
import 'package:speedquiz/shared/widgets/sq_press.dart';

/// Segmented language selector.
///
/// Each option is labelled with its **endonym** — हिन्दी, not "Hindi". A player
/// who has landed in a language they cannot read has to be able to find their
/// own, and "Hindi" written in English is no help to someone who only reads
/// Devanagari. The English name rides along underneath in the roomy variant so
/// the control is also readable to someone who only reads Latin.
class SqLanguagePicker extends StatelessWidget {
  const SqLanguagePicker({
    super.key,
    required this.selected,
    required this.onChanged,
    this.dense = false,
    this.tint,
    this.availability,
  });

  final AppLanguage selected;
  final ValueChanged<AppLanguage> onChanged;

  /// Chip-sized, for sitting inside a busy screen like quiz setup.
  final bool dense;

  /// Accent colour; defaults to the theme accent.
  final Color? tint;

  /// Optional per-language "is this usable right now?" flag. A false entry is
  /// still selectable — the screen explains why it is empty rather than
  /// silently removing an option and leaving the player to wonder.
  final Map<AppLanguage, bool>? availability;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final p = theme.sq;
    final accent = tint ?? p.accent;

    return Row(
      children: [
        for (final language in AppLanguage.values) ...[
          Expanded(
            child: _Option(
              language: language,
              selected: language == selected,
              dense: dense,
              accent: accent,
              unavailable: availability?[language] == false,
              onTap: () => onChanged(language),
            ),
          ),
          if (language != AppLanguage.values.last)
            SizedBox(width: dense ? 8 : 10),
        ],
      ],
    );
  }
}

class _Option extends StatelessWidget {
  const _Option({
    required this.language,
    required this.selected,
    required this.dense,
    required this.accent,
    required this.unavailable,
    required this.onTap,
  });

  final AppLanguage language;
  final bool selected;
  final bool dense;
  final Color accent;
  final bool unavailable;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final p = theme.sq;
    final color = selected ? accent : p.textSecondary;

    return SqPressable(
      onTap: onTap,
      haptic: false,
      pressedScale: 0.95,
      semanticLabel: language.label,
      child: AnimatedContainer(
        duration: AppMotion.fast,
        curve: AppMotion.standard,
        padding: EdgeInsets.symmetric(vertical: dense ? 9 : 14),
        decoration: BoxDecoration(
          color: selected
              ? accent.withValues(alpha: 0.15)
              : p.surface,
          borderRadius: BorderRadius.circular(AppRadii.md),
          border: Border.all(
            color: selected ? accent.withValues(alpha: 0.5) : p.border,
            width: selected ? 1.5 : 1,
          ),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                if (selected) ...[
                  Icon(Icons.check_rounded, size: dense ? 13 : 15, color: accent),
                  const SizedBox(width: 6),
                ] else if (unavailable) ...[
                  Icon(
                    Icons.hourglass_empty_rounded,
                    size: dense ? 12 : 14,
                    color: p.textFaint,
                  ),
                  const SizedBox(width: 5),
                ],
                Flexible(
                  child: Text(
                    language.nativeLabel,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: (dense
                            ? theme.textTheme.labelMedium
                            : theme.textTheme.titleSmall)
                        ?.copyWith(
                      color: unavailable && !selected ? p.textFaint : color,
                      fontWeight:
                          selected ? FontWeight.w800 : FontWeight.w600,
                    ),
                  ),
                ),
              ],
            ),
            // The endonym alone is unreadable to someone who does not know the
            // script; the English name underneath makes the control usable
            // from either direction.
            if (!dense && language.nativeLabel != language.label) ...[
              const SizedBox(height: 2),
              Text(
                language.label,
                style: theme.textTheme.labelSmall?.copyWith(
                  color: p.textFaint,
                  fontSize: 10.5,
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
