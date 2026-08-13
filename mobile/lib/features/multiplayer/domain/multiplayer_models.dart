import 'package:equatable/equatable.dart';

/// Wire models for battles, friends and the ranked ladder.
///
/// Every timestamp the server sends is absolute UTC, and every deadline is
/// paired with a `server_time` from the same response. [MatchState.clockSkew]
/// turns that pair into an offset the countdown corrects by, so a device whose
/// clock is ten minutes fast still shows an honest timer. Nothing here ever
/// derives a deadline from a duration — a duration is already stale by the
/// time it arrives, and wrong by exactly the latency the round clock is trying
/// to be fair about.

DateTime? _parseUtc(Object? raw) {
  if (raw is! String || raw.isEmpty) return null;
  return DateTime.tryParse(raw)?.toUtc();
}

DateTime _requireUtc(Object? raw) => _parseUtc(raw) ?? DateTime.now().toUtc();

enum MatchFormat { duel, room }

enum MatchKind { friendly, ranked }

enum MatchDelivery { live, asynchronous }

enum MatchStatus { pending, lobby, live, awaitingOpponent, completed, expired, cancelled }

enum ParticipantStatus {
  invited,
  joined,
  ready,
  playing,
  finished,
  declined,
  forfeited,
}

enum MatchOutcome { win, loss, draw }

T _enumFromWire<T extends Enum>(List<T> values, String? wire, T fallback) {
  if (wire == null) return fallback;
  // The server spells these in snake_case; Dart enum names are lowerCamel.
  final normalized = wire.replaceAll('_', '').toLowerCase();
  for (final value in values) {
    if (value.name.toLowerCase() == normalized) return value;
  }
  return fallback;
}

MatchDelivery _deliveryFromWire(String? wire) {
  // `async` is a Dart reserved word, so the enum member cannot share the
  // server's spelling and needs its own mapping.
  return wire == 'async' ? MatchDelivery.asynchronous : MatchDelivery.live;
}

class PlayerBrief extends Equatable {
  const PlayerBrief({
    required this.userId,
    required this.username,
    this.displayName,
    this.avatarId = 'avatar_01',
    this.level = 1,
    this.isPremium = false,
    this.rating,
    this.tier,
    this.tierIcon,
  });

  final String userId;
  final String username;
  final String? displayName;
  final String avatarId;
  final int level;
  final bool isPremium;
  final int? rating;
  final String? tier;
  final String? tierIcon;

  String get label => (displayName?.trim().isNotEmpty ?? false) ? displayName! : username;

  factory PlayerBrief.fromJson(Map<String, dynamic> json) => PlayerBrief(
        userId: json['user_id'] as String,
        username: json['username'] as String? ?? 'Player',
        displayName: json['display_name'] as String?,
        avatarId: json['avatar_id'] as String? ?? 'avatar_01',
        level: json['level'] as int? ?? 1,
        isPremium: json['is_premium'] as bool? ?? false,
        rating: json['rating'] as int?,
        tier: json['tier'] as String?,
        tierIcon: json['tier_icon'] as String?,
      );

  @override
  List<Object?> get props => [userId, username, avatarId, level, rating];
}

class HeadToHead extends Equatable {
  const HeadToHead({this.wins = 0, this.losses = 0, this.draws = 0});

  final int wins;
  final int losses;
  final int draws;

  int get played => wins + losses + draws;

  factory HeadToHead.fromJson(Map<String, dynamic>? json) => json == null
      ? const HeadToHead()
      : HeadToHead(
          wins: json['wins'] as int? ?? 0,
          losses: json['losses'] as int? ?? 0,
          draws: json['draws'] as int? ?? 0,
        );

  @override
  List<Object?> get props => [wins, losses, draws];
}

class Friend extends Equatable {
  const Friend({
    required this.friendshipId,
    required this.player,
    required this.headToHead,
    this.friendsSince,
    this.isOnline = false,
    this.openMatchId,
  });

  final String friendshipId;
  final PlayerBrief player;
  final HeadToHead headToHead;
  final DateTime? friendsSince;
  final bool isOnline;

  /// An unfinished match with this friend, so the tile can say "continue"
  /// instead of offering a second, competing challenge.
  final String? openMatchId;

