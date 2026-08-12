import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:speedquiz/core/i18n/l10n.dart';
import 'package:speedquiz/core/i18n/language_providers.dart';
import 'package:speedquiz/core/i18n/widgets/language_picker.dart';
import 'package:speedquiz/core/theme/app_theme.dart';
import 'package:speedquiz/features/topics/data/topics_repository.dart';

/// Devanagari block, used to assert Hindi copy is actually in script rather
/// than transliterated ("kripya" instead of "कृपया").
final _devanagari = RegExp(r'[ऀ-ॿ]');

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() => SharedPreferences.setMockInitialValues({}));

  group('AppLanguage', () {
    test('parses codes, locale tags and casing', () {
      expect(AppLanguage.fromCode('hi'), AppLanguage.hindi);
      expect(AppLanguage.fromCode('HI'), AppLanguage.hindi);
      expect(AppLanguage.fromCode('hi-IN'), AppLanguage.hindi);
      expect(AppLanguage.fromCode('hi_IN'), AppLanguage.hindi);
      expect(AppLanguage.fromCode('en-GB'), AppLanguage.english);
    });

    test('unknown input falls back instead of throwing', () {
      // A corrupt preference or a language a later build dropped must not
      // brick launch.
      for (final raw in [null, '', '   ', 'xx', 'klingon', '-']) {
        expect(AppLanguage.fromCode(raw), AppLanguage.fallback);
      }
    });

    test('device locales resolve in preference order', () {
      expect(
        AppLanguage.fromSystem(const [Locale('mr'), Locale('hi'), Locale('en')]),
        AppLanguage.hindi,
        reason: 'the earliest supported locale wins, not the last',
      );
      expect(AppLanguage.fromSystem(const [Locale('fr')]), AppLanguage.english);
      expect(AppLanguage.fromSystem(const []), AppLanguage.english);
    });

    test('every language names itself in its own script', () {
      expect(AppLanguage.hindi.nativeLabel, matches(_devanagari));
      expect(AppLanguage.hindi.script, SqScript.devanagari);
      expect(AppLanguage.english.script, SqScript.latin);
    });
  });

  group('string tables', () {
    test('Hindi is written in Devanagari, not romanised', () {
      final hi = stringsFor(AppLanguage.hindi);
      // A representative spread across screens rather than a spot check: the
      // failure this guards against is a whole section left in English.
      final samples = <String>[
        hi.homeStartARun,
        hi.setupPickATopic,
        hi.playEndRunTitle,
        hi.resultsRunComplete,
        hi.settingsTitle,
        hi.appLanguageTitle,
        hi.quizLanguageTitle,
        hi.statsTitle,
        hi.achievementsTitle,
        hi.leaderboardTitle,
        hi.customTitle,
        hi.errorGeneric,
        hi.premiumUnlocked,
        hi.subPaymentFailed,
        hi.welcomeNewPlayer,
        hi.landingTagline,
      ];
      for (final sample in samples) {
        expect(
          sample,
          matches(_devanagari),
          reason: '"$sample" reads as untranslated English',
        );
      }
    });

    test('no language leaves a player-visible string empty', () {
      for (final language in AppLanguage.values) {
        final l10n = stringsFor(language);
        final values = <String>[
          l10n.retry,
          l10n.cancel,
          l10n.tabHome,
          l10n.tabExplore,
          l10n.tabRanks,
          l10n.tabProfile,
          l10n.playNext,
          l10n.playSeeResults,
          l10n.resultsShare,
          l10n.setupCreateCustomTopic,
          l10n.settingsSignOut,
          l10n.gotIt,
        ];
        expect(values.every((v) => v.trim().isNotEmpty), isTrue);
      }
    });

    test('interpolations keep their arguments', () {
      for (final language in AppLanguage.values) {
        final l10n = stringsFor(language);
        expect(l10n.questionsCount(7), contains('7'));
        expect(l10n.questionNumber(3), contains('3'));
        // English shouts its buttons; Hindi has no case to shout in. Either
        // way the topic has to survive into the label.
        expect(
          l10n.startWithTopic('Astronomy').toLowerCase(),
          contains('astronomy'),
        );
        expect(l10n.languageBankEmpty('हिन्दी'), contains('हिन्दी'));
        expect(l10n.levelUpTo(12), contains('12'));
        expect(l10n.premiumSavePercent(40), contains('40'));
      }
    });

    test('counts agree with themselves at one and many', () {
      for (final language in AppLanguage.values) {
        final l10n = stringsFor(language);
        expect(l10n.questionsCount(1), isNot(l10n.questionsCount(2)));
        expect(l10n.daysCount(1), isNot(l10n.daysCount(5)));
        expect(l10n.livesLeft(1), isNot(l10n.livesLeft(3)));
      }
    });
  });

  group('theme', () {
    test('Devanagari gets font fallback and looser metrics', () {
      final latin = AppTheme.dark().textTheme.displaySmall!;
      final deva = AppTheme.dark(script: SqScript.devanagari)
          .textTheme
          .displaySmall!;

      // The bundled display face has no Devanagari glyphs at all.
      expect(deva.fontFamilyFallback, contains('Noto Sans Devanagari'));
      // Negative tracking pulls matras into their consonants.
      expect(latin.letterSpacing, lessThan(0));
      expect(deva.letterSpacing, 0);
      // Matras and conjuncts need more room than Latin ascenders.
      expect(deva.height! > latin.height!, isTrue);
    });
  });

  group('language preferences', () {
    test('a stored choice survives, and wins over the account', () async {
      SharedPreferences.setMockInitialValues({'settings_app_language': 'hi'});
      final container = ProviderContainer();
      addTearDown(container.dispose);

      await container.read(appLanguageProvider.notifier).hydrate();
      expect(container.read(appLanguageProvider), AppLanguage.hindi);

      // Signing in must not undo a deliberate choice made on this device.
      await container.read(appLanguageProvider.notifier).adoptFromProfile('en');
      expect(container.read(appLanguageProvider), AppLanguage.hindi);
    });

    test('with no stored choice the device language decides', () async {
      final container = ProviderContainer();
      addTearDown(container.dispose);

      await container
          .read(appLanguageProvider.notifier)
          .hydrate(systemLocales: const [Locale('hi', 'IN')]);
      expect(container.read(appLanguageProvider), AppLanguage.hindi);
    });

    test('an account language applies only when the device has no choice',
        () async {
      final container = ProviderContainer();
      addTearDown(container.dispose);

      await container
          .read(appLanguageProvider.notifier)
          .hydrate(systemLocales: const [Locale('en')]);
      await container.read(appLanguageProvider.notifier).adoptFromProfile('hi');
      expect(container.read(appLanguageProvider), AppLanguage.hindi);
    });

    test('the quiz language starts from the app language, then diverges',
        () async {
      final container = ProviderContainer();
      addTearDown(container.dispose);

      await container
          .read(appLanguageProvider.notifier)
          .hydrate(systemLocales: const [Locale('hi')]);
      await container.read(quizLanguageProvider.notifier).hydrate(
            fallback: container.read(appLanguageProvider),
          );
      expect(container.read(quizLanguageProvider), AppLanguage.hindi);

      // The two axes are independent: quizzing in English while reading the
      // app in Hindi is a supported, common combination.
      await container
          .read(quizLanguageProvider.notifier)
          .setLanguage(AppLanguage.english);
      expect(container.read(quizLanguageProvider), AppLanguage.english);
      expect(container.read(appLanguageProvider), AppLanguage.hindi);
    });

    test('a choice is persisted for the next launch', () async {
      final container = ProviderContainer();
      addTearDown(container.dispose);

      await container.read(appLanguageProvider.notifier).hydrate();
      await container
          .read(appLanguageProvider.notifier)
          .setLanguage(AppLanguage.hindi);

      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString('settings_app_language'), 'hi');
    });
  });

  group('topic availability', () {
    const stocked = TopicItem(
      id: 't1',
      name: 'Astronomy',
      icon: '🌌',
      questionCount: 412,
      questionCounts: {'en': 400, 'hi': 12},
    );
    const englishOnly = TopicItem(
      id: 't2',
      name: 'Esports',
      icon: '🕹',
      questionCount: 90,
      questionCounts: {'en': 90},
    );
    const legacy = TopicItem(
      id: 't3',
      name: 'Legacy server',
      icon: '📗',
      questionCount: 50,
    );

    test('playability is per language, not per topic', () {
      expect(stocked.isPlayableIn('hi'), isTrue);
      expect(englishOnly.isPlayableIn('hi'), isFalse);
      expect(englishOnly.isPlayableIn('en'), isTrue);
    });

    test('a server with no breakdown is treated as playable', () {
      // Older backend: the client must not declare the whole catalog empty.
      expect(legacy.isPlayableIn('hi'), isTrue);
      expect(legacy.countIn('hi'), 50);
    });

    test('a random pick never lands on a language with no bank', () {
      for (var i = 0; i < 50; i++) {
        final picked = pickRandomTopic(
          const [stocked, englishOnly],
          languageCode: 'hi',
        );
        expect(picked?.id, 't1');
      }
    });

    test('no playable topic in a language yields nothing rather than a dead end',
        () {
      expect(pickRandomTopic(const [englishOnly], languageCode: 'hi'), isNull);
    });
  });

  group('language picker', () {
    testWidgets('offers every language by its endonym', (tester) async {
      var picked = AppLanguage.english;

      await tester.pumpWidget(
        MaterialApp(
          localizationsDelegates: const [
            SqLocalizations.delegate,
            GlobalMaterialLocalizations.delegate,
            GlobalWidgetsLocalizations.delegate,
            GlobalCupertinoLocalizations.delegate,
          ],
          supportedLocales: AppLanguage.supportedLocales,
          theme: AppTheme.dark(),
          home: Scaffold(
            body: StatefulBuilder(
              builder: (context, setState) => SqLanguagePicker(
                selected: picked,
                onChanged: (l) => setState(() => picked = l),
              ),
            ),
          ),
        ),
      );
      await tester.pump();

      // The endonym is what makes the control usable to someone stuck in a
      // language they cannot read.
      expect(find.text('हिन्दी'), findsOneWidget);
      expect(find.text('English'), findsWidgets);

      await tester.tap(find.text('हिन्दी'));
      await tester.pump();
      expect(picked, AppLanguage.hindi);
    });
  });

  group('app chrome', () {
    testWidgets('switching locale re-renders the tree in that language',
        (tester) async {
      Widget host(Locale locale) => MaterialApp(
            locale: locale,
            localizationsDelegates: const [
              SqLocalizations.delegate,
              GlobalMaterialLocalizations.delegate,
              GlobalWidgetsLocalizations.delegate,
              GlobalCupertinoLocalizations.delegate,
            ],
            supportedLocales: AppLanguage.supportedLocales,
            home: Builder(
              builder: (context) => Text(context.l10n.settingsTitle),
            ),
          );

      await tester.pumpWidget(host(const Locale('en')));
      await tester.pump();
      expect(find.text('Settings'), findsOneWidget);

      await tester.pumpWidget(host(const Locale('hi')));
      await tester.pump();
      await tester.pump();
      expect(find.text('सेटिंग्स'), findsOneWidget);
      expect(find.text('Settings'), findsNothing);
    });

    testWidgets('an unsupported locale falls back to English chrome',
        (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          locale: const Locale('fr'),
          localizationsDelegates: const [
            SqLocalizations.delegate,
            GlobalMaterialLocalizations.delegate,
            GlobalWidgetsLocalizations.delegate,
            GlobalCupertinoLocalizations.delegate,
          ],
          supportedLocales: AppLanguage.supportedLocales,
          home: Builder(
            builder: (context) => Text(context.l10n.settingsTitle),
          ),
        ),
      );
      await tester.pump();
      expect(find.text('Settings'), findsOneWidget);
    });
  });
}
