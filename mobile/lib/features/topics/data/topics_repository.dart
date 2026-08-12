import 'dart:math' as math;

import 'package:dio/dio.dart';
import 'package:equatable/equatable.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:speedquiz/core/config/app_config.dart';
import 'package:speedquiz/core/i18n/language_providers.dart';
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
    this.questionCounts = const {},
  });

  final String id;
  final String slug;
  final String name;
  final String? description;
  final String icon;

  /// Banked questions across every language.
  final int questionCount;

  /// Banked questions per language code — `{'en': 412, 'hi': 60}`.
  ///
  /// A topic can be deep in one language and empty in another, so this, not
  /// [questionCount], decides whether it can be offered for a given run.
  final Map<String, int> questionCounts;

  final TopicCategory? category;
  final bool isTrending;
  final int popularityScore;

  /// A topic with no banked questions in any language cannot be played yet.
  bool get isPlayable => questionCount > 0;

  /// Questions banked in [languageCode].
  ///
  /// Falls back to the total when the server sent no breakdown at all, so a
  /// client running against an older backend keeps working instead of
  /// declaring every topic empty.
  int countIn(String languageCode) {
    if (questionCounts.isEmpty) return questionCount;
    return questionCounts[languageCode] ?? 0;
  }

  bool isPlayableIn(String languageCode) => countIn(languageCode) > 0;

  /// Category used for grouping, with a stable fallback bucket.
  TopicCategory get group => category ?? TopicCategory.other;

  factory TopicItem.fromJson(Map<String, dynamic> json) {
    final rawCategory = json['category'];
    final rawCounts = json['question_counts'];
    return TopicItem(
      id: json['id'] as String,
      slug: json['slug'] as String? ?? '',
      name: json['name'] as String,
      description: json['description'] as String?,
      icon: json['icon'] as String? ?? '✨',
      questionCount: json['question_count'] as int? ?? 0,
      questionCounts: rawCounts is Map
          ? {
              for (final entry in rawCounts.entries)
                entry.key.toString(): (entry.value as num?)?.toInt() ?? 0,
            }
          : const {},
      category: rawCategory is Map<String, dynamic>
          ? TopicCategory.fromJson(rawCategory)
          : null,
      isTrending: json['is_trending'] as bool? ?? false,
      popularityScore: json['popularity_score'] as int? ?? 0,
    );
  }

  @override
  List<Object?> get props =>
      [id, name, icon, questionCount, questionCounts, isTrending];
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

  /// The catalog, with display names in [languageCode].
  ///
  /// Names follow the *app* language — this is browsing chrome. Which language
  /// a topic can actually be played in is a separate question, answered by
  /// [TopicItem.countIn].
  Future<List<TopicItem>> list({String languageCode = 'en'}) async {
    final response = await _dio.get(
      '${AppConfig.apiPrefix}/topics',
      queryParameters: {'limit': 100, 'language': languageCode},
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
///
/// Watches the app language, so changing it refetches the catalog with
/// localized names. That is one request per language change, and it is what
/// keeps topic chips from staying English on an otherwise Hindi screen.
final topicsProvider = FutureProvider<List<TopicItem>>((ref) {
  final language = ref.watch(appLanguageProvider);
  return ref.watch(topicsRepositoryProvider).list(languageCode: language.code);
});

/// Topics that currently have questions banked, in any language.
final playableTopicsProvider = Provider<List<TopicItem>>((ref) {
  return ref.watch(topicsProvider).valueOrNull?.where((t) => t.isPlayable).toList() ??
      const [];
});

/// Topics playable in the currently selected *quiz* language.
///
/// This is the list any "start a run" shortcut must draw from: sending a
/// player into a topic with no questions in their language is a dead end at
/// the one moment they expected to be playing.
final playableTopicsInQuizLanguageProvider = Provider<List<TopicItem>>((ref) {
  final language = ref.watch(quizLanguageProvider);
  return ref
      .watch(playableTopicsProvider)
      .where((t) => t.isPlayableIn(language.code))
      .toList();
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
///
/// [languageCode] scopes both the eligibility test and the weighting to one
/// language's bank — a topic with 400 English and 4 Hindi questions should be
/// a rare pick for a Hindi run, not the most likely one.
TopicItem? pickRandomTopic(
  List<TopicItem> topics, {
  math.Random? random,
  String? languageCode,
}) {
  final playable = topics
      .where((t) => languageCode == null ? t.isPlayable : t.isPlayableIn(languageCode))
      .toList();
  if (playable.isEmpty) return null;
  if (playable.length == 1) return playable.first;

  final rng = random ?? math.Random();
  final weights = playable
      .map((t) => math
          .sqrt(
            (languageCode == null ? t.questionCount : t.countIn(languageCode))
                .toDouble(),
          )
          .clamp(1.0, 1e6))
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
///
/// Scoped to the quiz language: "Surprise me" has to land somewhere playable.
final randomTopicProvider = Provider<TopicItem?>((ref) {
  final language = ref.watch(quizLanguageProvider);
  return pickRandomTopic(
    ref.watch(playableTopicsProvider),
    languageCode: language.code,
  );
});
