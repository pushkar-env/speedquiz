import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:quizverse/features/auth/data/auth_repository.dart';
import 'package:quizverse/features/auth/domain/auth_models.dart';

sealed class AuthState {
  const AuthState();
}

class AuthInitial extends AuthState {
  const AuthInitial();
}

class AuthLoading extends AuthState {
  const AuthLoading();
}

class AuthAuthenticated extends AuthState {
  const AuthAuthenticated(this.user);
  final AuthUser user;
}

class AuthError extends AuthState {
  const AuthError(this.message);
  final String message;
}

class AuthController extends StateNotifier<AuthState> {
  AuthController(this._repo) : super(const AuthInitial());

  final AuthRepository _repo;

  Future<void> bootstrap() async {
    state = const AuthLoading();
    try {
      final existing = await _repo.fetchMe();
      if (existing != null) {
        state = AuthAuthenticated(existing);
        return;
      }
      final session = await _repo.signInAsGuest();
      state = AuthAuthenticated(session.user);
    } catch (error) {
      // Last resort: wipe tokens and try a fresh guest session once.
      try {
        await _repo.signOut();
        final session = await _repo.signInAsGuest();
        state = AuthAuthenticated(session.user);
      } catch (_) {
        state = AuthError(error.toString());
      }
    }
  }

  Future<void> continueAsGuest() async {
    state = const AuthLoading();
    try {
      final session = await _repo.signInAsGuest();
      state = AuthAuthenticated(session.user);
    } catch (error) {
      state = AuthError(error.toString());
    }
  }

  void applyProgress({
    int? level,
    int? xp,
    int? coins,
    int? currentStreak,
    int? dailyStreak,
    int? bestStreak,
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
      ),
    );
  }

  Future<void> refreshMe() async {
    try {
      final user = await _repo.fetchMe();
      if (user != null) {
        state = AuthAuthenticated(user);
      }
    } catch (_) {
      // Keep current session if refresh fails.
    }
  }
}

final authControllerProvider =
    StateNotifierProvider<AuthController, AuthState>((ref) {
  return AuthController(ref.watch(authRepositoryProvider));
});
