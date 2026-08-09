import 'package:equatable/equatable.dart';

class LeaderboardEntry extends Equatable {
  const LeaderboardEntry({
    required this.rank,
    required this.userId,
    required this.username,
    required this.score,
    required this.isMe,
  });

  final int rank;
  final String userId;
  final String username;
  final int score;
  final bool isMe;

  factory LeaderboardEntry.fromJson(Map<String, dynamic> json) {
    return LeaderboardEntry(
      rank: json['rank'] as int,
      userId: json['user_id'] as String,
      username: json['username'] as String? ?? 'Player',
      score: json['score'] as int,
      isMe: json['is_me'] as bool? ?? false,
    );
  }

  @override
  List<Object?> get props => [rank, userId, score];
}

class LeaderboardMe extends Equatable {
  const LeaderboardMe({this.rank, this.score, this.username});

  final int? rank;
  final int? score;
  final String? username;

  factory LeaderboardMe.fromJson(Map<String, dynamic>? json) {
    if (json == null) return const LeaderboardMe();
    return LeaderboardMe(
      rank: json['rank'] as int?,
      score: json['score'] as int?,
      username: json['username'] as String?,
    );
  }

  @override
  List<Object?> get props => [rank, score];
}

class LeaderboardBoard extends Equatable {
  const LeaderboardBoard({
    required this.scope,
    required this.periodKey,
    required this.items,
    required this.me,
    required this.total,
  });

  final String scope;
  final String periodKey;
  final List<LeaderboardEntry> items;
  final LeaderboardMe me;
  final int total;

  factory LeaderboardBoard.fromJson(Map<String, dynamic> json) {
    return LeaderboardBoard(
      scope: json['scope'] as String,
      periodKey: json['period_key'] as String,
      items: (json['items'] as List<dynamic>? ?? [])
          .map((e) => LeaderboardEntry.fromJson(e as Map<String, dynamic>))
          .toList(),
      me: LeaderboardMe.fromJson(json['me'] as Map<String, dynamic>?),
      total: json['total'] as int? ?? 0,
    );
  }

  @override
  List<Object?> get props => [scope, periodKey, items, me];
}
