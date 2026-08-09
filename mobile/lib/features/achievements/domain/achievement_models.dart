import 'package:equatable/equatable.dart';

class AchievementItem extends Equatable {
  const AchievementItem({
    required this.id,
    required this.code,
    required this.name,
    required this.description,
    required this.icon,
    required this.category,
    required this.xpReward,
    required this.coinsReward,
    required this.sortOrder,
    required this.unlocked,
    this.unlockedAt,
  });

  final String id;
  final String code;
  final String name;
  final String description;
  final String icon;
  final String category;
  final int xpReward;
  final int coinsReward;
  final int sortOrder;
  final bool unlocked;
  final DateTime? unlockedAt;

  factory AchievementItem.fromJson(Map<String, dynamic> json) {
    return AchievementItem(
      id: json['id'] as String,
      code: json['code'] as String,
      name: json['name'] as String,
      description: json['description'] as String,
      icon: json['icon'] as String? ?? 'trophy',
      category: json['category'] as String? ?? 'general',
      xpReward: json['xp_reward'] as int? ?? 0,
      coinsReward: json['coins_reward'] as int? ?? 0,
      sortOrder: json['sort_order'] as int? ?? 0,
      unlocked: json['unlocked'] as bool? ?? false,
      unlockedAt: json['unlocked_at'] == null
          ? null
          : DateTime.tryParse(json['unlocked_at'] as String),
    );
  }

  @override
  List<Object?> get props => [id, unlocked];
}

class AchievementList extends Equatable {
  const AchievementList({
    required this.items,
    required this.unlockedCount,
    required this.total,
  });

  final List<AchievementItem> items;
  final int unlockedCount;
  final int total;

  factory AchievementList.fromJson(Map<String, dynamic> json) {
    return AchievementList(
      items: (json['items'] as List<dynamic>? ?? [])
          .map((e) => AchievementItem.fromJson(e as Map<String, dynamic>))
          .toList(),
      unlockedCount: json['unlocked_count'] as int? ?? 0,
      total: json['total'] as int? ?? 0,
    );
  }

  @override
  List<Object?> get props => [unlockedCount, total, items];
}
