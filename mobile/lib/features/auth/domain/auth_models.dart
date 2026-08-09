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
    this.dailyStreak = 0,
    this.bestStreak = 0,
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
  final int dailyStreak;
  final int bestStreak;
  final bool onboardingCompleted;
  final String themePreference;

  factory AuthUser.fromJson(Map<String, dynamic> json) {
    final daily = json['daily_streak'] as int? ?? json['current_streak'] as int? ?? 0;
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
      currentStreak: json['current_streak'] as int? ?? daily,
      dailyStreak: daily,
      bestStreak: json['best_streak'] as int? ?? 0,
      onboardingCompleted: json['onboarding_completed'] as bool? ?? false,
      themePreference: json['theme_preference'] as String? ?? 'dark',
    );
  }

  AuthUser copyWith({
    int? level,
    int? xp,
    int? coins,
    int? currentStreak,
    int? dailyStreak,
    int? bestStreak,
    bool? isPremium,
  }) {
    return AuthUser(
      id: id,
      email: email,
      username: username,
      displayName: displayName,
      avatarId: avatarId,
      isGuest: isGuest,
      isPremium: isPremium ?? this.isPremium,
      level: level ?? this.level,
      xp: xp ?? this.xp,
      coins: coins ?? this.coins,
      currentStreak: currentStreak ?? this.currentStreak,
      dailyStreak: dailyStreak ?? this.dailyStreak,
      bestStreak: bestStreak ?? this.bestStreak,
      onboardingCompleted: onboardingCompleted,
      themePreference: themePreference,
    );
  }

  @override
  List<Object?> get props => [id, username, level, xp, currentStreak, dailyStreak];
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
