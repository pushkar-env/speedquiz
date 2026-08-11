import 'dart:math' as math;

import 'package:dio/dio.dart';
import 'package:equatable/equatable.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:speedquiz/core/config/app_config.dart';
import 'package:speedquiz/core/network/dio_client.dart';

/// A topic's category, as sent by `GET /api/v1/topics`.
class TopicCategory extends Equatable {
  const TopicCategory({
    required this.slug,
    required this.name,
    required this.icon,
    required this.sortOrder,
  });

  final String slug;
  final String name;
  final String icon;
  final int sortOrder;

  /// Bucket for topics the server did not categorise.
  static const other = TopicCategory(
    slug: '_other',
    name: 'More',
    icon: '✨',
    sortOrder: 9999,
  );

  factory TopicCategory.fromJson(Map<String, dynamic> json) {
    return TopicCategory(
      slug: json['slug'] as String,
      name: json['name'] as String,
      icon: json['icon'] as String? ?? '✨',
      sortOrder: json['sort_order'] as int? ?? 500,
    );
  }

  @override
  List<Object?> get props => [slug];
}

class TopicItem extends Equatable {
  const TopicItem({
    required this.id,
    required this.name,
    required this.icon,
    required this.questionCount,
    this.slug = '',
    this.description,
    this.category,
    this.isTrending = false,
    this.popularityScore = 0,
  });

  final String id;
  final String slug;
  final String name;
  final String? description;
  final String icon;
  final int questionCount;
  final TopicCategory? category;
  final bool isTrending;
  final int popularityScore;

  /// A topic with no banked questions cannot be played yet.
  bool get isPlayable => questionCount > 0;

  /// Category used for grouping, with a stable fallback bucket.
  TopicCategory get group => category ?? TopicCategory.other;

  factory TopicItem.fromJson(Map<String, dynamic> json) {
    final rawCategory = json['category'];
    return TopicItem(
      id: json['id'] as String,
      slug: json['slug'] as String? ?? '',
      name: json['name'] as String,
      description: json['description'] as String?,
      icon: json['icon'] as String? ?? '✨',
      questionCount: json['question_count'] as int? ?? 0,
      category: rawCategory is Map<String, dynamic>
          ? TopicCategory.fromJson(rawCategory)
          : null,
      isTrending: json['is_trending'] as bool? ?? false,
      popularityScore: json['popularity_score'] as int? ?? 0,
    );
  }

  @override
  List<Object?> get props => [id, name, icon, questionCount, isTrending];
}

/// Topics grouped under one category header.
class TopicGroup extends Equatable {
  const TopicGroup({required this.category, required this.topics});

  final TopicCategory category;
  final List<TopicItem> topics;

  int get playableCount => topics.where((t) => t.isPlayable).length;

  @override
  List<Object?> get props => [category, topics];
}

class TopicsRepository {
  TopicsRepository(this._dio);

  final Dio _dio;

  Future<List<TopicItem>> list() async {
    final response = await _dio.get(
      '${AppConfig.apiPrefix}/topics',
      queryParameters: {'limit': 100},
    );
    final items = (response.data['items'] as List<dynamic>? ?? [])
        .map((e) => TopicItem.fromJson(e as Map<String, dynamic>))
        .toList();
    // Richest banks first so shortcuts always point somewhere playable.
    items.sort((a, b) {
      final byCount = b.questionCount.compareTo(a.questionCount);
      return byCount != 0 ? byCount : a.name.compareTo(b.name);
    });
    return items;
  }
}

final topicsRepositoryProvider = Provider<TopicsRepository>((ref) {
  return TopicsRepository(ref.watch(dioProvider));
});

/// Shared across Home, Explore and Quiz Setup — kept alive so switching tabs
/// does not refetch the catalog.
final topicsProvider = FutureProvider<List<TopicItem>>((ref) {
  return ref.watch(topicsRepositoryProvider).list();
});

/// Topics that currently have questions banked.
final playableTopicsProvider = Provider<List<TopicItem>>((ref) {
  return ref.watch(topicsProvider).valueOrNull?.where((t) => t.isPlayable).toList() ??
      const [];
});

/// Trending topics that are actually playable, best-stocked first.
final trendingTopicsProvider = Provider<List<TopicItem>>((ref) {
  return ref
      .watch(playableTopicsProvider)
      .where((t) => t.isTrending)
      .toList();
});

/// Playable topics grouped by category, ordered the way the server orders
/// categories. Powers the sectioned Explore and Setup lists.
final topicGroupsProvider = Provider<List<TopicGroup>>((ref) {
  return groupTopics(ref.watch(playableTopicsProvider));
});

/// Pure helper so grouping is testable without a container.
List<TopicGroup> groupTopics(List<TopicItem> topics) {
  final buckets = <String, List<TopicItem>>{};
  final categories = <String, TopicCategory>{};

  for (final topic in topics) {
    final category = topic.group;
    categories[category.slug] = category;
    buckets.putIfAbsent(category.slug, () => []).add(topic);
  }

  final groups = buckets.entries
      .map(
        (entry) => TopicGroup(
          category: categories[entry.key]!,
          topics: entry.value..sort((a, b) => a.name.compareTo(b.name)),
        ),
      )
      .toList();

  groups.sort((a, b) {
    final byOrder = a.category.sortOrder.compareTo(b.category.sortOrder);
    return byOrder != 0 ? byOrder : a.category.name.compareTo(b.category.name);
  });
  return groups;
}

/// Picks a random playable topic, weighted toward deeper question banks so
/// "Surprise me" rarely lands on a nearly-empty topic.
TopicItem? pickRandomTopic(List<TopicItem> topics, {math.Random? random}) {
  final playable = topics.where((t) => t.isPlayable).toList();
  if (playable.isEmpty) return null;
  if (playable.length == 1) return playable.first;

  final rng = random ?? math.Random();
  final weights = playable
      .map((t) => math.sqrt(t.questionCount.toDouble()).clamp(1.0, 1e6))
      .toList();
  final total = weights.fold<double>(0, (sum, w) => sum + w);

  var roll = rng.nextDouble() * total;
  for (var i = 0; i < playable.length; i++) {
    roll -= weights[i];
    if (roll <= 0) return playable[i];
  }
  return playable.last;
}

/// Random topic drawn from the loaded catalog, or null while it is empty.
final randomTopicProvider = Provider<TopicItem?>((ref) {
  return pickRandomTopic(ref.watch(playableTopicsProvider));
});
