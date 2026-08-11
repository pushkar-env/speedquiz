import 'dart:async';

import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:speedquiz/core/settings/app_settings.dart';

/// Every one-shot cue the game can play.
enum Sfx {
  tap('tap.wav'),
  tick('tick.wav'),
  correct('correct.wav'),
  wrong('wrong.wav'),
  streak('streak.wav'),
  finish('finish.wav'),
  unlock('unlock.wav');

  const Sfx(this.asset);

  final String asset;

  String get path => 'audio/$asset';
}

/// Plays gameplay cues and the optional ambient loop.
///
/// Audio is strictly decorative: every call is fire-and-forget and every
/// failure is swallowed. A device with no audio output, a denied session, or
/// a platform without the plugin must never break gameplay.
class AudioService {
  AudioService();

  /// A small pool so rapid-fire cues overlap instead of cutting each other
  /// off — answering fast should still sound right.
  static const _poolSize = 3;

  final List<AudioPlayer> _pool = [];
  AudioPlayer? _ambient;

  int _next = 0;
  bool _sfxEnabled = true;
  bool _musicEnabled = false;
  bool _disposed = false;
  bool _broken = false;

  bool _settingsApplied = false;

  /// Mirrors [AppSettings] so callers never have to check first.
  void applySettings(AppSettings settings) {
    _sfxEnabled = settings.soundEnabled;
    final musicChanged = _musicEnabled != settings.musicEnabled;
    _musicEnabled = settings.musicEnabled;

    // Also act on the very first application, otherwise music that was left
    // enabled last session never starts on launch.
    if (musicChanged || !_settingsApplied) {
      if (_musicEnabled) {
        startAmbient();
      } else {
        stopAmbient();
      }
    }
    _settingsApplied = true;
  }

  Future<void> _ensurePool() async {
    if (_pool.isNotEmpty || _broken) return;
    try {
      for (var i = 0; i < _poolSize; i++) {
        final player = AudioPlayer()
          ..setReleaseMode(ReleaseMode.stop)
          ..setPlayerMode(PlayerMode.lowLatency);
        _pool.add(player);
      }
    } catch (error) {
      // No audio backend on this device/platform — go quiet permanently
      // rather than retrying on every tap.
      _broken = true;
      debugPrint('audio_unavailable: $error');
    }
  }

  /// Play a one-shot cue. Silently does nothing when sound is off.
  void play(Sfx sfx, {double volume = 1.0}) {
    if (!_sfxEnabled || _disposed || _broken) return;
    unawaited(_playAsync(sfx, volume));
  }

  Future<void> _playAsync(Sfx sfx, double volume) async {
    try {
      await _ensurePool();
      if (_pool.isEmpty || _disposed) return;
      final player = _pool[_next % _pool.length];
      _next++;
      await player.stop();
      await player.setVolume(volume.clamp(0.0, 1.0));
      await player.play(AssetSource(sfx.path));
    } catch (error) {
      debugPrint('audio_play_failed(${sfx.name}): $error');
    }
  }

  Future<void> startAmbient() async {
    if (_disposed || _broken || !_musicEnabled) return;
    try {
      _ambient ??= AudioPlayer()..setReleaseMode(ReleaseMode.loop);
      await _ambient!.setVolume(0.16);
      await _ambient!.play(AssetSource('audio/ambient.wav'));
    } catch (error) {
      debugPrint('audio_ambient_failed: $error');
    }
  }

  Future<void> stopAmbient() async {
    try {
      await _ambient?.stop();
    } catch (_) {
      // Nothing meaningful to do if stopping fails.
    }
  }

  Future<void> dispose() async {
    _disposed = true;
    for (final player in _pool) {
      try {
        await player.dispose();
      } catch (_) {}
    }
    _pool.clear();
    try {
      await _ambient?.dispose();
    } catch (_) {}
    _ambient = null;
  }
}

final audioServiceProvider = Provider<AudioService>((ref) {
  final service = AudioService()..applySettings(ref.read(settingsProvider));

  // Keep the service in step with the settings screen.
  ref.listen<AppSettings>(
    settingsProvider,
    (previous, next) => service.applySettings(next),
  );

  Sound.register(service);
  ref.onDispose(() {
    Sound.register(null);
    service.dispose();
  });
  return service;
});

/// Static facade for widgets that sit below the provider scope — the shared
/// widget library must not depend on Riverpod just to click.
///
/// Mirrors [Haptics]: fire-and-forget, no-ops when nothing is registered.
abstract final class Sound {
  static AudioService? _service;

  static void register(AudioService? service) => _service = service;

  static void play(Sfx sfx, {double volume = 1.0}) =>
      _service?.play(sfx, volume: volume);

  /// UI tick for deliberate actions (buttons, tab switches).
  static void tap() => play(Sfx.tap, volume: 0.45);
}
