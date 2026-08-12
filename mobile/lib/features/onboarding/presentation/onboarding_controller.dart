import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:speedquiz/core/i18n/language_providers.dart';
import 'package:speedquiz/features/auth/domain/auth_models.dart';
import 'package:speedquiz/features/auth/presentation/auth_controller.dart';
import 'package:speedquiz/features/onboarding/data/onboarding_store.dart';
import 'package:speedquiz/features/onboarding/domain/onboarding_state.dart';
import 'package:speedquiz/features/profile/data/profile_repository.dart';

/// Owns the first-run flow: whether to run it, and getting what it collects
/// onto the account.
///
/// The two halves are deliberately separated in time. A player answers before
/// they sign in — that is the whole point of onboarding — so the answers live
/// on the device until there is a session to write them to, and the write is
/// attached to the moment a session appears rather than to any one screen.
class OnboardingController extends StateNotifier<OnboardingState> {
  OnboardingController(this._ref) : super(const OnboardingState());

  final Ref _ref;

  OnboardingStore get _store => _ref.read(onboardingStoreProvider);

  /// Reads the device's record and installs the first-session hook.
  ///
  /// Called from `main` before the first frame: the router asks which screen a
  /// signed-out player gets on its very first redirect, and "not read yet"
  /// sends a first-run player past the flow.
  Future<void> hydrate() async {
    final record = await _store.read();
    state = OnboardingState(
      status: record.seen ? OnboardingStatus.done : OnboardingStatus.needed,
      pendingName: record.name,
    );
    _ref.read(authControllerProvider.notifier).onSessionEstablished =
        _onSessionEstablished;
  }

  /// The flow is finished. [name] is null when the player skipped that step.
  ///
  /// Marks the device done immediately rather than waiting for the sync: the
  /// router is watching, and nobody should be asked these questions twice
  /// because the network was slow.
  Future<void> complete({String? name}) async {
    final trimmed = name?.trim();
    final stored = (trimmed == null || trimmed.isEmpty) ? null : trimmed;
    state = OnboardingState(
      status: OnboardingStatus.done,
      pendingName: stored,
    );
    await _store.markCompleted(stored);
  }

  /// Runs for every session the app establishes — a cold-start restore as well
  /// as a fresh sign-in — and hands back the user the rest of the app sees.
  ///
  /// Being on this path rather than on a listener is what keeps the greeting
  /// honest: by the time Home builds, the profile already carries the name,
  /// so it never renders a generated handle and then rewrites it.
  Future<AuthUser> _onSessionEstablished(AuthUser user) async {
    // A session on this device is proof enough that the flow is behind us.
    // Without this, signing out on an install that predates onboarding would
    // drop the player into it.
    if (state.status != OnboardingStatus.done) {
      state = state.copyWith(status: OnboardingStatus.done);
    }

    final record = await _store.read();
    if (!record.seen) await _store.markSeen();
    if (!record.pending) return user;

    final name = _nameFor(user, record.name);
    try {
      final profile = await _ref.read(profileRepositoryProvider).update(
            displayName: name,
            // The device's language is the authority here — it is what the
            // player picked a screen ago, and on a fresh account there is
            // nothing on the server worth preferring over it.
            appLanguage: _ref.read(appLanguageProvider).code,
            quizLanguage: _ref.read(quizLanguageProvider).code,
            onboardingCompleted: true,
          );
      await _store.clearPending();
      state = const OnboardingState(status: OnboardingStatus.done);
      return user.copyWith(
        displayName: profile.displayName,
        avatarId: profile.avatarId,
        onboardingCompleted: true,
      );
    } catch (error) {
      // Offline, or a server that predates the fields. The sign-in itself
      // still stands and the answers are still on disk, so the next session
      // tries again.
      debugPrint('onboarding_sync_failed: $error');
      return user;
    }
  }

  /// The typed name — unless the account already has a life of its own.
  ///
  /// Reinstalling and signing back into an established account would otherwise
  /// overwrite a real display name with whatever was typed on the way in. Same
  /// "untouched account" reading the welcome cue uses: nobody with progress is
  /// on level 1 with no XP.
  static String? _nameFor(AuthUser user, String? typed) {
    final name = typed?.trim();
    if (name == null || name.isEmpty) return null;
    final untouched =
        !user.onboardingCompleted && user.level <= 1 && user.xp == 0;
    return untouched ? name : null;
  }
}

final onboardingControllerProvider =
    StateNotifierProvider<OnboardingController, OnboardingState>((ref) {
  return OnboardingController(ref);
});
