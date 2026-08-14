import 'package:flutter_test/flutter_test.dart';
import 'package:speedquiz/features/multiplayer/domain/multiplayer_models.dart';

/// Cover for the two things the battle screen now does without a round trip:
/// building a playable round straight off a `round.start` event, and folding
/// score updates into the match it already holds.
///
/// Both used to be a `GET /matches/{id}` per event — which is what made a live
/// round feel slow, and what stranded a player on a spinner when the fetch was
/// skipped.

const _me = '00000000-0000-0000-0000-0000000000a1';
const _them = '00000000-0000-0000-0000-0000000000b2';

Map<String, dynamic> _participant(String userId, {required bool isMe, int score = 0}) {
  return {
    'user_id': userId,
    'player': {'user_id': userId, 'username': isMe ? 'me' : 'them'},
    'status': 'playing',
    'is_me': isMe,
    'score': score,
    'answered_current_round': false,
  };
}

MatchState _match({int currentRound = 0, String status = 'live'}) {
  return MatchState.fromJson({
    'id': '00000000-0000-0000-0000-00000000000f',
    'topic_id': '00000000-0000-0000-0000-00000000000e',
    'host_user_id': _me,
    'status': status,
    'delivery': 'live',
    'question_count': 7,
    'current_round_index': currentRound,
    'server_time': '2026-08-14T10:00:00Z',
    'created_at': '2026-08-14T09:59:00Z',
    'participants': [
      _participant(_me, isMe: true, score: 120),
      _participant(_them, isMe: false, score: 90),
    ],
  });
}

/// A `round.start` as the server publishes it.
Map<String, dynamic> _roundStart() => {
      'round_index': 2,
      'total_rounds': 7,
      'starts_at': '2026-08-14T10:00:03Z',
      'deadline_at': '2026-08-14T10:00:18Z',
      'server_time': '2026-08-14T10:00:00Z',
      'question': {
        'question_id': '00000000-0000-0000-0000-0000000000c3',
        'prompt': 'Which planet is closest to the sun?',
        'time_limit_ms': 15000,
        'options': [
          {'index': 0, 'text': 'Mercury'},
          {'index': 1, 'text': 'Venus'},
          {'index': 2, 'text': 'Mars'},
          {'index': 3, 'text': 'Earth'},
        ],
      },
    };

void main() {
  group('round.start', () {
    test('builds a playable round with no further request', () {
      final round = MatchRound.fromEvent(_roundStart());

      expect(round, isNotNull);
      expect(round!.roundIndex, 2);
      expect(round.totalRounds, 7);
      expect(round.prompt, 'Which planet is closest to the sun?');
      expect(round.options.map((o) => o.text), [
        'Mercury',
        'Venus',
        'Mars',
        'Earth',
      ]);
      expect(round.timeLimitMs, 15000);
    });

    test('anchors the clock to when the server opens the round', () {
      // `starts_at` is a reveal pause after `server_time`, and the deadline is
      // measured from it — not from whenever this device got the event.
      final round = MatchRound.fromEvent(_roundStart())!;

      expect(round.servedAt, DateTime.utc(2026, 8, 14, 10, 0, 3));
      expect(round.deadlineAt, DateTime.utc(2026, 8, 14, 10, 0, 18));
      expect(round.deadlineAt.difference(round.servedAt).inMilliseconds, 15000);
    });

    test('falls back to an HTTP fetch when the event carries no question', () {
      final event = _roundStart()..remove('question');
      expect(MatchRound.fromEvent(event), isNull);
    });

    test('falls back rather than rendering a half-parsed question', () {
      final event = _roundStart();
      (event['question'] as Map<String, dynamic>).remove('prompt');
      expect(MatchRound.fromEvent(event), isNull);
    });
  });

  group('applying event payloads to the held match', () {
    test('withScores moves only the players the event named', () {
      final updated = _match().withScores({_them: 175});

      expect(updated.participants.firstWhere((p) => p.userId == _them).score, 175);
      expect(updated.participants.firstWhere((p) => p.isMe).score, 120);
    });

    test('withScores leaves the match alone when the map is empty', () {
      final before = _match();
      expect(before.withScores(const {}), before);
    });

    test('withAnswered lights one pip and no others', () {
      final updated = _match().withAnswered(_them);

      expect(
        updated.participants.firstWhere((p) => p.userId == _them).answeredCurrentRound,
        isTrue,
      );
      expect(
        updated.participants.firstWhere((p) => p.isMe).answeredCurrentRound,
        isFalse,
      );
    });

    test('withRoundReset clears every pip for the next round', () {
      final updated = _match().withAnswered(_them).withAnswered(_me).withRoundReset();

      expect(
        updated.participants.every((p) => !p.answeredCurrentRound),
        isTrue,
      );
    });

    test('carries the rest of the match across untouched', () {
      final before = _match(currentRound: 3);
      final after = before.withScores({_me: 200});

      expect(after.id, before.id);
      expect(after.status, before.status);
      expect(after.currentRoundIndex, 3);
      expect(after.questionCount, before.questionCount);
      expect(after.roundDeadlineAt, before.roundDeadlineAt);
    });
  });

  group('rebuild triggers', () {
    test('finishing the last round is a change the screen rebuilds for', () {
      // `my_rounds_answered` decides between the board and the waiting view.
      // Left out of props, answering the final question changed nothing the
      // widget tree could see.
      MatchState withAnswered(int count) => MatchState.fromJson({
            'id': '00000000-0000-0000-0000-00000000000f',
            'topic_id': '00000000-0000-0000-0000-00000000000e',
            'host_user_id': _me,
            'status': 'live',
            'question_count': 7,
            'my_rounds_answered': count,
            'server_time': '2026-08-14T10:00:00Z',
            'created_at': '2026-08-14T09:59:00Z',
            'participants': [_participant(_me, isMe: true)],
          });

      expect(withAnswered(6), isNot(withAnswered(7)));
      expect(withAnswered(6).isMyTurn, isTrue);
      expect(withAnswered(7).isMyTurn, isFalse);
    });
  });
}
