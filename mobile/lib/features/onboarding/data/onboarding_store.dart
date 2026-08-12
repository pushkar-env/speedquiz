import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// What the device remembers about the first-run flow.
///
/// [pending] is the part that matters: it means the answers are still owed to
/// the server. It stays true through a failed sync, a force-quit, or a player
/// who onboards today and only signs in next week.
typedef OnboardingRecord = ({bool seen, String? name, bool pending});

/// Device-local record of the first-run flow.
///
/// Deliberately on the device rather than only on the account: the flow runs
/// *before* anyone is signed in, so there is nowhere else to put the answers
/// until a session exists.
///
/// Every read fails soft. A corrupt or unavailable preference store must not
/// cost a player their session — the worst outcome here is being asked one
/// question twice.
class OnboardingStore {
  const OnboardingStore();

  static const _seenKey = 'onboarding_v1_seen';
  static const _nameKey = 'onboarding_v1_name';
  static const _pendingKey = 'onboarding_v1_pending';

  Future<OnboardingRecord> read() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      return (
        seen: prefs.getBool(_seenKey) ?? false,
        name: prefs.getString(_nameKey),
        pending: prefs.getBool(_pendingKey) ?? false,
      );
    } catch (error) {
      debugPrint('onboarding_store_read_failed: $error');
      // Claim it has been seen: skipping the flow is the safer failure.
      return (seen: true, name: null, pending: false);
    }
  }

  /// The flow finished. [name] is null when the player skipped that step.
  Future<void> markCompleted(String? name) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(_seenKey, true);
      await prefs.setBool(_pendingKey, true);
      if (name == null || name.isEmpty) {
        await prefs.remove(_nameKey);
      } else {
        await prefs.setString(_nameKey, name);
      }
    } catch (error) {
      debugPrint('onboarding_store_write_failed: $error');
    }
  }

  /// This device does not need the flow — usually because a session was
  /// already on it when the feature arrived.
  Future<void> markSeen() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(_seenKey, true);
    } catch (error) {
      debugPrint('onboarding_store_write_failed: $error');
    }
  }

  /// The profile has the answers; stop carrying them.
  Future<void> clearPending() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(_pendingKey, false);
      await prefs.remove(_nameKey);
    } catch (error) {
      debugPrint('onboarding_store_write_failed: $error');
    }
  }
}

final onboardingStoreProvider = Provider<OnboardingStore>((ref) {
  return const OnboardingStore();
});