  factory Friend.fromJson(Map<String, dynamic> json) => Friend(
        friendshipId: json['friendship_id'] as String,
        player: PlayerBrief.fromJson(json['player'] as Map<String, dynamic>),
        headToHead: HeadToHead.fromJson(json['head_to_head'] as Map<String, dynamic>?),
        friendsSince: _parseUtc(json['friends_since']),
        isOnline: json['is_online'] as bool? ?? false,
        openMatchId: json['open_match_id'] as String?,
      );

  @override
  List<Object?> get props => [friendshipId, player, isOnline, openMatchId];
}

class FriendRequest extends Equatable {
  const FriendRequest({
    required this.id,
    required this.player,
    required this.isIncoming,
    required this.createdAt,
  });

  final String id;
  final PlayerBrief player;
  final bool isIncoming;
  final DateTime createdAt;

  factory FriendRequest.fromJson(Map<String, dynamic> json) => FriendRequest(
        id: json['id'] as String,
        player: PlayerBrief.fromJson(json['player'] as Map<String, dynamic>),
        isIncoming: json['direction'] == 'incoming',
        createdAt: _requireUtc(json['created_at']),
      );

  @override
  List<Object?> get props => [id, player, isIncoming];
}

class MatchParticipant extends Equatable {
  const MatchParticipant({
    required this.userId,
    required this.player,
    required this.status,
    this.isHost = false,
    this.isMe = false,
    this.isConnected = false,
    this.score = 0,
    this.correctCount = 0,
    this.roundsAnswered = 0,
    this.bestStreak = 0,
    this.answeredCurrentRound = false,
    this.placement,
    this.outcome,
    this.ratingDelta,
    this.xpEarned = 0,
    this.coinsEarned = 0,
  });

  final String userId;
  final PlayerBrief player;
  final ParticipantStatus status;
  final bool isHost;
  final bool isMe;
  final bool isConnected;
  final int score;
  final int correctCount;
  final int roundsAnswered;
  final int bestStreak;

  /// Whether they have answered the round in play. Carries no correctness —
  /// the server withholds that until the round closes, because "they got it
  /// right" before you have answered *is* the answer.
  final bool answeredCurrentRound;

  final int? placement;
  final MatchOutcome? outcome;
  final int? ratingDelta;
  final int xpEarned;
  final int coinsEarned;

  factory MatchParticipant.fromJson(Map<String, dynamic> json) => MatchParticipant(
        userId: json['user_id'] as String,
        player: PlayerBrief.fromJson(json['player'] as Map<String, dynamic>),
        status: _enumFromWire(
          ParticipantStatus.values,
          json['status'] as String?,
          ParticipantStatus.joined,
        ),
        isHost: json['is_host'] as bool? ?? false,
        isMe: json['is_me'] as bool? ?? false,
        isConnected: json['is_connected'] as bool? ?? false,
        score: json['score'] as int? ?? 0,
        correctCount: json['correct_count'] as int? ?? 0,
        roundsAnswered: json['rounds_answered'] as int? ?? 0,
        bestStreak: json['best_streak'] as int? ?? 0,
        answeredCurrentRound: json['answered_current_round'] as bool? ?? false,
        placement: json['placement'] as int?,
        outcome: json['outcome'] == null
            ? null
            : _enumFromWire(
                MatchOutcome.values, json['outcome'] as String?, MatchOutcome.draw),
        ratingDelta: json['rating_delta'] as int?,
        xpEarned: json['xp_earned'] as int? ?? 0,
        coinsEarned: json['coins_earned'] as int? ?? 0,
      );

  @override
  List<Object?> get props =>
      [userId, status, score, roundsAnswered, answeredCurrentRound, isConnected, placement];
}

class MatchState extends Equatable {
  const MatchState({
    required this.id,
    required this.format,
    required this.kind,
    required this.delivery,
    required this.status,
    required this.topicId,
    required this.topicName,
    required this.difficulty,
    required this.language,
    required this.questionCount,
    required this.questionTimeLimitMs,
    required this.maxPlayers,
    required this.currentRoundIndex,
    required this.hostUserId,
    required this.participants,
    required this.createdAt,
    required this.serverTime,
    this.code,
    this.startedAt,
    this.finishedAt,
    this.expiresAt,
    this.roundDeadlineAt,
    this.myRoundsAnswered = 0,
    this.myOutcome,
  });

