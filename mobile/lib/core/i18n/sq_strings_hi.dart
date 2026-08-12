import 'package:speedquiz/core/i18n/app_language.dart';
import 'package:speedquiz/core/i18n/sq_strings.dart';

/// Hindi copy (Devanagari).
///
/// Written to be *read at speed* — this is a game with a countdown, not a
/// document. Where a literal translation would be longer than the English it
/// replaces, the shorter idiomatic phrasing wins: buttons and HUD chips have
/// fixed widths and a three-word label that wraps to two lines is worse than a
/// looser translation that fits.
///
/// Widely-understood English game vocabulary (स्ट्रीक, स्कोर, लेवल, XP) is kept
/// in Devanagari transliteration rather than replaced with formal Hindi
/// equivalents nobody uses while playing.
class SqStringsHi extends SqStrings {
  const SqStringsHi();

  @override
  AppLanguage get language => AppLanguage.hindi;

  // --- Common ------------------------------------------------------------
  @override
  String get appTagline => 'तेज़ सोचें। और तेज़ स्कोर करें।';
  @override
  String get retry => 'फिर से';
  @override
  String get cancel => 'रद्द करें';
  @override
  String get close => 'बंद करें';
  @override
  String get ok => 'ठीक है';
  @override
  String get done => 'हो गया';
  @override
  String get save => 'सहेजें';
  @override
  String get saving => 'सहेजा जा रहा है…';
  @override
  String get loading => 'लोड हो रहा है…';
  @override
  String get somethingWentWrong => 'कुछ गड़बड़ हो गई';
  @override
  String get tryAgain => 'फिर कोशिश करें';
  @override
  String get all => 'सभी';
  @override
  String get search => 'खोजें';
  @override
  String get comingSoon => 'जल्द आ रहा है';
  @override
  String get today => 'आज';
  @override
  String get points => 'अंक';
  @override
  String get level => 'लेवल';
  @override
  String get levelShort => 'लेवल';
  @override
  String get xp => 'XP';
  @override
  String get coins => 'सिक्के';
  @override
  String get streak => 'स्ट्रीक';
  @override
  String get bestStreak => 'सर्वश्रेष्ठ स्ट्रीक';
  @override
  String get accuracy => 'सटीकता';
  @override
  String get score => 'स्कोर';
  @override
  String get rank => 'रैंक';
  @override
  String get you => 'आप';
  @override
  String get player => 'खिलाड़ी';

  @override
  String questionsCount(int count) => count == 1 ? '1 प्रश्न' : '$count प्रश्न';
  @override
  String topicsCount(int count) => count == 1 ? '1 विषय' : '$count विषय';
  @override
  String questionsCountCompact(String formatted) => '$formatted प्रश्न';
  @override
  String daysCount(int count) => count == 1 ? '1 दिन' : '$count दिन';

  // --- Languages ---------------------------------------------------------
  @override
  String get appLanguageTitle => 'ऐप की भाषा';
  @override
  String get appLanguageSubtitle => 'मेन्यू, बटन और संदेश';
  @override
  String get quizLanguageTitle => 'क्विज़ की भाषा';
  @override
  String get quizLanguageSubtitle => 'प्रश्न जिस भाषा में लिखे होंगे';
  @override
  String get quizLanguageHint =>
      'हर रन के लिए अलग चुनें — ऐप की भाषा वैसी ही रहेगी।';
  @override
  String languageChanged(String nativeName) => 'भाषा $nativeName पर सेट की गई';
  @override
  String languageBankEmpty(String nativeName) =>
      '$nativeName में अभी प्रश्न नहीं हैं';
  @override
  String languageBankEmptyHint(String nativeName) =>
      'इस विषय के प्रश्न अभी $nativeName में तैयार नहीं हुए हैं। दूसरा विषय '
      'चुनें, या क्विज़ की भाषा बदलें।';

  // --- Errors ------------------------------------------------------------
  @override
  String get errorGeneric => 'कुछ गड़बड़ हो गई। कृपया फिर कोशिश करें।';
  @override
  String get errorTimeout =>
      'अनुरोध का समय समाप्त हो गया। कनेक्शन जाँचकर फिर कोशिश करें।';
  @override
  String get errorNoConnection =>
      'सर्वर से संपर्क नहीं हो पा रहा। कनेक्शन जाँचकर फिर कोशिश करें।';
  @override
  String get errorSessionExpired =>
      'सत्र समाप्त हो गया। होम पर जाकर ऐप दोबारा खोलें और साइन इन करें।';
  @override
  String get errorTooManyRequests =>
      'बहुत ज़्यादा अनुरोध। थोड़ी देर रुककर फिर कोशिश करें।';
  @override
  String get errorNoQuestion => 'कोई प्रश्न उपलब्ध नहीं है।';
  @override
  String get errorNoNextQuestion => 'अगला प्रश्न नहीं मिला।';
  @override
  String get errorUniqueCap =>
      'इस विषय के लिए मुफ़्त प्रश्नों की सीमा पूरी हो गई है। '
      'खेलते रहने के लिए प्रीमियम लें।';

  // --- Shell -------------------------------------------------------------
  @override
  String get tabHome => 'होम';
  @override
  String get tabExplore => 'खोजें';
  @override
  String get tabRanks => 'रैंक';
  @override
  String get tabProfile => 'प्रोफ़ाइल';
  @override
  String get pressBackAgainToExit => 'बाहर निकलने के लिए फिर से बैक दबाएँ';

