import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Local, per-device record of when we last greeted a player and when we first
/// saw them.
///
/// "First seen" is deliberately device-local and labelled as such in the UI:
/// the server does not expose an account creation date, so claiming "member
/// since" would be inventing a fact.
class WelcomeStore {
  const WelcomeStore();

  static const _lastGreetedKey = 'welcome_last_greeted_on';
  static const _firstSeenPrefix = 'welcome_first_seen_';

  static String _today() {
    final now = DateTime.now();
    return '${now.year.toString().padLeft(4, '0')}-'
        '${now.month.toString().padLeft(2, '0')}-'
        '${now.day.toString().padLeft(2, '0')}';
  }

  /// True at most once per calendar day, so a relaunch does not re-greet.
  Future<bool> shouldGreetToday() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      return prefs.getString(_lastGreetedKey) != _today();
    } catch (error) {
      debugPrint('welcome_store_read_failed: $error');
      return false;
    }
  }

  Future<void> markGreeted() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_lastGreetedKey, _today());
    } catch (error) {
      debugPrint('welcome_store_write_failed: $error');
    }
  }

  /// Records the first day this device saw [userId], and returns it. Later
  /// calls return the stored value untouched.
  Future<DateTime?> firstSeen(String userId) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final key = '$_firstSeenPrefix$userId';
      final stored = prefs.getString(key);
      if (stored != null) return DateTime.tryParse(stored);
      final now = DateTime.now();
      await prefs.setString(key, now.toIso8601String());
      return now;
    } catch (error) {
      debugPrint('welcome_store_first_seen_failed: $error');
      return null;
    }
  }
}

final welcomeStoreProvider = Provider<WelcomeStore>((ref) {
  return const WelcomeStore();
});

/// The day this device first saw the signed-in player, or null before it has
/// been read. Shown on the profile as "Playing since".
final firstSeenProvider =
    FutureProvider.autoDispose.family<DateTime?, String>((ref, userId) {
  return ref.watch(welcomeStoreProvider).firstSeen(userId);
});