  final String id;
  final String? code;
  final MatchFormat format;
  final MatchKind kind;
  final MatchDelivery delivery;
  final MatchStatus status;
  final String topicId;
  final String topicName;
  final String difficulty;
  final String language;
  final int questionCount;
  final int questionTimeLimitMs;
  final int maxPlayers;
  final int currentRoundIndex;
  final String hostUserId;
  final List<MatchParticipant> participants;
  final DateTime createdAt;
  final DateTime serverTime;
  final DateTime? startedAt;
  final DateTime? finishedAt;
  final DateTime? expiresAt;
  final DateTime? roundDeadlineAt;
  final int myRoundsAnswered;
  final MatchOutcome? myOutcome;

  /// How far this device's clock is ahead of the server's.
  ///
  /// Subtracting this from every server deadline is what keeps the countdown
  /// honest on a phone whose clock is wrong — which is common enough that a
  /// timer trusting the local clock will visibly lie to some players.
  Duration get clockSkew => DateTime.now().toUtc().difference(serverTime);

  /// Time left in the round, corrected for clock skew. Zero when there is no
  /// round in play.
  Duration get timeRemaining {
    final deadline = roundDeadlineAt;
    if (deadline == null) return Duration.zero;
    final left = deadline.difference(DateTime.now().toUtc().subtract(clockSkew));
    return left.isNegative ? Duration.zero : left;
  }

  MatchParticipant? get me =>
      participants.where((p) => p.isMe).cast<MatchParticipant?>().firstOrNull;

  List<MatchParticipant> get opponents =>
      participants.where((p) => !p.isMe).toList(growable: false);

  MatchParticipant? get primaryOpponent => opponents.firstOrNull;

  bool get isOver =>
      status == MatchStatus.completed ||
      status == MatchStatus.expired ||
      status == MatchStatus.cancelled;

  bool get isPlayable =>
      status == MatchStatus.live || status == MatchStatus.awaitingOpponent;

  bool get isInLobby =>
      status == MatchStatus.pending || status == MatchStatus.lobby;

  /// True when this player still owes the match a turn.
  bool get isMyTurn => isPlayable && myRoundsAnswered < questionCount;

  bool amHost(String userId) => hostUserId == userId;

  factory MatchState.fromJson(Map<String, dynamic> json) => MatchState(
        id: json['id'] as String,
        code: json['code'] as String?,
        format: _enumFromWire(MatchFormat.values, json['format'] as String?, MatchFormat.duel),
        kind: _enumFromWire(MatchKind.values, json['kind'] as String?, MatchKind.friendly),
        delivery: _deliveryFromWire(json['delivery'] as String?),
        status: _enumFromWire(
            MatchStatus.values, json['status'] as String?, MatchStatus.pending),
        topicId: json['topic_id'] as String,
        topicName: json['topic_name'] as String? ?? '',
        difficulty: json['difficulty'] as String? ?? 'medium',
        language: json['language'] as String? ?? 'en',
        questionCount: json['question_count'] as int? ?? 0,
        questionTimeLimitMs: json['question_time_limit_ms'] as int? ?? 15000,
        maxPlayers: json['max_players'] as int? ?? 2,
        currentRoundIndex: json['current_round_index'] as int? ?? 0,
        hostUserId: json['host_user_id'] as String,
        participants: (json['participants'] as List<dynamic>? ?? const [])
            .map((e) => MatchParticipant.fromJson(e as Map<String, dynamic>))
            .toList(growable: false),
        createdAt: _requireUtc(json['created_at']),
        serverTime: _requireUtc(json['server_time']),
        startedAt: _parseUtc(json['started_at']),
        finishedAt: _parseUtc(json['finished_at']),
        expiresAt: _parseUtc(json['expires_at']),
        roundDeadlineAt: _parseUtc(json['round_deadline_at']),
        myRoundsAnswered: json['my_rounds_answered'] as int? ?? 0,
        myOutcome: json['my_outcome'] == null
            ? null
            : _enumFromWire(
                MatchOutcome.values, json['my_outcome'] as String?, MatchOutcome.draw),
      );

  @override
  List<Object?> get props =>
      [id, status, delivery, currentRoundIndex, participants, roundDeadlineAt];
}

class MatchOption extends Equatable {
  const MatchOption({required this.index, required this.text});

  final int index;
  final String text;

  factory MatchOption.fromJson(Map<String, dynamic> json) =>
      MatchOption(index: json['index'] as int, text: json['text'] as String);

  @override
  List<Object?> get props => [index, text];
}

class MatchRound extends Equatable {
  const MatchRound({
    required this.roundIndex,
    required this.totalRounds,
    required this.questionId,
    required this.prompt,
    required this.options,
    required this.timeLimitMs,
    required this.deadlineAt,
    required this.servedAt,
    required this.serverTime,
    this.alreadyAnswered = false,
  });

