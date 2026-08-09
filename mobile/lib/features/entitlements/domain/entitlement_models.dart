import 'package:equatable/equatable.dart';

class EntitlementsMe extends Equatable {
  const EntitlementsMe({
    required this.isPremium,
    required this.enforceCaps,
    required this.customTopicsUnlimited,
    required this.devToggleAllowed,
    this.uniquePerTopicLimit,
  });

  final bool isPremium;
  final bool enforceCaps;
  final int? uniquePerTopicLimit;
  final bool customTopicsUnlimited;
  final bool devToggleAllowed;

  factory EntitlementsMe.fromJson(Map<String, dynamic> json) {
    return EntitlementsMe(
      isPremium: json['is_premium'] as bool? ?? false,
      enforceCaps: json['enforce_caps'] as bool? ?? false,
      uniquePerTopicLimit: json['unique_per_topic_limit'] as int?,
      customTopicsUnlimited: json['custom_topics_unlimited'] as bool? ?? true,
      devToggleAllowed: json['dev_toggle_allowed'] as bool? ?? false,
    );
  }

  EntitlementsMe copyWith({bool? isPremium}) {
    return EntitlementsMe(
      isPremium: isPremium ?? this.isPremium,
      enforceCaps: enforceCaps,
      uniquePerTopicLimit: uniquePerTopicLimit,
      customTopicsUnlimited: customTopicsUnlimited,
      devToggleAllowed: devToggleAllowed,
    );
  }

  @override
  List<Object?> get props => [
        isPremium,
        enforceCaps,
        uniquePerTopicLimit,
        customTopicsUnlimited,
        devToggleAllowed,
      ];
}