  // --- Home --------------------------------------------------------------
  @override
  String get greetingNight => 'रात के जागरण में';
  @override
  String get greetingMorning => 'सुप्रभात';
  @override
  String get greetingAfternoon => 'नमस्कार';
  @override
  String get greetingEvening => 'शुभ संध्या';
  @override
  // No case in Devanagari, so the name is left exactly as the player typed it.
  String greetingWithName(String greeting, String name) => '$greeting, $name';
  @override
  String get homeHeadline => 'विषय चुनें।\nरैंक चढ़ें।';
  @override
  String get homeReady => 'तैयार';
  @override
  String get homeServerScored => 'सर्वर-स्कोर्ड';
  @override
  String get homeStartARun => 'रन शुरू करें';
  @override
  String get homeStartARunBody =>
      'समयबद्ध प्रश्न, स्पीड बोनस और स्ट्रीक मल्टीप्लायर। '
      'कैज़ुअल, स्पीडरन या सर्वाइवल।';
  @override
  String get homePlay => 'खेलें';
  @override
  String get homeSurprise => 'कोई भी';
  @override
  String get homeOpenProfile => 'अपनी प्रोफ़ाइल खोलें';
  @override
  String get homeJumpBackIn => 'वापस शुरू करें';
  @override
  String get homeJumpBackInSubtitle => 'सबसे ज़्यादा प्रश्नों वाले विषय';
  @override
  String get homeTopicsUnavailable => 'विषय उपलब्ध नहीं';
  @override
  String get homeCouldNotLoadTopics => 'विषय लोड नहीं हो सके।';
  @override
  String get homeBankFilling =>
      'प्रश्नों का भंडार अभी तैयार हो रहा है। थोड़ी देर बाद देखें।';
  @override
  String get homeCustomTopic => 'अपना विषय';
  @override
  String get homeCustomTopicBody =>
      'कुछ भी लिखें और AI उस पर क्विज़ बना देगा';
  @override
  String get homeNoTopicReady => 'अभी किसी विषय के प्रश्न तैयार नहीं हैं।';

  // --- Daily challenge ---------------------------------------------------
  @override
  String get dailyChallenge => 'डेली चैलेंज';
  @override
  String get dailyTapToRetry => 'फिर कोशिश करने के लिए टैप करें';
  @override
  String get dailyUnavailable => 'डेली चैलेंज अभी उपलब्ध नहीं है।';
  @override
  String get dailyTodayDone => 'आज का हो गया';
  @override
  String dailyTodayDoneWithScore(String score) =>
      'आज के चैलेंज में आपने $score अंक बनाए। नया सेट कल खुलेगा।';
  @override
  String get dailyTodayDoneGeneric =>
      'आप आज का चैलेंज पूरा कर चुके हैं। नया सेट कल खुलेगा।';
  @override
  String get dailyNice => 'बढ़िया';
  @override
  String dailyCleared(String score) => 'पूरा · $score अंक';
  @override
  String get dailyClearedNoScore => 'पूरा · कल फिर आएँ';
  @override
  String dailyResume(String topic) => 'जारी रखें · $topic';
  @override
  String dailySubtitle(String topic, int questions) =>
      '$topic · ${questionsCount(questions)}';

  // --- Quiz setup --------------------------------------------------------
  @override
  String get setupTitle => 'नया रन';
  @override
  String get setupClose => 'बंद करें';
  @override
  String get setupModeCasual => 'कैज़ुअल';
  @override
  String get setupModeCasualHook => 'अनंत। स्ट्रीक के लिए खेलें।';
  @override
  String get setupModeSpeedrun => 'स्पीडरन';
  @override
  String get setupModeSpeedrunHook => 'तेज़ जवाब दें, और समय पाएँ।';
  @override
  String get setupModeSurvival => 'सर्वाइवल';
  @override
  String get setupModeSurvivalHook => 'तीन जीवन। रफ़्तार बढ़ती जाएगी।';
  @override
  String get difficultyEasy => 'आसान';
  @override
  String get difficultyMedium => 'मध्यम';
  @override
  String get difficultyHard => 'कठिन';
  @override
  String get difficultyExpert => 'विशेषज्ञ';
  @override
  String get difficultyAdaptive => 'अनुकूल';
  @override
  String get setupSurpriseMe => 'कोई भी चुनें';
  @override
  String get setupCustomTopic => 'अपना विषय';
  @override
  String setupSearchTopics(int count) => '$count विषयों में खोजें';
  @override
  String get setupPickATopic => 'विषय चुनें';
  @override
  String startWithTopic(String topic) => 'शुरू करें · $topic';
  @override
  String get setupPickTopicToStart => 'रन शुरू करने के लिए विषय चुनें।';
  @override
  String get setupNoTopicReady => 'अभी किसी विषय के प्रश्न तैयार नहीं हैं।';
  @override
  String setupRandomPicked(String topic) => '🎲 चलिए $topic सही।';
  @override
  String setupTopicStillWriting(String topic) =>
      '$topic के प्रश्न अभी लिखे जा रहे हैं। थोड़ी देर बाद देखें।';
  @override
  String get setupBankFilling => 'भंडार अभी भर रहा है';
  @override
  String get setupBankFillingBody =>
      'अभी किसी विषय के प्रश्न तैयार नहीं हैं। अपना विषय बनाकर देखें।';
  @override
  String get setupCreateCustomTopic => 'अपना विषय बनाएँ';
  @override
  String setupNoTopicMatches(String query) => '"$query" से कोई विषय नहीं मिला';
  @override
  String get setupNoTopicMatchesBody =>
      'कोई दूसरा शब्द आज़माएँ, या जो चाहिए वही बनवा लें।';
  @override
  String get setupCouldNotLoadTopics => 'विषय लोड नहीं हो सके';
  @override
  String get setupComingSoonBody => 'इनके प्रश्न अभी लिखे जा रहे हैं।';
  @override
  String get setupUnavailableInLanguage => 'इस भाषा में अभी नहीं';

