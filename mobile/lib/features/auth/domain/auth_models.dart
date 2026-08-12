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
    this.appLanguage,
    this.quizLanguage,
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

  /// Language preferences stored on the account. Null against a server that
  /// predates them — the device's own stored choice is the primary source and
  /// these only apply to a device that has never chosen (see
  /// `AppLanguageNotifier.adoptFromProfile`).
  final String? appLanguage;
  final String? quizLanguage;

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
      appLanguage: json['app_language'] as String?,
      quizLanguage: json['quiz_language'] as String?,
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
    String? displayName,
    String? avatarId,
    bool? onboardingCompleted,
  }) {
    return AuthUser(
      id: id,
      email: email,
      username: username,
      displayName: displayName ?? this.displayName,
      avatarId: avatarId ?? this.avatarId,
      isGuest: isGuest,
      isPremium: isPremium ?? this.isPremium,
      level: level ?? this.level,
      xp: xp ?? this.xp,
      coins: coins ?? this.coins,
      currentStreak: currentStreak ?? this.currentStreak,
      dailyStreak: dailyStreak ?? this.dailyStreak,
      bestStreak: bestStreak ?? this.bestStreak,
      onboardingCompleted: onboardingCompleted ?? this.onboardingCompleted,
      themePreference: themePreference,
      appLanguage: appLanguage,
      quizLanguage: quizLanguage,
    );
  }

  /// Name shown in the UI: the chosen display name, else the generated one.
  String get name => displayName?.trim().isNotEmpty == true
      ? displayName!.trim()
      : username;

  /// The name the player actually chose, or null while the account is still on
  /// its generated handle.
  ///
  /// A guest account ships with `display_name` already set to `player_a1b2c3d4`,
  /// so [name] is never empty and cannot answer "do we know who this is?".
  /// Greeting somebody as PLAYER_A1B2C3D4 reads worse than not naming them at
  /// all, so anywhere the name is optional decoration asks for this one.
  String? get chosenName {
    final chosen = displayName?.trim();
    if (chosen == null || chosen.isEmpty || chosen == username) return null;
    return chosen;
  }

  @override
  List<Object?> get props => [
        id,
        username,
        displayName,
        avatarId,
        level,
        xp,
        coins,
        isPremium,
        currentStreak,
        dailyStreak,
      ];
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
