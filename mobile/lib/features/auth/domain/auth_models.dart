import 'package:equatable/equatable.dart';

class AuthUser extends Equatable {
  const AuthUser({
    required this.id,
    required this.username,
    required this.isGuest,
    required this.isPremium,
    required this.level,
    required this.xp,
    required this.coins,
    required this.currentStreak,
    required this.onboardingCompleted,
    required this.themePreference,
    required this.avatarId,
    this.email,
    this.displayName,
  });

  final String id;
  final String? email;
  final String username;
  final String? displayName;
  final String avatarId;
  final bool isGuest;
  final bool isPremium;
  final int level;
  final int xp;
  final int coins;
  final int currentStreak;
  final bool onboardingCompleted;
  final String themePreference;

  factory AuthUser.fromJson(Map<String, dynamic> json) {
    return AuthUser(
      id: json['id'] as String,
      email: json['email'] as String?,
      username: json['username'] as String,
      displayName: json['display_name'] as String?,
      avatarId: json['avatar_id'] as String? ?? 'avatar_01',
      isGuest: json['is_guest'] as bool? ?? true,
      isPremium: json['is_premium'] as bool? ?? false,
      level: json['level'] as int? ?? 1,
      xp: json['xp'] as int? ?? 0,
      coins: json['coins'] as int? ?? 0,
      currentStreak: json['current_streak'] as int? ?? 0,
      onboardingCompleted: json['onboarding_completed'] as bool? ?? false,
      themePreference: json['theme_preference'] as String? ?? 'dark',
    );
  }

  @override
  List<Object?> get props => [id, username, level, xp, currentStreak];
}

class AuthSession extends Equatable {
  const AuthSession({
    required this.accessToken,
    required this.refreshToken,
    required this.user,
  });

  final String accessToken;
  final String refreshToken;
  final AuthUser user;

  factory AuthSession.fromJson(Map<String, dynamic> json) {
    return AuthSession(
      accessToken: json['access_token'] as String,
      refreshToken: json['refresh_token'] as String,
      user: AuthUser.fromJson(json['user'] as Map<String, dynamic>),
    );
  }

  @override
  List<Object?> get props => [accessToken, user];
}