  // --- Quiz play ---------------------------------------------------------
  @override
  String get playPreparing => 'आपका चैलेंज तैयार हो रहा है…';
  @override
  String get playPreparingHint =>
      'प्रश्न पहले से तैयार भंडार से आते हैं, तुरंत नहीं बनाए जाते।';
  @override
  String get playScoringRun => 'आपका रन जोड़ा जा रहा है…';
  @override
  String get playGo => 'शुरू';
  @override
  String get playSpeedrunTitle => 'स्पीडरन';
  @override
  String get playRuleRight => 'सही जवाब समय लौटाते हैं — जितना तेज़, उतना ज़्यादा';
  @override
  String get playRuleWrong => 'गलत जवाब पर 3 सेकंड कटेंगे';
  @override
  String get playRuleTighter => 'कुछ प्रश्नों के बाद समय और कम होता जाएगा';
  @override
  String get playEndRunTitle => 'यह रन खत्म करें?';
  @override
  String get playEndRunBody =>
      'अब तक का स्कोर सुरक्षित है और रन अभी जोड़ दिया जाएगा। '
      'इसके बाद इसे दोबारा शुरू नहीं किया जा सकता।';
  @override
  String get playEndRunConfirm => 'रन खत्म करें';
  @override
  String get playKeepPlaying => 'खेलते रहें';
  @override
  String get playEndRun => 'रन खत्म करें';
  @override
  String get playRunInterrupted => 'रन बीच में रुक गया';
  @override
  String get playFreeLimitReached => 'मुफ़्त सीमा पूरी हुई';
  @override
  String get playGoPremium => 'प्रीमियम लें';
  @override
  String get playPaywallReason =>
      'इस विषय के मुफ़्त प्रश्नों की सीमा पूरी हो चुकी है।';
  @override
  String get playBackHome => 'होम पर जाएँ';
  @override
  String get playLanguageUnavailableTitle => 'इस भाषा में अभी नहीं';
  @override
  String questionNumber(int number) => 'प्र$number';
  @override
  String get playRunClock => 'रन घड़ी';
  @override
  String overdriveMultiplier(int streak) => 'ओवरड्राइव ×$streak';
  @override
  String get playCorrect => 'सही';
  @override
  String get playNotQuite => 'गलत';
  @override
  String get playWhy => 'क्यों';
  @override
  String get playNext => 'अगला';
  @override
  String get playSeeResults => 'नतीजे देखें';
  @override
  String get playTeachMe => 'समझाएँ';
  @override
  String get playTeachMeThis => 'यह समझाएँ';
  @override
  String get playTeaching => 'समझाया जा रहा है…';
  @override
  String get playTeachError => 'अभी विस्तृत व्याख्या नहीं मिल पाई।';
  @override
  String get teachWhyCorrect => 'यह उत्तर सही क्यों है';
  @override
  String get teachWhyWrong => 'आपका उत्तर क्यों चूका';
  @override
  String get teachKeyConcept => 'मुख्य अवधारणा';
  @override
  String get teachRemember => 'यह याद रखें';
  @override
  String livesLeft(int lives) => lives == 1 ? '1 जीवन बचा' : '$lives जीवन बचे';

  // --- Results -----------------------------------------------------------
  @override
  String get resultsNewPersonalBest => 'नया सर्वश्रेष्ठ स्कोर';
  @override
  String get resultsRunComplete => 'रन पूरा हुआ';
  @override
  String personalBestValue(String score) => 'सर्वश्रेष्ठ $score';
  @override
  String get resultsAvgAnswer => 'औसत समय';
  @override
  String get resultsSurvived => 'टिके रहे';
  @override
  String get resultsQuestions => 'प्रश्न';
  @override
  String get resultsUnlocked => 'अनलॉक हुआ';
  @override
  String get resultsOneAchievement => 'एक नई उपलब्धि';
  @override
  String achievementsUnlockedCount(int count) => '$count नई उपलब्धियाँ';
  @override
  String get resultsPlayAgain => 'फिर खेलें';
  @override
  String get resultsNewRun => 'नया रन';
  @override
  String get resultsShare => 'साझा करें';
  @override
  String get resultsHome => 'होम';
  @override
  String get resultsShareFailed => 'शेयर विकल्प नहीं खुल सका।';
  @override
  String levelUpTo(int level) => 'लेवल अप — आप लेवल $level पर पहुँचे';
  @override
  String levelBadge(int level) => 'लेवल $level';
  @override
  String get resultsLoading => 'आपका नतीजा लोड हो रहा है…';
  @override
  String get resultsUnavailable => 'नतीजा उपलब्ध नहीं';
  @override
  String get resultsCouldNotLoad => 'यह रन लोड नहीं हो सका।';
  @override
  String get resultsGoHome => 'होम पर जाएँ';
  @override
  String get resultsOpenSharedCard => 'इसके बजाय साझा कार्ड खोलें';

