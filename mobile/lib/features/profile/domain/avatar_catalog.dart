import 'package:flutter/material.dart';
import 'package:speedquiz/core/theme/app_theme.dart';

/// A pickable avatar identity: a gradient plus a glyph.
///
/// The server stores only the [id] string (`avatar_id`), so the catalog can
/// grow without a migration. Unknown ids fall back to a deterministic pick.
class AvatarPreset {
  const AvatarPreset({
    required this.id,
    required this.name,
    required this.glyph,
    required this.colors,
  });

  final String id;
  final String name;
  final String glyph;
  final List<Color> colors;

  LinearGradient get gradient => LinearGradient(
        begin: Alignment.topLeft,
        end: Alignment.bottomRight,
        colors: colors,
      );
}

abstract final class AvatarCatalog {
  /// `avatar_01` is what the backend seeds new profiles with, so it stays
  /// first and keeps its meaning.
  static const presets = <AvatarPreset>[
    AvatarPreset(
      id: 'avatar_01',
      name: 'Spark',
      glyph: '⚡',
      colors: [AppColors.accent, AppColors.cyan],
    ),
    AvatarPreset(
      id: 'avatar_02',
      name: 'Nova',
      glyph: '🌟',
      colors: [AppColors.gold, Color(0xFFFF7A45)],
    ),
    AvatarPreset(
      id: 'avatar_03',
      name: 'Nebula',
      glyph: '🌌',
      colors: [AppColors.violet, AppColors.magenta],
    ),
    AvatarPreset(
      id: 'avatar_04',
      name: 'Circuit',
      glyph: '🤖',
      colors: [Color(0xFF60A5FA), AppColors.violet],
    ),
    AvatarPreset(
      id: 'avatar_05',
      name: 'Bloom',
      glyph: '🌱',
      colors: [Color(0xFF4ADE80), AppColors.accent],
    ),
    AvatarPreset(
      id: 'avatar_06',
      name: 'Ember',
      glyph: '🔥',
      colors: [Color(0xFFFF6B6B), AppColors.gold],
    ),
    AvatarPreset(
      id: 'avatar_07',
      name: 'Tide',
      glyph: '🌊',
      colors: [AppColors.cyan, Color(0xFF3B82F6)],
    ),
    AvatarPreset(
      id: 'avatar_08',
      name: 'Orbit',
      glyph: '🪐',
      colors: [Color(0xFFA78BFA), Color(0xFF6366F1)],
    ),
    AvatarPreset(
      id: 'avatar_09',
      name: 'Prism',
      glyph: '🔮',
      colors: [AppColors.magenta, Color(0xFF8B5CF6)],
    ),
    AvatarPreset(
      id: 'avatar_10',
      name: 'Quill',
      glyph: '📚',
      colors: [Color(0xFFF59E0B), Color(0xFFD97706)],
    ),
    AvatarPreset(
      id: 'avatar_11',
      name: 'Pulse',
      glyph: '🧠',
      colors: [Color(0xFFEC4899), Color(0xFFF43F5E)],
    ),
    AvatarPreset(
      id: 'avatar_12',
      name: 'Frost',
      glyph: '❄️',
      colors: [Color(0xFF7DD3FC), Color(0xFF38BDF8)],
    ),
  ];

  /// Resolve an avatar id. Unknown or empty ids hash [seed] so a player still
  /// gets a stable identity instead of everyone sharing preset one.
  static AvatarPreset resolve(String? avatarId, {String? seed}) {
    if (avatarId != null && avatarId.isNotEmpty) {
      for (final preset in presets) {
        if (preset.id == avatarId) return preset;
      }
    }
    final key = seed ?? avatarId ?? '';
    if (key.isEmpty) return presets.first;
    final hash = key.codeUnits.fold<int>(7, (acc, c) => (acc * 31 + c) & 0xFFFF);
    return presets[hash % presets.length];
  }
}
