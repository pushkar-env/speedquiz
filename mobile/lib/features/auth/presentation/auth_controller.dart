import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:speedquiz/core/network/api_errors.dart';
import 'package:speedquiz/features/auth/data/auth_repository.dart';
import 'package:speedquiz/features/auth/data/google_auth_service.dart';
import 'package:speedquiz/features/auth/domain/auth_models.dart';
import 'package:speedquiz/features/welcome/domain/welcome_cue.dart';

sealed class AuthState {
  const AuthState();
}

/// Restoring a stored session. The splash screen owns this state.
class AuthBooting extends AuthState {
  const AuthBooting();
}

/// No active session — the landing screen owns this state.
///
/// [pending] is set while a guest/Google attempt is in flight so the landing
/// screen can show inline progress without the router bouncing to splash.
class AuthSignedOut extends AuthState {
  const AuthSignedOut({
    this.pending = false,
    this.message,
    this.error,
    this.hasStoredSession = false,
  });

  final bool pending;

  /// Why the last attempt failed, if it did — already worded, in English.
  final String? message;

  /// The failure itself, so a screen with a `BuildContext` can word it in the
  /// player's language instead. This controller has none, and it outlives a
  /// language change, so it stores the cause rather than a sentence.
  final Object? error;

  /// A token exists on disk but could not be validated (usually offline), so
  /// retrying is more useful than starting a new guest session.
  final bool hasStoredSession;
}

class AuthAuthenticated extends AuthState {
  const AuthAuthenticated(this.user);
  final AuthUser user;
}

enum GoogleSignInOutcome { success, cancelled, failed }

class GoogleSignInResult {
  const GoogleSignInResult(this.outcome, [this.message]);

  final GoogleSignInOutcome outcome;
  final String? message;

  bool get isSuccess => outcome == GoogleSignInOutcome.success;
  bool get isCancelled => outcome == GoogleSignInOutcome.cancelled;
}

class AuthController extends StateNotifier<AuthState> {
  AuthController(this._repo, this._googleAuth) : super(const AuthBooting());

  final AuthRepository _repo;
  final GoogleAuthService _googleAuth;

  WelcomeCue? _welcome;

  /// Hand the pending greeting to whoever asks first, then forget it.
  ///
  /// Deliberately take-once: the greeting belongs to the moment the session
  /// started, not to a screen, so re-entering Home must not replay it.
  WelcomeCue? takeWelcomeCue() {
    final cue = _welcome;
    _welcome = null;
    return cue;
  }

  /// A fresh account looks the same as a returning one over the wire, so
  /// infer it: nobody with progress is on level 1 with zero XP and no streak.
  static WelcomeKind _kindFor(AuthUser user) {
    final untouched = user.level <= 1 && user.xp == 0 && user.bestStreak == 0;
    return untouched ? WelcomeKind.newPlayer : WelcomeKind.signedIn;
  }

  /// Restore a stored session on cold start.
  ///
  /// A network failure must never destroy a valid session, so tokens are only
  /// cleared when the server actually rejects them (handled in the repository
  /// on 401). Anything else lands on the landing screen with a retry.
  Future<void> bootstrap() async {
    state = const AuthBooting();
    try {
      final existing = await _repo.fetchMe();
      if (existing != null) {
        _welcome = WelcomeCue(
          kind: WelcomeKind.returning,
          user: existing,
        );
        state = AuthAuthenticated(existing);
        return;
      }
      state = const AuthSignedOut();
    } catch (error) {
      state = AuthSignedOut(
        message: apiErrorMessage(error),
        error: error,
        hasStoredSession: await _repo.hasStoredSession(),
      );
    }
  }

  /// Start (or restart) an anonymous session.
  Future<void> continueAsGuest() async {
    state = const AuthSignedOut(pending: true);
    try {
      final session = await _repo.signInAsGuest();
      _welcome = WelcomeCue(
        kind: _kindFor(session.user),
        user: session.user,
      );
      state = AuthAuthenticated(session.user);
    } catch (error) {
      state = AuthSignedOut(message: apiErrorMessage(error), error: error);
    }
  }

  /// Sign in with Google, or upgrade the current guest in place.
  Future<GoogleSignInResult> signInWithGoogle() async {
    final previous = state;
    if (previous is AuthSignedOut) {
      state = const AuthSignedOut(pending: true);
    }
    try {
      final idToken = await _googleAuth.obtainIdToken();
      if (idToken == null) {
        state = previous is AuthSignedOut ? const AuthSignedOut() : previous;
        return const GoogleSignInResult(GoogleSignInOutcome.cancelled);
      }
      final session = await _repo.signInWithGoogle(idToken);
      _welcome = WelcomeCue(
        kind: _kindFor(session.user),
        user: session.user,
      );
      state = AuthAuthenticated(session.user);
      return const GoogleSignInResult(GoogleSignInOutcome.success);
    } catch (error) {
      // A StateError here is a *build* misconfiguration (no client id, no ID
      // token) and its text is aimed at whoever built the APK, so it is shown
      // verbatim. Anything else falls through as null, which lets the screen
      // supply localized copy — this controller has no BuildContext of its
      // own and outlives a language change.
      final message = error is StateError
          ? error.message
          : apiErrorMessage(error, fallback: '');
      // An authenticated user stays authenticated when an upgrade fails.
      final surfaced = message.isEmpty ? null : message;
      state = previous is AuthAuthenticated
          ? previous
          : AuthSignedOut(message: surfaced, error: error);
      return GoogleSignInResult(GoogleSignInOutcome.failed, surfaced);
    }
  }

  /// Drop the local session and return to the landing screen.
  ///
  /// The Google session is cleared too, otherwise the next sign-in silently
  /// reuses the previous account without showing the picker.
  Future<void> signOut() async {
    state = const AuthSignedOut(pending: true);
    try {
      await _googleAuth.signOut();
    } catch (error) {
      debugPrint('google_sign_out_failed: $error');
    }
    await _repo.signOut();
    state = const AuthSignedOut();
  }

  void applyProgress({
    int? level,
    int? xp,
    int? coins,
    int? currentStreak,
    int? dailyStreak,
    int? bestStreak,
    bool? isPremium,
  }) {
    final current = state;
    if (current is! AuthAuthenticated) return;
    state = AuthAuthenticated(
      current.user.copyWith(
        level: level,
        xp: xp,
        coins: coins,
        currentStreak: currentStreak ?? dailyStreak,
        dailyStreak: dailyStreak ?? currentStreak,
        bestStreak: bestStreak,
        isPremium: isPremium,
      ),
    );
  }

  /// Reflect a profile edit across the app without a round trip.
  void applyIdentity({String? displayName, String? avatarId}) {
    final current = state;
    if (current is! AuthAuthenticated) return;
    state = AuthAuthenticated(
      current.user.copyWith(displayName: displayName, avatarId: avatarId),
    );
  }

  Future<void> refreshMe() async {
    try {
      final user = await _repo.fetchMe();
      if (user != null) {
        state = AuthAuthenticated(user);
      }
    } catch (_) {
      // Keep the current session if refresh fails.
    }
  }
}

final authControllerProvider =
    StateNotifierProvider<AuthController, AuthState>((ref) {
  return AuthController(
    ref.watch(authRepositoryProvider),
    ref.watch(googleAuthServiceProvider),
  );
});

/// Convenience: the signed-in user, or null.
final currentUserProvider = Provider<AuthUser?>((ref) {
  final state = ref.watch(authControllerProvider);
  return state is AuthAuthenticated ? state.user : null;
});