  // --- Explore -----------------------------------------------------------
  @override
  String get exploreTitle => 'खोजें';
  @override
  String get exploreSearchHint => 'विषय खोजें…';
  @override
  String get exploreNothingHere => 'यहाँ अभी कुछ नहीं है';
  @override
  String get exploreCategoryEmpty => 'इस श्रेणी में अभी कोई विषय नहीं है।';
  @override
  String exploreNoMatch(String query) =>
      '“$query” से कोई विषय नहीं मिला। इसे खुद बनवा लें।';
  @override
  String get exploreTrendingNow => 'अभी चर्चा में';
  @override
  String get exploreBankFilling => 'भंडार भर रहा है';
  @override
  String get exploreRandom => 'कोई भी';
  @override
  String get explorePlayRandom => 'कोई भी विषय खेलें';
  @override
  String get exploreCouldNotLoad => 'विषय लोड नहीं हो सके';
  @override
  String get exploreCheckConnection => 'कनेक्शन जाँचकर फिर कोशिश करें।';
  @override
  String exploreReadyToPlay(int count) =>
      count == 1 ? '1 विषय खेलने के लिए तैयार' : '$count विषय खेलने के लिए तैयार';

  // --- Leaderboard -------------------------------------------------------
  @override
  String get leaderboardTitle => 'लीडरबोर्ड';
  @override
  String get leaderboardSubtitle =>
      'साप्ताहिक रैंक और आज के डेली बोर्ड पर चढ़ें';
  @override
  String get leaderboardWeekly => 'साप्ताहिक';
  @override
  String get leaderboardDaily => 'डेली';
  @override
  String get leaderboardCouldNotLoad => 'रैंक लोड नहीं हो सकीं';
  @override
  String get leaderboardUnreachable => 'बोर्ड अभी उपलब्ध नहीं है।';
  @override
  String get leaderboardEmpty => 'अभी कोई रैंक नहीं';
  @override
  String get leaderboardEmptyDaily =>
      'आज का चैलेंज पूरा करें और बोर्ड पर पहले नाम लिखवाएँ।';
  @override
  String get leaderboardEmptyWeekly =>
      'इस हफ़्ते एक रन खेलें और आपका नाम यहाँ आ जाएगा।';
  @override
  String yourBestIn(String period) => 'आपका सर्वश्रेष्ठ · $period';

  // --- Profile -----------------------------------------------------------
  @override
  String get profileTitle => 'प्रोफ़ाइल';
  @override
  String get profileDetails => 'प्रोफ़ाइल विवरण';
  @override
  String get profileDetailsSubtitle =>
      'नाम, अवतार और बोर्ड पर आपकी पहचान';
  @override
  String get profileAchievements => 'उपलब्धियाँ';
  @override
  String get profileAchievementsSubtitle => 'अब तक जो कुछ आपने अनलॉक किया';
  @override
  String achievementsProgress(int unlocked, int total) =>
      '$total में से $unlocked अनलॉक';
  @override
  String get profileStatistics => 'आँकड़े';
  @override
  String get profileStatisticsSubtitle => 'सटीकता, रफ़्तार और विषयों पर पकड़';
  @override
  String get profilePremium => 'प्रीमियम';
  @override
  String get profileGoPremium => 'प्रीमियम लें';
  @override
  String get profilePremiumThanks => 'SpeedQuiz का साथ देने के लिए धन्यवाद';
  @override
  String get profilePremiumPitch => 'असीमित प्रश्न और अपने विषय';
  @override
  String get profileSettingsSubtitle => 'दिखावट, भाषा, ध्वनि, खाता';
  @override
  String get profileGuest => 'गेस्ट';
  @override
  String get profileFree => 'फ्री';
  @override
  String get profilePremiumBadge => 'प्रीमियम';
  @override
  String get profileGuestBadge => 'गेस्ट';
  @override
  String get profileBack => 'वापस';

  // --- Profile edit ------------------------------------------------------
  @override
  String get editTitle => 'प्रोफ़ाइल विवरण';
  @override
  String get editSubtitle => 'लीडरबोर्ड पर आप कैसे दिखेंगे';
  @override
  String get editDisplayName => 'प्रदर्शित नाम';
  @override
  String get editDisplayNameSubtitle =>
      'खाली छोड़ें तो आपका हैंडल इस्तेमाल होगा';
  @override
  String get editDisplayNameHint => 'जैसे: क्विज़ गोबलिन';
  @override
  String get editAvatar => 'अवतार';
  @override
  String get editAvatarSubtitle => 'अपने मन का रूप चुनें';
  @override
  String get editPremiumAvatarReason => 'ये अवतार प्रीमियम का हिस्सा हैं।';
  @override
  String get editSaveChanges => 'बदलाव सहेजें';
  @override
  String get editSaved => 'प्रोफ़ाइल अपडेट हो गई।';
  @override
  String get editSaveFailed => 'प्रोफ़ाइल सहेजी नहीं जा सकी। फिर कोशिश करें।';
  @override
  String editNameTooShort(int minimum) =>
      'नाम में कम से कम $minimum अक्षर होने चाहिए।';