  final int roundIndex;
  final int totalRounds;
  final String questionId;
  final String prompt;
  final List<MatchOption> options;
  final int timeLimitMs;
  final DateTime deadlineAt;
  final DateTime servedAt;
  final DateTime serverTime;
  final bool alreadyAnswered;

  Duration get clockSkew => DateTime.now().toUtc().difference(serverTime);

  Duration get timeRemaining {
    final left = deadlineAt.difference(DateTime.now().toUtc().subtract(clockSkew));
    return left.isNegative ? Duration.zero : left;
  }

  factory MatchRound.fromJson(Map<String, dynamic> json) => MatchRound(
        roundIndex: json['round_index'] as int,
        totalRounds: json['total_rounds'] as int,
        questionId: json['question_id'] as String,
        prompt: json['prompt'] as String,
        options: (json['options'] as List<dynamic>? ?? const [])
            .map((e) => MatchOption.fromJson(e as Map<String, dynamic>))
            .toList(growable: false),
        timeLimitMs: json['time_limit_ms'] as int? ?? 15000,
        deadlineAt: _requireUtc(json['deadline_at']),
        servedAt: _requireUtc(json['served_at']),
        serverTime: _requireUtc(json['server_time']),
        alreadyAnswered: json['already_answered'] as bool? ?? false,
      );

  @override
  List<Object?> get props => [roundIndex, questionId, deadlineAt, alreadyAnswered];
}

class OpponentRoundState extends Equatable {
  const OpponentRoundState({
    required this.userId,
    required this.answered,
    this.isCorrect,
    this.pointsAwarded,
  });

  final String userId;
  final bool answered;
  final bool? isCorrect;
  final int? pointsAwarded;

  factory OpponentRoundState.fromJson(Map<String, dynamic> json) => OpponentRoundState(
        userId: json['user_id'] as String,
        answered: json['answered'] as bool? ?? false,
        isCorrect: json['is_correct'] as bool?,
        pointsAwarded: json['points_awarded'] as int?,
      );

  @override
  List<Object?> get props => [userId, answered, isCorrect];
}

class MatchAnswerFeedback extends Equatable {
  const MatchAnswerFeedback({
    required this.roundIndex,
    required this.isCorrect,
    required this.correctOptionIndex,
    required this.pointsAwarded,
    required this.speedBonus,
    required this.streak,
    required this.score,
    required this.roundClosed,
    required this.matchFinished,
    required this.opponents,
    this.selectedOptionIndex,
    this.explanation,
  });

  final int roundIndex;
  final bool isCorrect;
  final int correctOptionIndex;
  final int? selectedOptionIndex;
  final int pointsAwarded;
  final int speedBonus;
  final int streak;
  final int score;
  final bool roundClosed;
  final bool matchFinished;
  final String? explanation;
  final List<OpponentRoundState> opponents;

  factory MatchAnswerFeedback.fromJson(Map<String, dynamic> json) => MatchAnswerFeedback(
        roundIndex: json['round_index'] as int,
        isCorrect: json['is_correct'] as bool? ?? false,
        correctOptionIndex: json['correct_option_index'] as int? ?? 0,
        selectedOptionIndex: json['selected_option_index'] as int?,
        pointsAwarded: json['points_awarded'] as int? ?? 0,
        speedBonus: json['speed_bonus'] as int? ?? 0,
        streak: json['streak'] as int? ?? 0,
        score: json['score'] as int? ?? 0,
        roundClosed: json['round_closed'] as bool? ?? false,
        matchFinished: json['match_finished'] as bool? ?? false,
        explanation: json['explanation'] as String?,
        opponents: (json['opponents'] as List<dynamic>? ?? const [])
            .map((e) => OpponentRoundState.fromJson(e as Map<String, dynamic>))
            .toList(growable: false),
      );

  @override
  List<Object?> get props => [roundIndex, isCorrect, score, roundClosed, matchFinished];
}

class MatchResult extends Equatable {
  const MatchResult({
    required this.match,
    required this.standings,
    this.myOutcome,
    this.myPlacement,
    this.ratingDelta,
    this.xpEarned = 0,
    this.coinsEarned = 0,
  });

  final MatchState match;
  final List<MatchParticipant> standings;
  final MatchOutcome? myOutcome;
  final int? myPlacement;
  final int? ratingDelta;
  final int xpEarned;
  final int coinsEarned;

