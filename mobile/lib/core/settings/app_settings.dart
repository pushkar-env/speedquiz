import 'package:equatable/equatable.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:speedquiz/core/feedback/haptics.dart';

/// Player-facing feel settings. Persisted locally — they describe this device,
/// not the account.
class AppSettings extends Equatable {
  const AppSettings({
    this.soundEnabled = true,
    this.musicEnabled = false,
    this.hapticsEnabled = true,
  });

  /// Gameplay cues: correct, wrong, tick, celebrate.
  final bool soundEnabled;

  /// Ambient background loop. Off by default — most players are in public.
  final bool musicEnabled;

  final bool hapticsEnabled;

  AppSettings copyWith({
    bool? soundEnabled,
    bool? musicEnabled,
    bool? hapticsEnabled,
  }) {
    return AppSettings(
      soundEnabled: soundEnabled ?? this.soundEnabled,
      musicEnabled: musicEnabled ?? this.musicEnabled,
      hapticsEnabled: hapticsEnabled ?? this.hapticsEnabled,
    );
  }

  @override
  List<Object?> get props => [soundEnabled, musicEnabled, hapticsEnabled];
}

class SettingsNotifier extends StateNotifier<AppSettings> {
  SettingsNotifier() : super(const AppSettings());

  static const _soundKey = 'settings_sound';
  static const _musicKey = 'settings_music';
  static const _hapticsKey = 'settings_haptics';

  Future<void> hydrate() async {
    final prefs = await SharedPreferences.getInstance();
    state = AppSettings(
      soundEnabled: prefs.getBool(_soundKey) ?? true,
      musicEnabled: prefs.getBool(_musicKey) ?? false,
      hapticsEnabled: prefs.getBool(_hapticsKey) ?? true,
    );
    Haptics.enabled = state.hapticsEnabled;
  }

  Future<void> setSound(bool enabled) async {
    state = state.copyWith(soundEnabled: enabled);
    await _persist(_soundKey, enabled);
  }

  Future<void> setMusic(bool enabled) async {
    state = state.copyWith(musicEnabled: enabled);
    await _persist(_musicKey, enabled);
  }

  Future<void> setHaptics(bool enabled) async {
    state = state.copyWith(hapticsEnabled: enabled);
    Haptics.enabled = enabled;
    await _persist(_hapticsKey, enabled);
  }

  Future<void> _persist(String key, bool value) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(key, value);
  }
}

final settingsProvider =
    StateNotifierProvider<SettingsNotifier, AppSettings>((ref) {
  return SettingsNotifier();
});