  // --- Account card ------------------------------------------------------
  @override
  String get accountTitle => 'खाता';
  @override
  String get accountGoogle => 'GOOGLE';
  @override
  String get accountGuest => 'गेस्ट';
  @override
  String get accountUsername => 'उपयोगकर्ता नाम';
  @override
  String get accountEmail => 'ईमेल';
  @override
  String get accountNotLinked => 'जुड़ा नहीं है';
  @override
  String get accountPlayingSince => 'कब से खेल रहे हैं';
  @override
  String get accountOnThisDevice => 'इस डिवाइस पर';
  @override
  String get accountPlayerId => 'प्लेयर ID';
  @override
  String get accountCopyPlayerId => 'प्लेयर ID कॉपी करें';
  @override
  String get accountPlayerIdCopied => 'प्लेयर ID कॉपी हो गई।';
  @override
  String get accountGuestHint =>
      'गेस्ट प्रगति इसी डिवाइस पर रहती है। अगले फ़ोन पर ले जाने के लिए '
      'सेटिंग्स में Google खाता जोड़ें।';

  // --- Stats -------------------------------------------------------------
  @override
  String get statsTitle => 'आँकड़े';
  @override
  String get statsSubtitle => 'अब तक आपका पूरा खेल';
  @override
  String get statsUnavailable => 'आँकड़े उपलब्ध नहीं';
  @override
  String get statsCouldNotLoad => 'आपके आँकड़े लोड नहीं हो सके।';
  @override
  String get statsNoRuns => 'अभी कोई रन नहीं';
  @override
  String get statsNoRunsBody => 'पहली क्विज़ खेलें और आपके आँकड़े यहाँ दिखेंगे।';
  @override
  String get statsLifetimeAccuracy => 'कुल सटीकता';
  @override
  String get statsRunsPlayed => 'खेले गए रन';
  @override
  String get statsBestScore => 'सर्वश्रेष्ठ स्कोर';
  @override
  String get statsQuestions => 'प्रश्न';
  @override
  String get statsMissed => 'चूके';
  @override
  String get statsTopicMastery => 'विषयों पर पकड़';
  @override
  String get statsTopicMasterySubtitle => 'आप किनमें सबसे मज़बूत हैं';

  // --- Achievements ------------------------------------------------------
  @override
  String get achievementsTitle => 'उपलब्धियाँ';
  @override
  String get achievementsSubtitle => 'हर वह पड़ाव जिसे पाना बनता है';
  @override
  String get achievementsUnavailable => 'उपलब्धियाँ उपलब्ध नहीं';
  @override
  String get achievementsCouldNotLoad => 'आपकी उपलब्धियाँ लोड नहीं हो सकीं।';
  @override
  String get achievementsNoneYet => 'अभी कुछ अनलॉक नहीं हुआ';
  @override
  String get achievementsAllUnlocked => 'सब अनलॉक';
  @override
  String get achievementsNoneYetBody =>
      'एक रन पूरा करें और पहली उपलब्धि पाएँ।';
  @override
  String get achievementsAllUnlockedBody =>
      'आपने हर उपलब्धि हासिल कर ली है। कमाल!';
  @override
  String get achievementsCompletionist => 'सब पूरा। अब कुछ बाकी नहीं।';
  @override
  String get achievementsFilterAll => 'सभी';
  @override
  String get achievementsFilterUnlocked => 'अनलॉक';
  @override
  String get achievementsFilterLocked => 'लॉक';

  // --- Custom topic ------------------------------------------------------
  @override
  String get customTitle => 'अपना विषय';
  @override
  String get customHeadline => 'आप किस पर सवाल\nचाहते हैं?';
  @override
  String get customBody =>
      'कुछ भी लिखें — गेम, विज्ञान, कहानियाँ, शौक। '
      'AI सवाल लिखेगा और जाँचेगा भी।';
  @override
  String get customPromptHint =>
      'जैसे: मुझसे मुगल काल पर कठिन सवाल पूछो';
  @override
  // Suggestions are examples, not translations — these are chosen for what a
  // Hindi-reading player is likely to want quizzed, not a literal rendering of
  // the English list.
  List<String> get customSuggestions => const [
        'भारतीय संविधान के मूल अधिकार',
        'क्रिकेट विश्व कप का इतिहास',
        'मुगल काल, पर कठिन सवाल',
        'भारतीय रेलवे और भूगोल',
        'हिंदी सिनेमा के क्लासिक',
      ];
  @override
  String get customDifficulty => 'कठिनाई';
  @override
  String get customMode => 'मोड';
  @override
  String get customStyle => 'अंदाज़';
  @override
  String get customStyleSubtitle => 'वैकल्पिक — सवालों का मिज़ाज कैसा हो?';
  @override
  String get customStyleHint => 'जैसे: कहानी वाला, ट्रिविया, व्यावहारिक';
  @override
  String get customCreate => 'क्विज़ बनाएँ';
  @override
  String get customNeedPrompt => 'बताएँ कि आप किस पर सवाल चाहते हैं।';
  @override
  String get customNotEnoughQuestions =>
      'इस पर पर्याप्त अच्छे सवाल नहीं बन पाए। '
      'कोई स्पष्ट या थोड़ा बड़ा विषय आज़माएँ।';
  @override
  String get customFailed => 'आपका चैलेंज तैयार नहीं हो सका। फिर कोशिश करें।';
  @override
  String get customBuilding => 'आपकी क्विज़ बन रही है';
  @override
  String get customBuildingHint =>
      'यह असली मॉडल चलाता है, इसलिए कुछ सेकंड लगते हैं। '
      'इसके बाद सब कुछ तुरंत मिलेगा।';
  @override
  String get customStageUnderstanding => 'आपका विषय समझा जा रहा है';
  @override
  String get customStageWriting => 'सवाल लिखे जा रहे हैं';
  @override
  String get customStageChecking => 'हर उत्तर की जाँच हो रही है';
  @override
  String get customStageShuffling => 'अच्छे सवाल चुने जा रहे हैं';
  @override
  String customLanguageNote(String nativeName) =>
      'सवाल $nativeName में लिखे जाएँगे';