  factory MatchResult.fromJson(Map<String, dynamic> json) => MatchResult(
        match: MatchState.fromJson(json['match'] as Map<String, dynamic>),
        standings: (json['standings'] as List<dynamic>? ?? const [])
            .map((e) => MatchParticipant.fromJson(e as Map<String, dynamic>))
            .toList(growable: false),
        myOutcome: json['my_outcome'] == null
            ? null
            : _enumFromWire(
                MatchOutcome.values, json['my_outcome'] as String?, MatchOutcome.draw),
        myPlacement: json['my_placement'] as int?,
        ratingDelta: json['rating_delta'] as int?,
        xpEarned: json['xp_earned'] as int? ?? 0,
        coinsEarned: json['coins_earned'] as int? ?? 0,
      );

  @override
  List<Object?> get props => [match, standings, myOutcome, ratingDelta];
}

class RankedProfile extends Equatable {
  const RankedProfile({
    required this.seasonKey,
    required this.rating,
    required this.peakRating,
    required this.tier,
    required this.tierName,
    required this.tierIcon,
    required this.placementsRemaining,
    required this.matchesPlayed,
    required this.wins,
    required this.losses,
    required this.draws,
    required this.winStreak,
    this.nextTier,
    this.nextTierAt,
    this.rank,
  });

  final String seasonKey;
  final int rating;
  final int peakRating;
  final String tier;
  final String tierName;
  final String tierIcon;
  final String? nextTier;
  final int? nextTierAt;
  final int placementsRemaining;
  final int matchesPlayed;
  final int wins;
  final int losses;
  final int draws;
  final int winStreak;
  final int? rank;

  bool get isProvisional => placementsRemaining > 0;

  /// Progress toward the next tier, 0..1. Full at the top of the ladder.
  double get tierProgress {
    final target = nextTierAt;
    if (target == null || target <= 0) return 1;
    return (rating / target).clamp(0.0, 1.0);
  }

  factory RankedProfile.fromJson(Map<String, dynamic> json) => RankedProfile(
        seasonKey: json['season_key'] as String? ?? '',
        rating: json['rating'] as int? ?? 1000,
        peakRating: json['peak_rating'] as int? ?? 1000,
        tier: json['tier'] as String? ?? 'unranked',
        tierName: json['tier_name'] as String? ?? 'Unranked',
        tierIcon: json['tier_icon'] as String? ?? 'tier_unranked',
        nextTier: json['next_tier'] as String?,
        nextTierAt: json['next_tier_at'] as int?,
        placementsRemaining: json['placements_remaining'] as int? ?? 0,
        matchesPlayed: json['matches_played'] as int? ?? 0,
        wins: json['wins'] as int? ?? 0,
        losses: json['losses'] as int? ?? 0,
        draws: json['draws'] as int? ?? 0,
        winStreak: json['win_streak'] as int? ?? 0,
        rank: json['rank'] as int?,
      );

  @override
  List<Object?> get props => [seasonKey, rating, tier, placementsRemaining, rank];
}

class RankedLeaderboardEntry extends Equatable {
  const RankedLeaderboardEntry({
    required this.rank,
    required this.player,
    required this.rating,
    required this.wins,
    required this.losses,
    required this.isMe,
  });

  final int rank;
  final PlayerBrief player;
  final int rating;
  final int wins;
  final int losses;
  final bool isMe;

  factory RankedLeaderboardEntry.fromJson(Map<String, dynamic> json) =>
      RankedLeaderboardEntry(
        rank: json['rank'] as int,
        player: PlayerBrief.fromJson(json['player'] as Map<String, dynamic>),
        rating: json['rating'] as int? ?? 0,
        wins: json['wins'] as int? ?? 0,
        losses: json['losses'] as int? ?? 0,
        isMe: json['is_me'] as bool? ?? false,
      );

  @override
  List<Object?> get props => [rank, player, rating, isMe];
}

enum QueueState { searching, matched, timeout, cancelled }

class QueueTicket extends Equatable {
  const QueueTicket({
    required this.state,
    this.matchId,
    this.waitedSeconds = 0,
    this.band = 0,
    this.playersSearching,
  });

  final QueueState state;
  final String? matchId;
  final int waitedSeconds;
  final int band;
  final int? playersSearching;

