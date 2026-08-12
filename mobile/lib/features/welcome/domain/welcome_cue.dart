import 'package:speedquiz/core/i18n/sq_strings.dart';
import 'package:speedquiz/features/auth/domain/auth_models.dart';

/// Why we are greeting the player.
enum WelcomeKind {
  /// A brand new account — first session ever on this device.
  newPlayer,

  /// Signed in deliberately this session (Google, or a fresh guest run on an
  /// account that already has progress).
  signedIn,

  /// A stored session was restored on launch.
  returning,
}

/// A one-shot request to greet the player, raised by the auth controller and
/// consumed by whichever screen is showing when they land.
///
/// It is deliberately transient — nothing persists it, so a hot restart or a
/// tab switch never re-greets. What *is* persisted (in [WelcomeStore]) is only
/// the once-a-day throttle and the first-seen date.
class WelcomeCue {
  const WelcomeCue({required this.kind, required this.user});

  final WelcomeKind kind;
  final AuthUser user;

  bool get isFirstEver => kind == WelcomeKind.newPlayer;

  /// A returning player gets a quieter greeting than someone who just signed
  /// in — a launch is not an event.
  bool get deservesSheet => kind != WelcomeKind.returning;

  /// Takes the string table rather than reading one: this is a domain object
  /// and has no BuildContext.
  String headline(SqStrings l10n) => switch (kind) {
        WelcomeKind.newPlayer => l10n.welcomeNewPlayer,
        WelcomeKind.signedIn => l10n.welcomeSignedIn(user.name),
        WelcomeKind.returning => l10n.welcomeBack(user.name),
      };
}