  // --- Landing / onboarding ----------------------------------------------
  @override
  String get landingTagline => 'अनगिनत AI क्विज़। असली गेम वाला मज़ा।';
  @override
  String get landingWarmingUp => 'तैयार हो रहा है…';
  @override
  String get landingFeatureModesTitle => 'खेलने के तीन तरीके';
  @override
  String get landingFeatureModesBody =>
      'अनंत कैज़ुअल, स्पीडरन की घड़ी, तीन जीवन वाला सर्वाइवल';
  @override
  String get landingFeatureDailyTitle => 'डेली चैलेंज और रैंक';
  @override
  String get landingFeatureDailyBody =>
      'हर दिन एक नया सेट, साप्ताहिक और डेली बोर्ड';
  @override
  String get landingFeatureExplainTitle => 'हर जवाब की व्याख्या';
  @override
  String get landingFeatureExplainBody =>
      'गलत हुआ तो ऐप बताएगा कि क्यों';
  @override
  String get landingPlayAsGuest => 'गेस्ट के रूप में खेलें';
  @override
  String get landingNewGuestRun => 'नया गेस्ट रन शुरू करें';
  @override
  String get landingGuestNote =>
      'गेस्ट प्रगति इसी डिवाइस पर सुरक्षित रहती है और बाद में खाते से जोड़ी '
      'जा सकती है।';
  @override
  String get landingGoogleUnavailable => 'Google साइन-इन उपलब्ध नहीं';
  @override
  String get landingGoogleUnavailableBody =>
      'यह बिल्ड Google क्लाइंट ID के बिना बना है। गेस्ट के रूप में खेलें — '
      'खाता बाद में जोड़ा जा सकता है।';
  @override
  String get landingGoogleFailed => 'Google साइन-इन विफल रहा।';
  @override
  String get landingContinueWithGoogle => 'Google से जारी रखें';

  // --- Welcome sheet -----------------------------------------------------
  @override
  String get welcomeNewPlayer => 'SpeedQuiz में आपका स्वागत है';
  @override
  String welcomeSignedIn(String name) => 'स्वागत है, $name';
  @override
  String welcomeBack(String name) => 'फिर से स्वागत है, $name';
  @override
  String get welcomeWaitingToday => 'आज आपका इंतज़ार कर रहा है';
  @override
  String get welcomeStartPlaying => 'खेलना शुरू करें';
  @override
  String get welcomeJumpBackIn => 'वापस शुरू करें';
  @override
  String get welcomeLookAround => 'पहले देख लेते हैं';
  @override
  String get welcomeGuestBody =>
      'आप गेस्ट के रूप में खेल रहे हैं — प्रगति इसी डिवाइस पर सुरक्षित है और '
      'बाद में खाते से जोड़ी जा सकती है।';
  @override
  String get welcomeAccountBody =>
      'आपका खाता तैयार है। जहाँ भी साइन इन करेंगे, प्रगति साथ चलेगी।';
  @override
  String welcomeGuestHandle(String username) => 'गेस्ट खाता · @$username';
  @override
  String get welcomeCuePickTopic => 'विषय चुनें और रन शुरू करें';
  @override
  String get welcomeCueDailyDone => 'डेली पूरा — अब खुलकर खेलें';
  @override
  String welcomeCueResumeDaily(String topic) => 'डेली जारी रखें · $topic';
  @override
  String welcomeCueDaily(String topic) => 'डेली चैलेंज · $topic';

  // --- Shared result -----------------------------------------------------
  @override
  String get sharedRunBadge => 'साझा रन';
  @override
  String get sharedCardUnavailable => 'कार्ड उपलब्ध नहीं';
  @override
  String get sharedCardExpired => 'यह साझा नतीजा हटा दिया गया है या पुराना है।';
  @override
  String get sharedOpenSpeedQuiz => 'SPEEDQUIZ खोलें';
  @override
  String get sharedBeatThat => 'क्या आप इसे हरा सकते हैं?';
  @override
  String get sharedBeatThisScore => 'इस स्कोर को हराएँ';

