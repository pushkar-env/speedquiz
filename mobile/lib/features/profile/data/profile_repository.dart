import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:speedquiz/core/config/app_config.dart';
import 'package:speedquiz/core/network/dio_client.dart';
import 'package:speedquiz/features/profile/domain/profile_models.dart';

class ProfileRepository {
  ProfileRepository(this._dio);

  final Dio _dio;

  Future<UserProfile> fetch() async {
    final response = await _dio.get('${AppConfig.apiPrefix}/users/me');
    return UserProfile.fromJson(response.data as Map<String, dynamic>);
  }

  /// Partial update. Only non-null fields are sent, matching the server's
  /// PATCH semantics — sending nulls would be indistinguishable from "clear".
  Future<UserProfile> update({
    String? displayName,
    String? avatarId,
    String? themePreference,
    List<String>? favoriteTopicIds,
    bool? onboardingCompleted,
  }) async {
    final body = <String, dynamic>{
      'display_name': ?displayName,
      'avatar_id': ?avatarId,
      'theme_preference': ?themePreference,
      'favorite_topic_ids': ?favoriteTopicIds,
      'onboarding_completed': ?onboardingCompleted,
    };
    final response = await _dio.patch(
      '${AppConfig.apiPrefix}/users/me',
      data: body,
    );
    return UserProfile.fromJson(response.data as Map<String, dynamic>);
  }
}

final profileRepositoryProvider = Provider<ProfileRepository>((ref) {
  return ProfileRepository(ref.watch(dioProvider));
});

/// Full profile with lifetime statistics. Separate from [authControllerProvider]
/// because it carries the heavier stats payload the hub does not always need.
final profileProvider = FutureProvider.autoDispose<UserProfile>((ref) {
  return ref.watch(profileRepositoryProvider).fetch();
});
