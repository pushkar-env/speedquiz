import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:speedquiz/features/profile/domain/avatar_catalog.dart';
import 'package:speedquiz/features/topics/data/topics_repository.dart';
import 'package:speedquiz/features/topics/presentation/topic_tile.dart';

const _science = TopicCategory(
  slug: 'science',
  name: 'Science',
  icon: '🔬',
  sortOrder: 10,
);
const _gaming = TopicCategory(
  slug: 'gaming',
  name: 'Gaming',
  icon: '🎮',
  sortOrder: 50,
);

TopicItem _topic(
  String id,
  String name, {
  int count = 100,
  TopicCategory? category,
}) {
  return TopicItem(
    id: id,
    slug: name.toLowerCase(),
    name: name,
    icon: '✨',
    questionCount: count,
    category: category,
  );
}

void main() {
  group('groupTopics', () {
    test('orders groups by the server category order', () {
      final groups = groupTopics([
        _topic('1', 'Gaming', category: _gaming),
        _topic('2', 'Astronomy', category: _science),
      ]);

      expect(groups.map((g) => g.category.slug), ['science', 'gaming']);
    });

    test('sorts topics alphabetically inside a group', () {
      final groups = groupTopics([
        _topic('1', 'Zoology', category: _science),
        _topic('2', 'Astronomy', category: _science),
        _topic('3', 'Marine Biology', category: _science),
      ]);

      expect(
        groups.single.topics.map((t) => t.name),
        ['Astronomy', 'Marine Biology', 'Zoology'],
      );
    });

    test('buckets uncategorised topics last instead of dropping them', () {
      final groups = groupTopics([
        _topic('1', 'Loose Topic'),
        _topic('2', 'Astronomy', category: _science),
      ]);

      expect(groups.first.category.slug, 'science');
      expect(groups.last.category.slug, TopicCategory.other.slug);
      expect(groups.last.topics.single.name, 'Loose Topic');
    });

    test('returns nothing for an empty catalog', () {
      expect(groupTopics(const []), isEmpty);
    });
  });

  group('pickRandomTopic', () {
    test('never returns a topic with an empty bank', () {
      final topics = [
        _topic('1', 'Empty', count: 0),
        _topic('2', 'Stocked', count: 300),
        _topic('3', 'Also Empty', count: 0),
      ];

      for (var seed = 0; seed < 50; seed++) {
        final picked = pickRandomTopic(topics, random: math.Random(seed));
        expect(picked?.name, 'Stocked');
      }
    });

    test('returns null when nothing is playable', () {
      expect(pickRandomTopic([_topic('1', 'Empty', count: 0)]), isNull);
    });

    test('reaches every playable topic across many draws', () {
      final topics = [
        _topic('1', 'A', count: 200),
        _topic('2', 'B', count: 200),
        _topic('3', 'C', count: 200),
      ];

      final seen = <String>{};
      for (var seed = 0; seed < 200; seed++) {
        seen.add(pickRandomTopic(topics, random: math.Random(seed))!.name);
      }
      expect(seen, {'A', 'B', 'C'});
    });

    test('favours deeper banks without starving thin ones', () {
      final topics = [
        _topic('1', 'Deep', count: 900),
        _topic('2', 'Thin', count: 10),
      ];

      var deep = 0;
      const draws = 400;
      for (var seed = 0; seed < draws; seed++) {
        if (pickRandomTopic(topics, random: math.Random(seed))!.name ==
            'Deep') {
          deep++;
        }
      }
      expect(deep, greaterThan(draws ~/ 2));
      expect(deep, lessThan(draws));
    });
  });

  group('topicDepth', () {
    test('maps bank size onto the meter', () {
      expect(topicDepth(10), TopicDepth.thin);
      expect(topicDepth(200), TopicDepth.solid);
      expect(topicDepth(900), TopicDepth.deep);
    });
  });

  group('AvatarCatalog', () {
    test('resolves a known id exactly', () {
      expect(AvatarCatalog.resolve('avatar_03').name, 'Nebula');
    });

    test('falls back to a stable pick for unknown ids', () {
      final first = AvatarCatalog.resolve('nope', seed: 'user-123');
      final second = AvatarCatalog.resolve('nope', seed: 'user-123');
      expect(first.id, second.id);
    });

    test('different seeds generally land on different presets', () {
      final ids = {
        for (final seed in ['a', 'b', 'c', 'd', 'e', 'f'])
          AvatarCatalog.resolve(null, seed: seed).id,
      };
      expect(ids.length, greaterThan(1));
    });
  });
}