  // --- Premium -----------------------------------------------------------
  @override
  String get premiumUnlockEverything => 'गेम का साथ दें, सब कुछ अनलॉक करें';
  @override
  String get premiumYourePremium => 'आप प्रीमियम हैं';
  @override
  String get premiumBenefitQuestionsTitle => 'असीमित प्रश्न';
  @override
  String get premiumBenefitQuestionsBody =>
      'किसी भी विषय में प्रश्नों की कोई सीमा नहीं';
  @override
  String get premiumBenefitCustomTitle => 'असीमित अपने विषय';
  @override
  String get premiumBenefitCustomBody =>
      'किसी भी चीज़ पर, जितनी बार चाहें, क्विज़ बनवाएँ';
  @override
  String get premiumBenefitCosmeticsTitle => 'प्रीमियम अवतार और सजावट';
  @override
  String get premiumBenefitCosmeticsBody =>
      'छह ख़ास अवतार, सुनहरी प्रोफ़ाइल रिंग और लीडरबोर्ड बैज';
  @override
  String get premiumUnlocked => 'प्रीमियम चालू हो गया। आनंद लें।';
  @override
  String get premiumUnlockedTest => 'प्रीमियम चालू (टेस्ट खरीद)';
  @override
  String get premiumVerifyReturnedFree =>
      'जाँच में फ्री मिला — सर्वर देखें';
  @override
  String get premiumEnabledStub => 'प्रीमियम चालू (स्टब खरीद)';
  @override
  String get premiumEnabledDev => 'प्रीमियम चालू (डेव)';
  @override
  String get premiumNotAvailableHere =>
      'इस डिवाइस पर अभी सदस्यता उपलब्ध नहीं है — कोई शुल्क नहीं लिया गया।';
  @override
  String get premiumRestored => 'खरीदारी बहाल हो गई।';
  @override
  String get premiumNoSubscription =>
      'इस स्टोर खाते पर कोई सक्रिय सदस्यता नहीं है।';
  @override
  String get premiumRestoredStub => 'प्रीमियम बहाल (स्टब)';
  @override
  String get premiumNothingToRestore => 'बहाल करने के लिए कुछ नहीं है।';
  @override
  String get premiumRestoreUnavailable =>
      'इस डिवाइस पर बहाली उपलब्ध नहीं है।';
  @override
  String get premiumRestorePurchases => 'खरीदारी बहाल करें';
  @override
  String get premiumSubscribe => 'सदस्यता लें';
  @override
  String premiumSubscribeWithPrice(String price) => 'सदस्यता लें · $price';
  @override
  String premiumSwitchTo(String plan) => '$plan पर जाएँ';
  @override
  String get premiumTestPurchase => 'टेस्ट खरीद';
  @override
  String premiumTestPurchaseWith(String plan) => 'टेस्ट खरीद · $plan';
  @override
  String get premiumEnableDev => 'प्रीमियम चालू करें (डेव)';
  @override
  String get premiumUnavailable => 'उपलब्ध नहीं';
  @override
  String get premiumTestModeNote =>
      'टेस्ट मोड — खरीदारी सर्वर पर नकली है और कोई शुल्क नहीं लगता।';
  @override
  String get premiumSignInNote =>
      'Google से साइन इन करें ताकि आपकी सदस्यता अगले डिवाइस पर भी साथ चले।';
  @override
  String get premiumCurrent => 'मौजूदा';
  @override
  String get premiumNotOnThisDevice => 'इस डिवाइस पर उपलब्ध नहीं';
  @override
  String premiumSavePercent(int percent) => '$percent% बचाएँ';
  @override
  String get premiumRenewsAutomatically =>
      'आपकी सदस्यता अपने आप नवीनीकृत होती है';
  @override
  String premiumRenewsAt(String price, String period) =>
      'हर $period $price पर अपने आप नवीनीकरण';
  @override
  String premiumCancelAnytime(String store) =>
      'अपने $store खाते से कभी भी रद्द करें — अवधि पूरी होने तक प्रीमियम '
      'आपके पास रहेगा।';

  // --- Subscription status -----------------------------------------------
  @override
  String get subPaymentFailed => 'भुगतान विफल';
  @override
  String get subOnHold => 'सदस्यता रोकी गई';
  @override
  String get subPaused => 'सदस्यता ठहरी हुई';
  @override
  String get subPaymentProcessing => 'भुगतान संसाधित हो रहा है';
  @override
  String get subCancelled => 'रद्द';
  @override
  String get subEnded => 'सदस्यता समाप्त';
  @override
  String get subRefunded => 'सदस्यता वापस की गई';
  @override
  String subActivePlan(String plan) => '$plan · सक्रिय';
  @override
  String get subFixPaymentMethod => 'भुगतान विधि ठीक करें';
  @override
  String get subManageSubscription => 'सदस्यता प्रबंधित करें';
  @override
  String get subCouldNotOpenStore => 'स्टोर सदस्यता नहीं खुल सकी।';
  @override
  String get subUpdatePaymentNow =>
      'प्रीमियम बनाए रखने के लिए भुगतान विधि अपडेट करें।';
  @override
  String subUpdatePaymentBy(String date) =>
      'प्रीमियम बनाए रखने के लिए $date तक भुगतान विधि अपडेट करें।';
  @override
  String get subOnHoldBody =>
      'पिछला भुगतान नहीं हो पाया, इसलिए प्रीमियम रुका हुआ है। '
      'भुगतान विधि अपडेट करें और वहीं से आगे बढ़ें।';
  @override
  String get subPausedBody => 'ठहराव खत्म होते ही प्रीमियम अपने आप शुरू होगा।';
  @override
  String subProcessingBody(String date) =>
      'आपका बैंक अभी भुगतान की पुष्टि कर रहा है। प्रीमियम $date तक चालू होगा।';
  @override
  String get subCancelledBodyNoDate =>
      'बिलिंग अवधि खत्म होने तक प्रीमियम सक्रिय रहेगा।';
  @override
  String subCancelledBody(String date) =>
      'प्रीमियम $date तक सक्रिय रहेगा। दोबारा शुल्क नहीं लगेगा।';
  @override
  String get subEndedBody =>
      'प्रीमियम दोबारा पाने के लिए कभी भी सदस्यता लें।';
  @override
  String get subRefundedBody =>
      'यह खरीद वापस कर दी गई, इसलिए प्रीमियम समाप्त हो गया।';
  @override
  String get subThanks => 'SpeedQuiz का साथ देने के लिए धन्यवाद।';
  @override
  String subIntroPriceUntil(String date) =>
      'आपकी परिचयात्मक कीमत $date तक लागू है।';
  @override
  String subRenewsOn(String date) => '$date को नवीनीकरण होगा।';