  factory QueueTicket.fromJson(Map<String, dynamic> json) => QueueTicket(
        state: _enumFromWire(
            QueueState.values, json['state'] as String?, QueueState.searching),
        matchId: json['match_id'] as String?,
        waitedSeconds: json['waited_seconds'] as int? ?? 0,
        band: json['band'] as int? ?? 0,
        playersSearching: json['players_searching'] as int?,
      );

  @override
  List<Object?> get props => [state, matchId, waitedSeconds, band];
}

class UsernameStatus extends Equatable {
  const UsernameStatus({
    required this.username,
    required this.friendCode,
    this.changeAvailableAt,
  });

  final String username;
  final String friendCode;

  /// Null when the player may rename right now.
  final DateTime? changeAvailableAt;

  bool get canChangeNow => changeAvailableAt == null;

  factory UsernameStatus.fromJson(Map<String, dynamic> json) => UsernameStatus(
        username: json['username'] as String,
        friendCode: json['friend_code'] as String? ?? '',
        changeAvailableAt: _parseUtc(json['change_available_at']),
      );

  @override
  List<Object?> get props => [username, friendCode, changeAvailableAt];
}

class UsernameAvailability extends Equatable {
  const UsernameAvailability({
    required this.username,
    required this.available,
    this.reason,
    this.suggestions = const [],
  });

  final String username;
  final bool available;

  /// Machine-readable code (`username_taken`, `username_charset`, …). The
  /// client renders the sentence from its own string table so the message is
  /// in the player's language, not the server's.
  final String? reason;
  final List<String> suggestions;

  factory UsernameAvailability.fromJson(Map<String, dynamic> json) => UsernameAvailability(
        username: json['username'] as String? ?? '',
        available: json['available'] as bool? ?? false,
        reason: json['reason'] as String?,
        suggestions: (json['suggestions'] as List<dynamic>? ?? const [])
            .cast<String>()
            .toList(growable: false),
      );

  @override
  List<Object?> get props => [username, available, reason];
}

enum AppNotificationType {
  friendRequest,
  friendAccepted,
  matchInvite,
  matchYourTurn,
  matchResult,
  matchExpiring,
}

class AppNotification extends Equatable {
  const AppNotification({
    required this.id,
    required this.type,
    required this.createdAt,
    this.actor,
    this.matchId,
    this.payload = const {},
    this.deepLink,
    this.readAt,
  });

  final String id;
  final AppNotificationType type;
  final PlayerBrief? actor;
  final String? matchId;
  final Map<String, dynamic> payload;
  final String? deepLink;
  final DateTime? readAt;
  final DateTime createdAt;

  bool get isUnread => readAt == null;

  factory AppNotification.fromJson(Map<String, dynamic> json) => AppNotification(
        id: json['id'] as String,
        type: _enumFromWire(
          AppNotificationType.values,
          json['type'] as String?,
          AppNotificationType.matchResult,
        ),
        actor: json['actor'] == null
            ? null
            : PlayerBrief.fromJson(json['actor'] as Map<String, dynamic>),
        matchId: json['match_id'] as String?,
        payload: (json['payload'] as Map<String, dynamic>?) ?? const {},
        deepLink: json['deep_link'] as String?,
        readAt: _parseUtc(json['read_at']),
        createdAt: _requireUtc(json['created_at']),
      );

  @override
  List<Object?> get props => [id, type, readAt];
}

class SocialSummary extends Equatable {
  const SocialSummary({
    this.friendRequests = 0,
    this.unreadNotifications = 0,
    this.matchesAwaitingYou = 0,
    this.onlineFriendIds = const {},
  });

  final int friendRequests;
  final int unreadNotifications;
  final int matchesAwaitingYou;
  final Set<String> onlineFriendIds;

  int get badgeCount => friendRequests + matchesAwaitingYou;

  factory SocialSummary.fromJson(Map<String, dynamic> json) => SocialSummary(
        friendRequests: json['friend_requests'] as int? ?? 0,
        unreadNotifications: json['unread_notifications'] as int? ?? 0,
        matchesAwaitingYou: json['matches_awaiting_you'] as int? ?? 0,
        onlineFriendIds:
            (json['online_friend_ids'] as List<dynamic>? ?? const []).cast<String>().toSet(),
      );

  @override
  List<Object?> get props =>
      [friendRequests, unreadNotifications, matchesAwaitingYou, onlineFriendIds];
}

extension _FirstOrNull<T> on Iterable<T> {
  T? get firstOrNull => isEmpty ? null : first;
}
