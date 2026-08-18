import 'package:equatable/equatable.dart';

/// Where this **device** stands with the first-run flow.
///
/// No longer a routing input. Whether to run the flow is asked of the account
/// — `AuthUser.needsOnboarding` — because a device record made every reinstall
/// look like a first run. What is left here tracks one thing: whether this
/// device is still carrying answers the server has not accepted yet.
enum OnboardingStatus {
  /// Not read from storage yet.
  unknown,

  /// This device has a first-run record it has not resolved.
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