  // --- Misc widgets ------------------------------------------------------
  @override
  String get hotBadge => 'हॉट';
  @override
  String get confirm => 'पुष्टि करें';
  @override
  String get gotIt => 'समझ गया';
  @override
  String get periodMonth => 'महीने';
  @override
  String get periodYear => 'साल';
  @override
  String get streakActive => 'स्ट्रीक चालू';
  @override
  String get streakInactive => 'स्ट्रीक बंद';

  // --- Speed tiers -------------------------------------------------------
  //
  // Short, punchy, and in script: these flash for a few hundred milliseconds
  // over the answer, so length matters more than literal accuracy.
  @override
  String get speedTierBlitz => 'बिजली';
  @override
  String get speedTierFast => 'तेज़';
  @override
  String get speedTierClean => 'सटीक';
  @override
  String get speedTierClutch => 'ऐन वक़्त';

  // --- Billing progress --------------------------------------------------
  @override
  String get billingOpeningStore => 'स्टोर खुल रहा है…';
  @override
  String get billingRestoring => 'खरीदारी बहाल हो रही है…';
  @override
  String get billingVerifying => 'जाँच हो रही है…';
  @override
  String get billingCouldNotStart => 'खरीद शुरू नहीं हो सकी';
  @override
  String get billingPurchaseFailed => 'खरीद विफल';
  @override
  String get billingWaitingForPayment =>
      'आपके भुगतान की पुष्टि का इंतज़ार है। पुष्टि होते ही प्रीमियम अपने आप '
      'चालू हो जाएगा।';
  @override
  String get billingStoreUnavailable => 'इस डिवाइस पर स्टोर उपलब्ध नहीं';
  @override
  String get billingNoPlans => 'कोई प्लान कॉन्फ़िगर नहीं है';

  // --- Settings ----------------------------------------------------------
  @override
  String get settingsTitle => 'सेटिंग्स';
  @override
  String get settingsAppearance => 'दिखावट';
  @override
  String get settingsAppearanceSubtitle => 'पूरे ऐप में तुरंत लागू होता है';
  @override
  String get settingsThemeDark => 'डार्क';
  @override
  String get settingsThemeLight => 'लाइट';
  @override
  String get settingsThemeSystem => 'सिस्टम';
  @override
  String get settingsLanguageSection => 'भाषा';
  @override
  String get settingsLanguageSubtitle => 'ऐप और क्विज़ की भाषा अलग हो सकती है';
  @override
  String get settingsFeel => 'एहसास';
  @override
  String get settingsFeelSubtitle => 'ध्वनि और कंपन';
  @override
  String get settingsSound => 'ध्वनि प्रभाव';
  @override
  String get settingsSoundSubtitle => 'जवाब, स्ट्रीक और नतीजों की आवाज़ें';
  @override
  String get settingsMusic => 'बैकग्राउंड संगीत';
  @override
  String get settingsMusicSubtitle => 'खेलते समय हल्का संगीत';
  @override
  String get settingsHaptics => 'हैप्टिक्स';
  @override
  String get settingsHapticsSubtitle => 'हर टैप और जवाब पर हल्का कंपन';
  @override
  String get settingsAccount => 'खाता';
  @override
  String get settingsSaveProgress => 'अपनी प्रगति सहेजें';
  @override
  String get settingsSaveProgressBody =>
      'गेस्ट प्रगति सिर्फ़ इसी डिवाइस पर रहती है। Google खाता जोड़ें और आपका '
      'लेवल, स्ट्रीक और रैंक हर जगह आपके साथ चलेंगे।';
  @override
  String get settingsLinkGoogle => 'Google खाता जोड़ें';
  @override
  String get settingsGoogleUnavailable => 'Google साइन-इन उपलब्ध नहीं';
  @override
  String get settingsGoogleUnavailableBody =>
      'यह बिल्ड Google क्लाइंट ID के बिना बना है, इसलिए यहाँ खाता नहीं जोड़ा '
      'जा सकता।';
  @override
  String get settingsAccountLinked => 'खाता जुड़ गया — आपकी प्रगति सुरक्षित है।';
  @override
  String get settingsAccountLinkFailed => 'खाता नहीं जोड़ा जा सका।';
  @override
  String get settingsSignedInWithGoogle => 'Google से साइन इन';
  @override
  String get settingsSignOut => 'साइन आउट';
  @override
  String get settingsSigningOut => 'साइन आउट हो रहा है…';
  @override
  String get settingsSignOutTitle => 'साइन आउट करें?';
  @override
  String get settingsSignOutGuestBody =>
      'यह गेस्ट सत्र है। साइन आउट करने पर इस डिवाइस का लेवल, XP और स्ट्रीक '
      'वापस नहीं आएगा — पहले Google खाता जोड़ लें।';
  @override
  String get settingsSignOutBody =>
      'आप कभी भी Google से दोबारा साइन इन करके वहीं से आगे बढ़ सकते हैं।';
  @override
  String get settingsSignOutConfirm => 'साइन आउट';
  @override
  String get settingsStay => 'रहने दें';
  @override
  String get settingsDevEntitlements => 'डेव एंटाइटलमेंट';
  @override
  String get settingsPremiumEnabled => 'प्रीमियम चालू है';
  @override
  String get settingsEnablePremium => 'प्रीमियम चालू करें';
  @override
  String get settingsPremiumEnabledDev => 'प्रीमियम चालू (डेव)';
  @override
  String get settingsBackToFreeDev => 'वापस फ्री (डेव)';
  @override
  String settingsVersion(String version) => 'SpeedQuiz · v$version';
}
