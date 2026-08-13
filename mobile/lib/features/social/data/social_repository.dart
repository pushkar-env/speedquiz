import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:speedquiz/core/config/app_config.dart';
import 'package:speedquiz/core/network/dio_client.dart';
import 'package:speedquiz/features/multiplayer/domain/multiplayer_models.dart';

/// Friends, usernames, search and the badge counts.
class SocialRepository {
  SocialRepository(this._dio);

  final Dio _dio;

  static const _p = AppConfig.apiPrefix;

  // --- Username ------------------------------------------------------------

  Future<UsernameStatus> fetchUsername() async {
    final response = await _dio.get('$_p/username');
    return UsernameStatus.fromJson(response.data as Map<String, dynamic>);
  }

  Future<UsernameAvailability> checkUsername(String username) async {
    final response = await _dio.get(
      '$_p/username/available',
      queryParameters: {'username': username},
    );
    return UsernameAvailability.fromJson(response.data as Map<String, dynamic>);
  }

  Future<UsernameStatus> changeUsername(String username) async {
    final response = await _dio.put('$_p/username', data: {'username': username});
    return UsernameStatus.fromJson(response.data as Map<String, dynamic>);
  }

  // --- Friends -------------------------------------------------------------

  Future<List<Friend>> fetchFriends() async {
    final response = await _dio.get('$_p/friends');
    final data = response.data as Map<String, dynamic>;
    return (data['items'] as List<dynamic>? ?? const [])
        .map((e) => Friend.fromJson(e as Map<String, dynamic>))
        .toList(growable: false);
  }

  Future<({List<FriendRequest> incoming, List<FriendRequest> outgoing})>
      fetchRequests() async {
    final response = await _dio.get('$_p/friends/requests');
    final data = response.data as Map<String, dynamic>;
    List<FriendRequest> parse(String key) =>
        (data[key] as List<dynamic>? ?? const [])
            .map((e) => FriendRequest.fromJson(e as Map<String, dynamic>))
            .toList(growable: false);
    return (incoming: parse('incoming'), outgoing: parse('outgoing'));
  }

  /// Search by username or friend code. The server decides which it is.
  Future<({List<PlayerBrief> players, Map<String, String> relationships})> search(
    String query,
  ) async {
    final response = await _dio.get(
      '$_p/players/search',
      queryParameters: {'q': query},
    );
    final data = response.data as Map<String, dynamic>;
    return (
      players: (data['items'] as List<dynamic>? ?? const [])
          .map((e) => PlayerBrief.fromJson(e as Map<String, dynamic>))
          .toList(growable: false),
      relationships: (data['relationships'] as Map<String, dynamic>? ?? const {})
          .map((k, v) => MapEntry(k, v as String)),
    );
  }

  Future<void> sendRequest({String? userId, String? username, String? friendCode}) {
    return _dio.post('$_p/friends/requests', data: {
      'user_id': ?userId,
      'username': ?username,
      'friend_code': ?friendCode,
    });
  }

  Future<void> acceptRequest(String requestId) =>
      _dio.post('$_p/friends/requests/$requestId/accept');

  Future<void> declineRequest(String requestId) =>
      _dio.post('$_p/friends/requests/$requestId/decline');

  Future<void> cancelRequest(String requestId) =>
      _dio.delete('$_p/friends/requests/$requestId');

  Future<void> unfriend(String userId) => _dio.delete('$_p/friends/$userId');

  Future<void> block(String userId) => _dio.post('$_p/blocks/$userId');

  Future<void> unblock(String userId) => _dio.delete('$_p/blocks/$userId');

  Future<List<PlayerBrief>> fetchBlocked() async {
    final response = await _dio.get('$_p/blocks');
    return (response.data as List<dynamic>? ?? const [])
        .map((e) => PlayerBrief.fromJson(e as Map<String, dynamic>))
        .toList(growable: false);
  }

  // --- Badges and devices --------------------------------------------------

  Future<SocialSummary> fetchSummary() async {
    final response = await _dio.get('$_p/social/summary');
    return SocialSummary.fromJson(response.data as Map<String, dynamic>);
  }

  Future<({List<AppNotification> items, int unreadCount})> fetchNotifications() async {
    final response = await _dio.get('$_p/notifications');
    final data = response.data as Map<String, dynamic>;
    return (
      items: (data['items'] as List<dynamic>? ?? const [])
          .map((e) => AppNotification.fromJson(e as Map<String, dynamic>))
          .toList(growable: false),
      unreadCount: data['unread_count'] as int? ?? 0,
    );
  }

  /// Marks one notification read, or the whole inbox when [id] is omitted.
  Future<void> markNotificationsRead({String? id}) {
    return _dio.post(
      '$_p/notifications/read',
      queryParameters: {'notification_id': ?id},
    );
  }

  Future<void> registerDevice({
    required String token,
    required String platform,
    required String language,
    required int utcOffsetMinutes,
    String? appVersion,
  }) {
    return _dio.post('$_p/devices', data: {
      'token': token,
      'platform': platform,
      'language': language,
      'utc_offset_minutes': utcOffsetMinutes,
      'app_version': ?appVersion,
    });
  }

  Future<void> unregisterDevice(String token) =>
      _dio.delete('$_p/devices', queryParameters: {'token': token});
}

final socialRepositoryProvider = Provider<SocialRepository>((ref) {
  return SocialRepository(ref.watch(dioProvider));
});
