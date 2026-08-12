import 'package:equatable/equatable.dart';

/// Where this **device** stands with the first-run flow.
enum OnboardingStatus {
  /// Not read from storage yet.
  ///
  /// Treated as "do not interrupt": showing the flow to someone who has
  /// already been through it is worse than skipping it for someone who has
  /// not, and the router asks this question on its very first redirect.
  unknown,

  /// Never completed here, and no session has ever been restored on this
  /// device — a genuine first run.
  needed,

  /// Completed, or implied complete by a session that already existed.
  done,
}

/// Onboarding as the rest of the app sees it: whether to run the flow, and the
/// answer that has not reached the server yet.
class OnboardingState extends Equatable {
  const OnboardingState({
    this.status = OnboardingStatus.unknown,
    this.pendingName,
  });

  final OnboardingStatus status;

  /// The name the player typed before signing in.
  ///
  /// It is held on the device because the flow deliberately runs *before*
  /// there is an account to write it to. Cleared once a session exists and the
  /// profile has actually taken it.
  final String? pendingName;

  bool get isNeeded => status == OnboardingStatus.needed;

  OnboardingState copyWith({
    OnboardingStatus? status,
    String? pendingName,
    bool clearPendingName = false,
  }) {
    return OnboardingState(
      status: status ?? this.status,
      pendingName: clearPendingName ? null : (pendingName ?? this.pendingName),
    );
  }

  @override
  List<Object?> get props => [status, pendingName];
}
