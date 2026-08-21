import 'package:speedquiz/core/i18n/app_language.dart';
import 'package:speedquiz/core/i18n/sq_strings.dart';

/// English copy. The source of truth: new strings land here first and every
/// other language implements against them.
class SqStringsEn extends SqStrings {
  const SqStringsEn();

  @override
  AppLanguage get language => AppLanguage.english;

  // --- Common ------------------------------------------------------------
  @override
  String get appTagline => 'Think fast. Score faster.';
  @override
  String get retry => 'Retry';
  @override
  String get cancel => 'Cancel';
  @override
  String get close => 'Close';
  @override
  String get ok => 'OK';
  @override
  String get done => 'Done';
  @override
  String get save => 'Save';
  @override
  String get saving => 'Saving…';
  @override
  String get loading => 'Loading…';
  @override
  String get somethingWentWrong => 'Something went wrong';
  @override
  String get tryAgain => 'Try again';
  @override
  String get all => 'All';
  @override
  String get search => 'Search';
  @override
  String get comingSoon => 'Coming soon';
  @override
  String get today => 'Today';
  @override
  String get points => 'pts';
  @override
  String get level => 'Level';
  @override
  String get levelShort => 'LVL';
  @override
  String get xp => 'XP';
  @override
  String get coins => 'Coins';
  @override
  String get streak => 'Streak';
  @override
  String get bestStreak => 'Best streak';
  @override
  String get accuracy => 'Accuracy';
  @override
  String get score => 'Score';
  @override
  String get rank => 'Rank';
  @override
  String get you => 'You';
  @override
  String get player => 'Player';

  @override
  String questionsCount(int count) =>
      count == 1 ? '1 question' : '$count questions';
  @override
  String topicsCount(int count) => count == 1 ? '1 topic' : '$count topics';
  @override
  String questionsCountCompact(String formatted) => '$formatted questions';
  @override
  String daysCount(int count) => count == 1 ? '1 day' : '$count days';

  // --- Languages ---------------------------------------------------------
  @override
  String get appLanguageTitle => 'App language';
  @override
  String get appLanguageSubtitle => 'Menus, buttons and messages';
  @override
  String get quizLanguageTitle => 'Quiz language';
  @override
  String get quizLanguageSubtitle => 'The language questions are written in';
  @override
  String get quizLanguageHint =>
      'Set per run — your app language stays as it is.';
  @override
  String languageChanged(String nativeName) => 'Language set to $nativeName';
  @override
  String languageBankEmpty(String nativeName) =>
      'No $nativeName questions here yet';
  @override
  String languageBankEmptyHint(String nativeName) =>
      'This topic has not been written in $nativeName yet. Pick another topic, '
      'or switch the quiz language.';

  // --- Errors ------------------------------------------------------------
  @override
  String get errorGeneric => 'Something went wrong. Please try again.';
  @override
  String get errorTimeout =>
      'Request timed out. Check your connection and try again.';
  @override
  String get errorNoConnection =>
      'Cannot reach the server. Check your connection and try again.';
  @override
  String get errorSessionExpired =>
      'Session expired. Go home and reopen the app to sign in again.';
  @override
  String get errorTooManyRequests =>
      'Too many requests. Please wait a moment and try again.';
  @override
  String get errorNoQuestion => 'No question available.';
  @override
  String get errorNoNextQuestion => 'No next question was returned.';
  @override
  String get errorUniqueCap =>
      'You have hit the free unique-question limit for this topic. '
      'Go Premium to keep playing it.';

  // --- Shell -------------------------------------------------------------
  @override
  String get tabHome => 'Home';
  @override
  String get tabExplore => 'Explore';
  @override
  String get tabRanks => 'Ranks';
  @override
  String get tabProfile => 'Profile';
  @override
  String get pressBackAgainToExit => 'Press back again to exit';

  // --- Home --------------------------------------------------------------
  @override
  String get greetingNight => 'BURNING THE MIDNIGHT OIL';
  @override
  String get greetingMorning => 'GOOD MORNING';
  @override
  String get greetingAfternoon => 'GOOD AFTERNOON';
  @override
  String get greetingEvening => 'GOOD EVENING';
  @override
  String greetingWithName(String greeting, String name) =>
      '$greeting, ${name.toUpperCase()}';
  @override
  String get homeHeadline => 'Pick a topic.\nClimb the ranks.';
  @override
  String get homeReady => 'READY';
  @override
  String get homeServerScored => 'SERVER-SCORED';
  @override
  String get homeStartARun => 'Start a run';
  @override
  String get homeStartARunBody =>
      'Timed questions, speed bonuses and streak multipliers. '
      'Casual, Speedrun or Survival.';
  @override
  String get homePlay => 'PLAY';
  @override
  String get homeSurprise => 'SURPRISE';
  @override
  String get homeOpenProfile => 'Open your profile';
  @override
  String get homeJumpBackIn => 'Jump back in';
  @override
  String get homeJumpBackInSubtitle => 'Topics with the deepest question banks';
  @override
  String get homeTopicsUnavailable => 'Topics unavailable';
  @override
  String get homeCouldNotLoadTopics => 'Could not load topics.';
  @override
  String get homeBankFilling =>
      'The question bank is still filling up. Check back shortly.';
  @override
  String get homeCustomTopic => 'Custom topic';
  @override
  String get homeCustomTopicBody =>
      'Describe anything and the AI builds a quiz for it';
  @override
  String get homeNoTopicReady => 'No topic has questions ready yet.';

  // --- Daily challenge ---------------------------------------------------
  @override
  String get dailyChallenge => 'Daily Challenge';
  @override
  String get dailyTapToRetry => 'Tap to retry';
  @override
  String get dailyUnavailable => 'Daily challenge is unavailable.';
  @override
  String get dailyTodayDone => 'Today is done';
  @override
  String dailyTodayDoneWithScore(String score) =>
      'You scored $score on today’s challenge. A fresh set unlocks tomorrow.';
  @override
  String get dailyTodayDoneGeneric =>
      'You already cleared today’s challenge. A fresh set unlocks tomorrow.';
  @override
  String get dailyNice => 'NICE';
  @override
  String dailyCleared(String score) => 'Cleared · $score pts';
  @override
  String get dailyClearedNoScore => 'Cleared · back tomorrow';
  @override
  String dailyResume(String topic) => 'Resume · $topic';
  @override
  String dailySubtitle(String topic, int questions) =>
      '$topic · ${questionsCount(questions)}';

  // --- Quiz setup --------------------------------------------------------
  @override
  String get setupTitle => 'New run';
  @override
  String get setupClose => 'Close';
  @override
  String get setupModeCasual => 'Casual';
  @override
  String get setupModeCasualHook => 'Endless. Play for the streak.';
  @override
  String get setupModeSpeedrun => 'Speedrun';
  @override
  String get setupModeSpeedrunHook => 'Answer fast to buy more time.';
  @override
  String get setupModeSurvival => 'Survival';
  @override
  String get setupModeSurvivalHook => 'Three lives. It gets faster.';
  @override
  String get difficultyEasy => 'Easy';
  @override
  String get difficultyMedium => 'Medium';
  @override
  String get difficultyHard => 'Hard';
  @override
  String get difficultyExpert => 'Expert';
  @override
  String get difficultyAdaptive => 'Adaptive';
  @override
  String get setupSurpriseMe => 'Surprise me';
  @override
  String get setupCustomTopic => 'Custom topic';
  @override
  String setupSearchTopics(int count) => 'Search $count topics';
  @override
  String get setupPickATopic => 'PICK A TOPIC';
  @override
  String startWithTopic(String topic) => 'START · ${topic.toUpperCase()}';
  @override
  String get setupPickTopicToStart => 'Pick a topic to start your run.';
  @override
  String get setupNoTopicReady => 'No topic has questions ready yet.';
  @override
  String setupRandomPicked(String topic) => '🎲 $topic it is.';
  @override
  String setupTopicStillWriting(String topic) =>
      '$topic is still being written. Check back shortly.';
  @override
  String get setupBankFilling => 'Bank still filling';
  @override
  String get setupBankFillingBody =>
      'No topic has questions ready yet. Build your own instead.';
  @override
  String get setupCreateCustomTopic => 'CREATE CUSTOM TOPIC';
  @override
  String setupNoTopicMatches(String query) => 'No topic matches "$query"';
  @override
  String get setupNoTopicMatchesBody =>
      'Try a different word, or generate exactly what you want.';
  @override
  String get setupCouldNotLoadTopics => 'Could not load topics';
  @override
  String get setupComingSoonBody =>
      'Questions are still being written for these.';
  @override
  String get setupUnavailableInLanguage => 'Not in this language yet';

  // --- Quiz play ---------------------------------------------------------
  @override
  String get playPreparing => 'Preparing your challenge…';
  @override
  String get playPreparingHint =>
      'Questions are served from the bank, not generated live.';
  @override
  String get playScoringRun => 'Scoring your run…';
  @override
  String get playGo => 'GO';
  @override
  String get playSpeedrunTitle => 'SPEEDRUN';
  @override
  String get playRuleRight => 'Right answers buy time back — faster pays more';
  @override
  String get playRuleWrong => 'Wrong burns 3 seconds';
  @override
  String get playRuleTighter => 'Every few questions the clock gets tighter';
  @override
  String get playEndRunTitle => 'End this run?';
  @override
  String get playEndRunBody =>
      'Your score so far is banked and the run is scored now. '
      'You cannot resume it afterwards.';
  @override
  String get playEndRunConfirm => 'END RUN';
  @override
  String get playKeepPlaying => 'KEEP PLAYING';
  @override
  String get playEndRun => 'End run';
  @override
  String get playRunInterrupted => 'Run interrupted';
  @override
  String get playFreeLimitReached => 'Free limit reached';
  @override
  String get playGoPremium => 'GO PREMIUM';
  @override
  String get playPaywallReason =>
      'You hit the free unique-question limit for this topic.';
  @override
  String get playBackHome => 'BACK HOME';
  @override
  String get playLanguageUnavailableTitle => 'Not in this language yet';
  @override
  String questionNumber(int number) => 'Q$number';
  @override
  String get playRunClock => 'RUN CLOCK';
  @override
  String overdriveMultiplier(int streak) => 'OVERDRIVE ×$streak';
  @override
  String get playCorrect => 'Correct';
  @override
  String get playNotQuite => 'Not quite';
  @override
  String get playWhy => 'WHY';
  @override
  String get playNext => 'NEXT';
  @override
  String get playSeeResults => 'SEE RESULTS';
  @override
  String get playTeachMe => 'TEACH ME';
  @override
  String get playTeachMeThis => 'TEACH ME THIS';
  @override
  String get playTeaching => 'TEACHING…';
  @override
  String get playTeachError => 'Could not load a deeper explanation right now.';
  @override
  String get teachWhyCorrect => 'Why the answer is right';
  @override
  String get teachWhyWrong => 'Why yours missed';
  @override
  String get teachKeyConcept => 'Key concept';
  @override
  String get teachRemember => 'Remember this';
  @override
  String livesLeft(int lives) => lives == 1 ? '1 life left' : '$lives lives left';

  // --- Results -----------------------------------------------------------
  @override
  String get resultsNewPersonalBest => 'NEW PERSONAL BEST';
  @override
  String get resultsRunComplete => 'RUN COMPLETE';
  @override
  String personalBestValue(String score) => 'Personal best $score';
  @override
  String get resultsAvgAnswer => 'Avg answer';
  @override
  String get resultsSurvived => 'Survived';
  @override
  String get resultsQuestions => 'Questions';
  @override
  String get resultsUnlocked => 'Unlocked';
  @override
  String get resultsOneAchievement => 'One new achievement';
  @override
  String achievementsUnlockedCount(int count) => '$count new achievements';
  @override
  String get resultsPlayAgain => 'PLAY AGAIN';
  @override
  String get resultsNewRun => 'NEW RUN';
  @override
  String get resultsShare => 'SHARE';
  @override
  String get resultsHome => 'HOME';
  @override
  String get resultsShareFailed => 'Could not open the share sheet.';
  @override
  String levelUpTo(int level) => 'LEVEL UP — you hit level $level';
  @override
  String levelBadge(int level) => 'LEVEL $level';
  @override
  String get resultsLoading => 'Loading your result…';
  @override
  String get resultsUnavailable => 'Result unavailable';
  @override
  String get resultsCouldNotLoad => 'This run could not be loaded.';
  @override
  String get resultsGoHome => 'GO HOME';
  @override
  String get resultsOpenSharedCard => 'Open the shared card instead';

  // --- Explore -----------------------------------------------------------
  @override
  String get exploreTitle => 'Explore';
  @override
  String get exploreSearchHint => 'Search topics…';
  @override
  String get exploreNothingHere => 'Nothing here yet';
  @override
  String get exploreCategoryEmpty => 'This category has no topics stocked yet.';
  @override
  String exploreNoMatch(String query) =>
      'No topic matches “$query”. Build it instead.';
  @override
  String get exploreTrendingNow => 'Trending now';
  @override
  String get exploreBankFilling => 'Bank filling up';
  @override
  String get exploreRandom => 'RANDOM';
  @override
  String get explorePlayRandom => 'Play a random topic';
  @override
  String get exploreCouldNotLoad => 'Could not load topics';
  @override
  String get exploreCheckConnection => 'Check your connection and try again.';
  @override
  String exploreReadyToPlay(int count) =>
      count == 1 ? '1 topic ready to play' : '$count topics ready to play';

  // --- Leaderboard -------------------------------------------------------
  @override
  String get leaderboardTitle => 'Leaderboard';
  @override
  String get leaderboardSubtitle =>
      'Climb the weekly ranks and today’s daily board';
  @override
  String get leaderboardWeekly => 'Weekly';
  @override
  String get leaderboardDaily => 'Daily';
  @override
  String get leaderboardCouldNotLoad => 'Could not load ranks';
  @override
  String get leaderboardUnreachable => 'The board is not reachable right now.';
  @override
  String get leaderboardEmpty => 'No ranks yet';
  @override
  String get leaderboardEmptyDaily =>
      'Finish today’s challenge to claim the board first.';
  @override
  String get leaderboardEmptyWeekly =>
      'Play a run this week and your name lands here.';
  @override
  String yourBestIn(String period) => 'Your best · $period';

  // --- Profile -----------------------------------------------------------
  @override
  String get profileTitle => 'Profile';
  @override
  String get profileDetails => 'Profile details';
  @override
  String get profileDetailsSubtitle =>
      'Name, avatar and how you appear on boards';
  @override
  String get profileAchievements => 'Achievements';
  @override
  String get profileAchievementsSubtitle =>
      'Track everything you have unlocked';
  @override
  String achievementsProgress(int unlocked, int total) =>
      '$unlocked of $total unlocked';
  @override
  String get profileStatistics => 'Statistics';
  @override
  String get profileStatisticsSubtitle => 'Accuracy, speed and topic mastery';
  @override
  String get profilePremium => 'Premium';
  @override
  String get profileGoPremium => 'Go Premium';
  @override
  String get profilePremiumThanks => 'Thanks for supporting SpeedQuiz';
  @override
  String get profilePremiumPitch => 'Unlimited questions and custom topics';
  @override
  String get profileSettingsSubtitle => 'Appearance, language, sound, account';
  @override
  String get profileGuest => 'Guest';
  @override
  String get profileFree => 'FREE';
  @override
  String get profilePremiumBadge => 'PREMIUM';
  @override
  String get profileGuestBadge => 'GUEST';
  @override
  String get profileBack => 'Back';

  // --- Profile edit ------------------------------------------------------
  @override
  String get editTitle => 'Profile details';
  @override
  String get editSubtitle => 'How you appear on leaderboards';
  @override
  String get editDisplayName => 'Display name';
  @override
  String get editDisplayNameSubtitle => 'Leave empty to use your handle';
  @override
  String get editDisplayNameHint => 'e.g. Quiz Goblin';
  @override
  String get editAvatar => 'Avatar';
  @override
  String get editAvatarSubtitle => 'Pick the look that fits you';
  @override
  String get editPremiumAvatarReason => 'Premium avatars are part of Premium.';
  @override
  String get editSaveChanges => 'SAVE CHANGES';
  @override
  String get editSaved => 'Profile updated.';
  @override
  String get editSaveFailed => 'Could not save your profile. Try again.';
  @override
  String editNameTooShort(int minimum) =>
      'Names need at least $minimum characters.';

  // --- Account card ------------------------------------------------------
  @override
  String get accountTitle => 'ACCOUNT';
  @override
  String get accountGoogle => 'GOOGLE';
  @override
  String get accountGuest => 'GUEST';
  @override
  String get accountUsername => 'Username';
  @override
  String get accountEmail => 'Email';
  @override
  String get accountNotLinked => 'Not linked';
  @override
  String get accountPlayingSince => 'Playing since';
  @override
  String get accountOnThisDevice => 'on this device';
  @override
  String get accountPlayerId => 'Player ID';
  @override
  String get accountCopyPlayerId => 'Copy player ID';
  @override
  String get accountPlayerIdCopied => 'Player ID copied.';
  @override
  String get accountGuestHint =>
      'Guest progress lives on this device. Link a Google account in Settings '
      'to carry it to your next phone.';

  // --- Stats -------------------------------------------------------------
  @override
  String get statsTitle => 'Statistics';
  @override
  String get statsSubtitle => 'Everything you have played so far';
  @override
  String get statsUnavailable => 'Statistics unavailable';
  @override
  String get statsCouldNotLoad => 'Could not load your statistics.';
  @override
  String get statsNoRuns => 'No runs yet';
  @override
  String get statsNoRunsBody =>
      'Play your first quiz and your numbers land here.';
  @override
  String get statsLifetimeAccuracy => 'Lifetime accuracy';
  @override
  String get statsRunsPlayed => 'Runs played';
  @override
  String get statsBestScore => 'Best score';
  @override
  String get statsQuestions => 'Questions';
  @override
  String get statsMissed => 'Missed';
  @override
  String get statsTopicMastery => 'Topic mastery';
  @override
  String get statsTopicMasterySubtitle => 'Where you are strongest';

  // --- Achievements ------------------------------------------------------
  @override
  String get achievementsTitle => 'Achievements';
  @override
  String get achievementsSubtitle => 'Every milestone worth chasing';
  @override
  String get achievementsUnavailable => 'Achievements unavailable';
  @override
  String get achievementsCouldNotLoad => 'Could not load your achievements.';
  @override
  String get achievementsNoneYet => 'Nothing unlocked yet';
  @override
  String get achievementsAllUnlocked => 'All unlocked';
  @override
  String get achievementsNoneYetBody =>
      'Finish a run to claim your first one.';
  @override
  String get achievementsAllUnlockedBody =>
      'You have claimed every achievement. Respect.';
  @override
  String get achievementsCompletionist =>
      'Completionist. Nothing left to chase.';
  @override
  String get achievementsFilterAll => 'All';
  @override
  String get achievementsFilterUnlocked => 'Unlocked';
  @override
  String get achievementsFilterLocked => 'Locked';

  // --- Custom topic ------------------------------------------------------
  @override
  String get customTitle => 'Custom topic';
  @override
  String get customHeadline => 'What do you want to\nbe quizzed on?';
  @override
  String get customBody =>
      'Describe anything — games, science, lore, hobbies. '
      'The AI writes and validates the questions.';
  @override
  String get customPromptHint =>
      'e.g. Ask me difficult questions about Elden Ring lore';
  @override
  List<String> get customSuggestions => const [
        'Elden Ring lore, but brutal',
        'Formula 1 rules and history',
        'Ancient Rome for a nerd',
        'Machine learning fundamentals',
        'Classic horror cinema',
      ];
  @override
  String get customDifficulty => 'Difficulty';
  @override
  String get customMode => 'Mode';
  @override
  String get customStyle => 'Style';
  @override
  String get customStyleSubtitle => 'Optional — how should the questions feel?';
  @override
  String get customStyleHint => 'e.g. lore-heavy, trivia, practical';
  @override
  String get customCreate => 'CREATE QUIZ';
  @override
  String get customNeedPrompt => 'Tell us what you want to be quizzed on.';
  @override
  String get customNotEnoughQuestions =>
      'We could not build enough good questions for that. '
      'Try a clearer or broader topic.';
  @override
  String get customFailed =>
      'Could not prepare your challenge. Please try again.';
  @override
  String get customBuilding => 'Building your quiz';
  @override
  String get customBuildingHint =>
      'This one runs a real model, so it takes a few seconds. '
      'Everything after this is served instantly.';
  @override
  String get customStageUnderstanding => 'Understanding your topic';
  @override
  String get customStageWriting => 'Writing candidate questions';
  @override
  String get customStageChecking => 'Fact-checking every answer';
  @override
  String get customStageShuffling => 'Shuffling the good ones in';
  @override
  String customLanguageNote(String nativeName) =>
      'Questions will be written in $nativeName';

  // --- Landing / onboarding ----------------------------------------------
  @override
  String get landingTagline => 'Endless AI quizzes. Real game energy.';
  @override
  String get landingWarmingUp => 'Warming up…';
  @override
  String get landingFeatureModesTitle => 'Three ways to play';
  @override
  String get landingFeatureModesBody =>
      'Endless Casual, the Speedrun clock, Survival on three lives';
  @override
  String get landingFeatureDailyTitle => 'Daily challenge & ranks';
  @override
  String get landingFeatureDailyBody =>
      'One fresh set a day, weekly and daily boards';
  @override
  String get landingFeatureExplainTitle => 'Every answer explained';
  @override
  String get landingFeatureExplainBody =>
      'Miss one and the app teaches you why';
  @override
  String get landingPlayAsGuest => 'PLAY AS GUEST';
  @override
  String get landingNewGuestRun => 'START A NEW GUEST RUN';
  @override
  String get landingGuestNote =>
      'Guest progress is saved on this device and can be linked later.';
  @override
  String get landingGoogleUnavailable => 'Google sign-in unavailable';
  @override
  String get landingGoogleUnavailableBody =>
      'This build was compiled without a Google client ID. '
      'Play as a guest — you can link a Google account later.';
  @override
  String get landingGoogleFailed => 'Google sign-in failed.';
  @override
  String get landingContinueWithGoogle => 'Continue with Google';
  @override
  String landingReadyName(String name) => 'Ready when you are, $name.';

  // --- First run ---------------------------------------------------------
  @override
  String onboardingStepOf(int step, int total) => 'Step $step of $total';
  @override
  String get onboardingBack => 'Back';
  @override
  String get onboardingLanguageTitle => 'Pick your language';
  @override
  String get onboardingLanguageBody =>
      'The whole app switches the moment you choose. '
      'You can change it any time in Settings.';
  @override
  String get onboardingLanguageQuizNote =>
      'Quizzes start in this language too — questions can have their own '
      'language later.';
  @override
  String get onboardingNameTitle => 'What should we call you?';
  @override
  String get onboardingNameBody =>
      'It goes on your profile, your home screen and the leaderboards. '
      'You can change it later.';
  @override
  String get onboardingNameHint => 'Your name';
  @override
  String get onboardingContinue => 'CONTINUE';
  @override
  String get onboardingLetsGo => "LET'S GO";
  @override
  String get onboardingSkip => 'SKIP FOR NOW';

  // --- Welcome sheet -----------------------------------------------------
  @override
  String get welcomeNewPlayer => 'Welcome to SpeedQuiz';
  @override
  String welcomeNewPlayerNamed(String name) => 'Welcome to SpeedQuiz, $name';
  @override
  String welcomeSignedIn(String name) => 'Welcome, $name';
  @override
  String welcomeBack(String name) => 'Welcome back, $name';
  @override
  String get welcomeWaitingToday => 'Waiting for you today';
  @override
  String get welcomeStartPlaying => 'START PLAYING';
  @override
  String get welcomeJumpBackIn => 'JUMP BACK IN';
  @override
  String get welcomeLookAround => 'LOOK AROUND FIRST';
  @override
  String get welcomeGuestBody =>
      'Playing as a guest — your progress is saved on this device and can be '
      'linked to an account later.';
  @override
  String get welcomeAccountBody =>
      'Your account is ready. Progress syncs everywhere you sign in.';
  @override
  String welcomeGuestHandle(String username) => 'Guest account · @$username';
  @override
  String get welcomeCuePickTopic => 'Pick a topic and start a run';
  @override
  String get welcomeCueDailyDone => 'Daily done — free play is open';
  @override
  String welcomeCueResumeDaily(String topic) => 'Resume the daily · $topic';
  @override
  String welcomeCueDaily(String topic) => 'Daily challenge · $topic';

  // --- Shared result -----------------------------------------------------
  @override
  String get sharedRunBadge => 'SHARED RUN';
  @override
  String get sharedCardUnavailable => 'Card unavailable';
  @override
  String get sharedCardExpired =>
      'This shared result has expired or was removed.';
  @override
  String get sharedOpenSpeedQuiz => 'OPEN SPEEDQUIZ';
  @override
  String get sharedBeatThat => 'Think you can beat that?';
  @override
  String get sharedBeatThisScore => 'BEAT THIS SCORE';

  // --- Premium -----------------------------------------------------------
  @override
  String get premiumUnlockEverything => 'Support the game, unlock everything';
  @override
  String get premiumYourePremium => 'You’re Premium';
  @override
  String get premiumBenefitQuestionsTitle => 'Unlimited questions';
  @override
  String get premiumBenefitQuestionsBody =>
      'No cap on unique questions in any topic';
  @override
  String get premiumBenefitCustomTitle => 'Unlimited custom topics';
  @override
  String get premiumBenefitCustomBody =>
      'Generate quizzes on anything, as often as you like';
  @override
  String get premiumBenefitCosmeticsTitle => 'Premium avatars & flair';
  @override
  String get premiumBenefitCosmeticsBody =>
      'Six exclusive avatars, a gold profile ring and a leaderboard badge';
  @override
  String get premiumUnlocked => 'Premium unlocked. Enjoy.';
  @override
  String get premiumUnlockedTest => 'Premium unlocked (test purchase)';
  @override
  String get premiumVerifyReturnedFree => 'Verify returned free — check the server';
  @override
  String get premiumEnabledStub => 'Premium enabled (stub purchase)';
  @override
  String get premiumEnabledDev => 'Premium enabled (dev)';
  @override
  String get premiumNotAvailableHere =>
      'Subscriptions are not available on this device yet — '
      'nothing has been charged.';
  @override
  String get premiumRestored => 'Purchases restored.';
  @override
  String get premiumNoSubscription =>
      'No active subscription on this store account.';
  @override
  String get premiumRestoredStub => 'Premium restored (stub)';
  @override
  String get premiumNothingToRestore => 'Nothing to restore.';
  @override
  String get premiumRestoreUnavailable =>
      'Restore is unavailable on this device.';
  @override
  String get premiumRestorePurchases => 'Restore purchases';
  @override
  String get premiumSubscribe => 'SUBSCRIBE';
  @override
  String premiumSubscribeWithPrice(String price) => 'SUBSCRIBE · $price';
  @override
  String premiumSwitchTo(String plan) => 'SWITCH TO $plan';
  @override
  String get premiumTestPurchase => 'TEST PURCHASE';
  @override
  String premiumTestPurchaseWith(String plan) => 'TEST PURCHASE · $plan';
  @override
  String get premiumEnableDev => 'ENABLE PREMIUM (DEV)';
  @override
  String get premiumUnavailable => 'UNAVAILABLE';
  @override
  String get premiumTestModeNote =>
      'Test mode — purchases are simulated on the server and nothing is '
      'charged.';
  @override
  String get premiumSignInNote =>
      'Sign in with Google so your subscription follows you to your next '
      'device.';
  @override
  String get premiumCurrent => 'CURRENT';
  @override
  String get premiumNotOnThisDevice => 'Not available on this device';
  @override
  String premiumSavePercent(int percent) => 'Save $percent%';
  @override
  String get premiumRenewsAutomatically =>
      'Your subscription renews automatically';
  @override
  String premiumRenewsAt(String price, String period) =>
      'Renews automatically at $price per $period';
  @override
  String premiumCancelAnytime(String store) =>
      'Cancel anytime from your $store account — you keep Premium until the '
      'period ends.';

  // --- Subscription status -----------------------------------------------
  @override
  String get subPaymentFailed => 'Payment failed';
  @override
  String get subOnHold => 'Subscription on hold';
  @override
  String get subPaused => 'Subscription paused';
  @override
  String get subPaymentProcessing => 'Payment processing';
  @override
  String get subCancelled => 'Cancelled';
  @override
  String get subEnded => 'Subscription ended';
  @override
  String get subRefunded => 'Subscription refunded';
  @override
  String subActivePlan(String plan) => '$plan · Active';
  @override
  String get subFixPaymentMethod => 'FIX PAYMENT METHOD';
  @override
  String get subManageSubscription => 'MANAGE SUBSCRIPTION';
  @override
  String get subCouldNotOpenStore => 'Could not open your store subscriptions.';
  @override
  String get subUpdatePaymentNow =>
      'Update your payment method to keep Premium.';
  @override
  String subUpdatePaymentBy(String date) =>
      'Update your payment method by $date to keep Premium.';
  @override
  String get subOnHoldBody =>
      'Your last payment did not go through, so Premium is paused. '
      'Update your payment method to pick up where you left off.';
  @override
  String get subPausedBody =>
      'Premium resumes automatically when your pause ends.';
  @override
  String subProcessingBody(String date) =>
      'Your bank is still confirming the payment. Premium unlocks by $date.';
  @override
  String get subCancelledBodyNoDate =>
      'Premium stays active until the end of your billing period.';
  @override
  String subCancelledBody(String date) =>
      'Premium stays active until $date. You will not be charged again.';
  @override
  String get subEndedBody => 'Resubscribe any time to unlock Premium again.';
  @override
  String get subRefundedBody =>
      'This purchase was refunded, so Premium has ended.';
  @override
  String get subThanks => 'Thanks for supporting SpeedQuiz.';
  @override
  String subIntroPriceUntil(String date) =>
      'Your introductory price applies until $date.';
  @override
  String subRenewsOn(String date) => 'Renews on $date.';

  // --- Misc widgets ------------------------------------------------------
  @override
  String get hotBadge => 'HOT';
  @override
  String get confirm => 'CONFIRM';
  @override
  String get gotIt => 'GOT IT';
  @override
  String get periodMonth => 'month';
  @override
  String get periodYear => 'year';
  @override
  String get streakActive => 'Streak active';
  @override
  String get streakInactive => 'Streak inactive';

  // --- Speed tiers -------------------------------------------------------
  @override
  String get speedTierBlitz => 'BLITZ';
  @override
  String get speedTierFast => 'FAST';
  @override
  String get speedTierClean => 'CLEAN';
  @override
  String get speedTierClutch => 'CLUTCH';

  // --- Billing progress --------------------------------------------------
  @override
  String get billingOpeningStore => 'Opening the store…';
  @override
  String get billingRestoring => 'Restoring purchases…';
  @override
  String get billingVerifying => 'Verifying…';
  @override
  String get billingCouldNotStart => 'Could not start purchase';
  @override
  String get billingPurchaseFailed => 'Purchase failed';
  @override
  String get billingWaitingForPayment =>
      'Waiting for your payment to clear. Premium unlocks automatically once '
      'it does.';
  @override
  String get billingStoreUnavailable => 'Store not available on this device';
  @override
  String get billingNoPlans => 'No plans configured';

  // --- Settings ----------------------------------------------------------
  @override
  String get settingsTitle => 'Settings';
  @override
  String get settingsAppearance => 'Appearance';
  @override
  String get settingsAppearanceSubtitle => 'Applies instantly across the app';
  @override
  String get settingsThemeDark => 'Dark';
  @override
  String get settingsThemeLight => 'Light';
  @override
  String get settingsThemeSystem => 'System';
  @override
  String get settingsLanguageSection => 'Language';
  @override
  String get settingsLanguageSubtitle =>
      'The app and your quizzes can differ';
  @override
  String get settingsFeel => 'Feel';
  @override
  String get settingsFeelSubtitle => 'Sound and vibration';
  @override
  String get settingsSound => 'Sound effects';
  @override
  String get settingsSoundSubtitle => 'Answer, streak and result cues';
  @override
  String get settingsMusic => 'Ambient music';
  @override
  String get settingsMusicSubtitle => 'Low background loop while you play';
  @override
  String get settingsReminders => 'Reminders';
  @override
  String get settingsRemindersSubtitle =>
      'Daily challenge, streaks and the occasional nudge.';
  @override
  String get settingsHaptics => 'Haptics';
  @override
  String get settingsHapticsSubtitle => 'Taps, hits and misses you can feel';
  @override
  String get settingsAccount => 'Account';
  @override
  String get settingsSaveProgress => 'Save your progress';
  @override
  String get settingsSaveProgressBody =>
      'Guest progress lives only on this device. Link a Google account and '
      'your level, streak and ranks follow you anywhere.';
  @override
  String get settingsLinkGoogle => 'Link Google account';
  @override
  String get settingsGoogleUnavailable => 'Google sign-in unavailable';
  @override
  String get settingsGoogleUnavailableBody =>
      'This build was compiled without a Google client ID, so accounts cannot '
      'be linked here.';
  @override
  String get settingsAccountLinked => 'Account linked — your progress is safe.';
  @override
  String get settingsAccountLinkFailed => 'Could not link your account.';
  @override
  String get settingsSignedInWithGoogle => 'Signed in with Google';
  @override
  String get settingsSignOut => 'SIGN OUT';
  @override
  String get settingsSigningOut => 'SIGNING OUT…';
  @override
  String get settingsSignOutTitle => 'Sign out?';
  @override
  String get settingsSignOutGuestBody =>
      'This is a guest session. Signing out ends it — level, XP and streak on '
      'this device will not come back unless you link a Google account first.';
  @override
  String get settingsSignOutBody =>
      'You can sign back in with Google any time and pick up exactly where you '
      'left off.';
  @override
  String get settingsSignOutConfirm => 'SIGN OUT';
  @override
  String get settingsStay => 'STAY';
  @override
  String get settingsDevEntitlements => 'Dev entitlements';
  @override
  String get settingsPremiumEnabled => 'Premium enabled';
  @override
  String get settingsEnablePremium => 'Enable Premium';
  @override
  String get settingsPremiumEnabledDev => 'Premium enabled (dev)';
  @override
  String get settingsBackToFreeDev => 'Back to Free (dev)';
  @override
  String settingsVersion(String version) => 'SpeedQuiz · v$version';

  // --- Battle: hub -------------------------------------------------------
  @override
  String get battleTitle => 'Battle';
  @override
  String get battleTab => 'Battle';
  @override
  String get battleQuickMatch => 'Quick match';
  @override
  String get battleQuickMatchSubtitle => 'Ranked 1v1 against someone your level';
  @override
  String get battleChallengeFriend => 'Challenge a friend';
  @override
  String get battleChallengeFriendSubtitle => 'Unranked — just for bragging rights';
  @override
  String get battlePrivateRoom => 'Private room';
  @override
  String get battlePrivateRoomSubtitle => 'Up to 8 players, join by code';
  @override
  String get battleJoinRoom => 'Join with code';
  @override
  String get battleCopy => 'COPY';
  @override
  String get battleYourTurn => 'Your turn';
  @override
  String get battleWaitingOnThem => 'Waiting on them';
  @override
  String get battleActiveMatches => 'In play';
  @override
  String get battleRecentMatches => 'Recent';
  @override
  String get battleNoMatches => 'No battles yet';
  @override
  String get battleNoMatchesBody =>
      'Challenge a friend or find a quick match — your first win is one game away.';
  @override
  String get battleContinue => 'CONTINUE';
  @override
  String get battlePlay => 'PLAY';
  @override
  String get battleView => 'VIEW';

  // --- Battle: lobby -----------------------------------------------------
  @override
  String get lobbyTitle => 'Get ready';
  @override
  String get lobbyWaitingForOpponent => 'Waiting for your opponent…';
  @override
  String get lobbyReady => "I'M READY";
  @override
  String get lobbyNotReady => 'NOT READY';
  @override
  String get lobbyStartNow => 'START NOW';
  @override
  String get lobbyWaitingForReady => 'WAITING FOR EVERYONE';
  @override
  String get lobbyRoomCode => 'Room code';
  @override
  String get lobbyShareCode => 'SHARE CODE';
  @override
  String get lobbyCodeCopied => 'Code copied';
  @override
  String get lobbyEnterCode => 'Enter room code';
  @override
  String get lobbyJoin => 'JOIN';
  @override
  String get lobbyInviteAccepted => 'Challenge accepted';
  @override
  String get lobbyChallengedYou => 'challenged you';

  @override
  String get lobbyChallengeTitle => 'Challenge!';
  @override
  String get lobbyAccept => 'ACCEPT';
  @override
  String get lobbyDecline => 'DECLINE';
  @override
  String get lobbyDeclined => 'Challenge declined';
  @override
  String lobbyPlayersReady(int ready, int total) => '$ready of $total ready';
  @override
  String lobbySeats(int filled, int total) => '$filled/$total players';

  // --- Battle: play ------------------------------------------------------
  @override
  String battleRoundOf(int current, int total) => 'Round $current of $total';
  @override
  String get battleYou => 'You';
  @override
  String get battleOpponent => 'Opponent';
  @override
  String get battleWaitingForOthers => 'Waiting for the others…';
  @override
  String get battleOpponentAnswered => 'Answered';
  @override
  String get battleOpponentThinking => 'Thinking…';
  @override
  String get battleOpponentFinishing => 'Finishing…';
  @override
  String get battleTimeUp => "Time's up";
  @override
  String get battleCorrect => 'Correct';
  @override
  String get battleWrong => 'Wrong';
  @override
  String get battleReconnecting => 'Reconnecting…';

  @override
  String get battleCombo => 'COMBO';

  @override
  String get battleOnFire => 'ON FIRE';

  @override
  String get battleUnstoppable => 'UNSTOPPABLE';

  @override
  String get battleFinalRound => 'FINAL QUESTION';

  @override
  String get battleDoublePoints => 'DOUBLE POINTS';

  @override
  String get battleFirstBonus => 'FIRST!';

  @override
  String get battleCatchUp => 'CATCH-UP BONUS';

  @override
  String battleMultiplier(String value) => '×$value';
  @override
  String get battleOffline => 'Offline — your answers still count';
  @override
  String get battleAbandonAction => 'Abandon';
  @override
  String get battleAbandonTitle => 'Abandon the match?';
  @override
  String get battleAbandonBody =>
      'It ends now and your opponent wins by abandonment. Your score so far is '
      'kept on the scoreboard but cannot win. This cannot be undone.';
  @override
  String get battleAbandonConfirm => 'ABANDON';
  @override
  String get battleAsyncNotice =>
      'Playing at your own pace — your opponent plays the same questions.';

  // --- Battle: result ----------------------------------------------------
  @override
  String get resultWin => 'You won!';
  @override
  String get resultYou => 'You';
  @override
  String get resultVersus => 'VS';
  @override
  String get battleHistoryTitle => 'Match history';
  @override
  String get battleHistorySeeAll => 'HISTORY';
  @override
  String get battleHistoryEmpty => 'No finished matches yet';
  @override
  String get battleHistoryEmptyBody =>
      'Play a battle and your last ten will show up here.';
  @override
  String battleCorrectOf(int correct, int total) => '$correct/$total correct';
  @override
  String get resultLoss => 'You lost';
  @override
  String get resultDraw => 'Dead heat';
  @override
  String get resultWinBody => 'Faster and sharper. Take the points.';
  @override
  String get resultLossBody => 'Close one. Run it back?';
  @override
  String get resultDrawBody => 'Same score, same clock. Nobody blinked.';
  @override
  String get resultWinByAbandonBody => 'Your opponent abandoned the match.';
  @override
  String get resultLossByAbandonBody => 'You abandoned the match.';
  @override
  String get resultAbandoned => 'Left';
  @override
  String get resultAwaitingOpponent => 'Your score is in';
  @override
  String get resultAwaitingOpponentBody =>
      "We'll let you know the moment they finish their turn.";
  @override
  String get resultRematch => 'REMATCH';
  @override
  String get resultBackToBattle => 'BACK TO BATTLE';
  @override
  String get resultNewTopic => 'NEW TOPIC';
  @override
  String get resultHome => 'HOME';
  @override
  String get resultStandings => 'Final standings';
  @override
  String resultRatingGained(int points) => '+$points rating';
  @override
  String resultRatingLost(int points) => '$points rating';
  @override
  String resultPlacement(int place) => switch (place) {
        1 => '1st',
        2 => '2nd',
        3 => '3rd',
        _ => '${place}th',
      };

  // --- Ranked ------------------------------------------------------------
  @override
  String get rankedTitle => 'Ranked';
  @override
  String get rankedSearching => 'Finding an opponent';
  @override
  String get rankedSearchingBody => 'Looking for someone at your level…';
  @override
  String get rankedCancelSearch => 'CANCEL';
  @override
  String get rankedNoOpponent => 'Nobody around right now';
  @override
  String get rankedNoOpponentBody =>
      'The queue is quiet. Try again in a moment, or challenge a friend instead.';
  @override
  String get rankedTryAgain => 'TRY AGAIN';
  @override
  String get rankedPlacements => 'Placement matches';
  @override
  String get rankedUnranked => 'Unranked';
  @override
  String get rankedSeason => 'Season';
  @override
  String get rankedLadder => 'Ladder';
  @override
  String get rankedYourRank => 'Your rank';
  @override
  String get rankedNoRankYet => 'Play a ranked match to join the ladder.';
  @override
  String rankedPlacementsRemaining(int count) =>
      count == 1 ? '1 placement match left' : '$count placement matches left';
  @override
  String rankedNextTier(String tier, int points) => '$points to $tier';
  @override
  String rankedSearchingFor(int seconds) => '${seconds}s';
  @override
  String rankedPlayersSearching(int count) =>
      count == 1 ? '1 player searching' : '$count players searching';
  @override
  String rankedRecord(int wins, int losses, int draws) => '$wins W · $losses L · $draws D';

  // --- Friends -----------------------------------------------------------
  @override
  String get friendsTitle => 'Friends';
  @override
  String get friendsTab => 'Friends';
  @override
  String get friendsRequestsTab => 'Requests';
  @override
  String get friendsAdd => 'Add friend';
  @override
  String get friendsSearchHint => 'Username or friend code';
  @override
  String get friendsSearchEmpty => 'No players found';
  @override
  String get friendsNoFriends => 'No friends yet';
  @override
  String get friendsNoFriendsBody =>
      'Share your friend code, or search for someone by their username.';
  @override
  String get friendsNoRequests => 'Nothing waiting';
  @override
  String get friendsIncoming => 'Waiting on you';
  @override
  String get friendsOutgoing => 'Sent';
  @override
  String get friendsAccept => 'ACCEPT';
  @override
  String get friendsDecline => 'DECLINE';
  @override
  String get friendsCancelRequest => 'CANCEL';
  @override
  String get friendsRequestSent => 'Request sent';
  @override
  String get friendsRequestPending => 'Pending';
  @override
  String get friendsAlreadyFriends => 'Friends';
  @override
  String get friendsChallenge => 'CHALLENGE';
  @override
  String get friendsRemove => 'Remove friend';
  @override
  String get friendsRemoveTitle => 'Remove friend?';
  @override
  String get friendsRemoveConfirm => 'REMOVE';
  @override
  String get friendsBlock => 'Block';
  @override
  String get friendsBlockTitle => 'Block this player?';
  @override
  String get friendsBlockBody =>
      "They won't be able to find you, challenge you, or see you in search. You can undo this in Settings.";
  @override
  String get friendsBlocked => 'Blocked';
  @override
  String get friendsUnblock => 'UNBLOCK';
  @override
  String get friendsBlockedList => 'Blocked players';
  @override
  String get friendsOnline => 'Online';
  @override
  String get friendsYourCode => 'Your friend code';
  @override
  String get friendsShareCode => 'SHARE';
  @override
  String get friendsCodeCopied => 'Friend code copied';
  @override
  String get friendsCodeHint => 'Share this so friends can add you instantly.';
  @override
  String friendsRemoveBody(String name) =>
      'Remove $name from your friends? You can always add them again.';
  @override
  String friendsHeadToHead(int wins, int losses) => '$wins–$losses';
  @override
  String friendsCount(int count) => count == 1 ? '1 friend' : '$count friends';

  // --- Username ----------------------------------------------------------
  @override
  String get usernameTitle => 'Username';
  @override
  String get usernameLabel => 'Choose a username';
  @override
  String get usernameHint => 'e.g. quizwhiz';
  @override
  String get usernameAvailable => 'Available';
  @override
  String get usernameChecking => 'Checking…';
  @override
  String get usernameSave => 'SAVE';
  @override
  String get usernameSaved => 'Username updated';
  @override
  String get usernameSuggestions => 'Try one of these';
  @override
  String get usernameRules =>
      '3–20 characters. Letters, numbers and underscores, starting with a letter.';
  @override
  String usernameLockedUntil(String date) => 'You can change this again on $date.';
  @override
  String usernameError(String code) => switch (code) {
        'username_length' => 'Use between 3 and 20 characters.',
        'username_charset' =>
          'Letters, numbers and underscores only, starting with a letter.',
        'username_reserved' => 'That name is reserved.',
        'username_blocked' => 'Please choose a different name.',
        'username_taken' => 'That name is taken.',
        'username_cooldown' => 'You changed your username recently.',
        _ => 'That name cannot be used.',
      };

  // --- Notifications -----------------------------------------------------
  @override
  String get notificationsTitle => 'Notifications';
  @override
  String get notificationsEmpty => 'Nothing here yet';
  @override
  String get notificationsEmptyBody =>
      'Friend requests, challenges and results will show up here.';
  @override
  String get notificationsMarkRead => 'Mark all read';
  @override
  String get notificationsClear => 'Clear all';
  @override
  String get notificationsClearTitle => 'Clear notifications?';
  @override
  String get notificationsClearBody =>
      'This empties your inbox on every device. Challenges you have not answered stay in Battle.';
  @override
  String get notificationsCleared => 'Inbox cleared';
  @override
  String get notificationsSettings => 'Notification settings';
  @override
  String get notificationsPushDisabled =>
      'Push is off for this build — you will see everything here instead.';
  @override
  String notificationFriendRequest(String name) => '$name wants to be friends';
  @override
  String notificationFriendAccepted(String name) => '$name accepted your request';
  @override
  String notificationMatchInvite(String name, String topic) =>
      '$name challenged you to $topic';
  @override
  String notificationYourTurn(String name) => '$name is waiting for you to play';
  @override
  String notificationMatchResult(String name) => 'Your match with $name is done';
  @override
  String notificationsUnread(int count) =>
      count == 1 ? '1 unread notification' : '$count unread notifications';
  @override
  String get notificationTitleFriendRequest => 'FRIEND REQUEST';
  @override
  String get notificationTitleFriendAccepted => 'FRIEND ADDED';
  @override
  String get notificationTitleYourTurn => 'YOUR TURN';
  @override
  String get notificationTitleMatchResult => 'MATCH FINISHED';
  @override
  String get notificationTitleExpiring => 'ENDING SOON';
  @override
  String get notificationIgnore => 'IGNORE';

  // --- On-device reminders -----------------------------------------------
  @override
  String get reminderDailyTitle => "Today's challenge is up";
  @override
  String get reminderDailyBody => 'A fresh quiz is waiting. Got two minutes?';
  @override
  String get reminderStreakTitle => 'Your streak ends at midnight';
  @override
  String reminderStreakBody(int days) => days == 1
      ? 'One day on the board. Play the daily to keep it.'
      : '$days days on the board. Play the daily to keep it.';
  @override
  String get reminderComebackTitle => 'Ready for a quick round?';
  @override
  String get reminderComebackBody => 'Pick a topic and see how fast you are.';
  @override
  String reminderComebackBodyTopic(String topic) =>
      '$topic is waiting. See how fast you are.';

  // --- Shared errors -----------------------------------------------------
  @override
  String get errorNotFriends => 'You can only challenge friends directly.';
  @override
  String get errorMatchFull => 'That room is full.';
  @override
  String get errorMatchClosed => 'That match has already started.';
  @override
  String get errorBankTooThin => 'Not enough questions in this topic yet.';
  @override
  String get errorAlreadyAnswered => 'You already answered this round.';
  @override
  String get errorRoundClosed => 'That round has closed.';
  @override
  String get errorMultiplayerDisabled => 'Battles are unavailable right now.';
  @override
  String get errorNetwork => 'Check your connection and try again.';
  @override
  String matchError(String code) => switch (code) {
        'not_friends' => errorNotFriends,
        'match_full' => errorMatchFull,
        'match_closed' || 'match_started' => errorMatchClosed,
        'bank_too_thin' => errorBankTooThin,
        'already_answered' => errorAlreadyAnswered,
        'round_closed' => errorRoundClosed,
        'multiplayer_disabled' => errorMultiplayerDisabled,
        'match_not_found' => 'That match no longer exists.',
        'user_not_found' => 'Player not found.',
        'already_friends' => friendsAlreadyFriends,
        'request_pending' => friendsRequestPending,
        'friends_full' => 'Your friend list is full.',
        'too_many_requests' => 'Too many requests. Try again later.',
        'not_enough_players' => 'You need at least one opponent.',
        'players_not_ready' => 'Everyone needs to be ready first.',
        'not_host' => 'Only the host can start.',
        'rate_limited' => 'Slow down a moment.',
        _ => errorNetwork,
      };

  // --- Quiz studio (player-authored quizzes) -----------------------------
  @override
  String get studioTitle => 'Quiz studio';
  @override
  String get studioHeadline => 'Write a quiz.\nChallenge your friends.';
  @override
  String get studioBody =>
      'Your questions, your answers. Play it solo or put it in front of a friend.';
  @override
  String get studioMine => 'Your quizzes';
  @override
  String get studioShared => 'Shared with you';
  @override
  String get studioSharedSubtitle => 'Quizzes friends sent you';
  @override
  String get studioEmptyTitle => 'Nothing here yet';
  @override
  String get studioEmptyBody =>
      'Make your first quiz, or open one a friend sent you with their code.';
  @override
  String get studioCreate => 'Create a quiz';
  @override
  String get studioNewQuiz => 'New quiz';
  @override
  String get studioOpenWithCode => 'Open with a code';
  @override
  String get studioCodeHint => 'e.g. BCD234';
  @override
  String get studioCodeInvalid => 'That code does not look right.';
  @override
  String get studioOpen => 'Open';
  @override
  String get studioCouldNotLoad => 'Could not load your quizzes.';
  @override
  String studioSlotsLeft(int remaining, int total) =>
      '$remaining of $total quiz slots left';
  @override
  String get studioSlotsUnlimited => 'Unlimited quizzes';
  @override
  String get studioSlotsNone => 'All quiz slots used';
  @override
  String get studioSlotsNoneBody =>
      'Archive one, or go Premium for unlimited quizzes.';

  @override
  String get homeMakeQuiz => 'Make your own quiz';
  @override
  String get homeMakeQuizBody => 'Write the questions, challenge your friends';

  @override
  String get quizStatusDraft => 'Draft';
  @override
  String get quizStatusPublished => 'Live';
  @override
  String get quizStatusArchived => 'Archived';
  @override
  String get quizStatusHidden => 'Under review';
  @override
  String get quizVisibilityPrivate => 'Just me';
  @override
  String get quizVisibilityPrivateBody => 'Only you can play it';
  @override
  String get quizVisibilityFriends => 'Friends';
  @override
  String get quizVisibilityFriendsBody => 'Anyone on your friends list';
  @override
  String get quizVisibilityLink => 'Anyone with the code';
  @override
  String get quizVisibilityLinkBody => 'Share the code and they are in';
  @override
  String quizStatLine(int questions, int plays) =>
      '${questionsCount(questions)} · ${plays == 1 ? '1 play' : '$plays plays'}';
  @override
  String quizByAuthor(String name) => 'by $name';
  @override
  String get quizNoPlaysYet => 'No plays yet';

  @override
  String get editorNewTitle => 'New quiz';
  @override
  String get editorEditTitle => 'Edit quiz';
  @override
  String get editorTitleLabel => 'Title';
  @override
  String get editorTitleHint => 'Bollywood in the 2000s';
  @override
  String get editorDescriptionLabel => 'Description';
  @override
  String get editorDescriptionHint => 'What is this quiz about? (optional)';
  @override
  String get editorIconLabel => 'Icon';
  @override
  String get editorVisibilityLabel => 'Who can play it';
  @override
  String get editorDefaultsLabel => 'Suggested setup';
  @override
  String get editorDefaultsSubtitle =>
      'What players start on. They can still change it.';
  @override
  String get editorQuestionsLabel => 'Questions';
  @override
  String editorQuestionsCounter(int used, int max) => '$used / $max';
  @override
  String get editorAddQuestion => 'Add a question';
  @override
  String get editorAiDraft => 'Draft with AI';
  @override
  String get editorNoQuestionsTitle => 'No questions yet';
  @override
  String get editorNoQuestionsBody =>
      'Write one yourself, or let the AI draft a few and edit them.';
  @override
  String get editorPublish => 'Publish';
  @override
  String get editorPublished => 'Your quiz is live.';
  @override
  String get editorUnpublish => 'Back to draft';
  @override
  String get editorUnpublished => 'Back to draft. Nobody can start it now.';
  @override
  String get editorArchive => 'Archive';
  @override
  String get editorArchived => 'Archived. Scores are kept.';
  @override
  String get editorRestore => 'Restore';
  @override
  String get editorDelete => 'Delete quiz';
  @override
  String get editorDeleteTitle => 'Delete this quiz?';
  @override
  String get editorDeleteBody =>
      'The quiz and its questions are gone for good. This cannot be undone.';
  @override
  String get editorSaveChanges => 'Save';
  @override
  String get editorSaved => 'Saved';
  @override
  String get editorNeedTitle => 'Give your quiz a title first.';
  @override
  String editorNeedQuestions(int minimum) =>
      'You need at least ${questionsCount(minimum)} to publish.';
  @override
  String get editorQuestionLimit =>
      'This quiz is full. Premium raises the limit.';
  @override
  String get editorQuizLimit =>
      'You have used all your quiz slots. Archive one, or go Premium.';
  @override
  String get editorDiscardTitle => 'Discard this quiz?';
  @override
  String get editorDiscardBody =>
      'It has no questions yet, so nothing will be kept.';
  @override
  String get editorKeepEditing => 'Keep editing';
  @override
  String get editorDiscard => 'Discard';
  @override
  String get editorReorderHint => 'Hold and drag to reorder';
  @override
  String get editorRetiredNote =>
      'Already played, so removing it keeps everyone’s scores intact.';
  @override
  String get editorHiddenNote =>
      'This quiz is locked while it is reviewed. You cannot edit it right now.';
  @override
  String get editorLanguageLocked =>
      'Questions are written in the language you picked when you created the quiz.';

  @override
  String get questionEditorNew => 'New question';
  @override
  String get questionEditorEdit => 'Edit question';
  @override
  String get questionPromptLabel => 'Question';
  @override
  String get questionPromptHint => 'Which film won Best Picture in 2004?';
  @override
  String get questionOptionsLabel => 'Answers';
  @override
  String get questionOptionsHint => 'Tap the circle to mark the right one';
  @override
  String questionOptionHint(int index) => 'Answer ${index + 1}';
  @override
  String get questionExplanationLabel => 'Explanation';
  @override
  String get questionExplanationHint => 'Shown after answering (optional)';
  @override
  String get questionDifficultyLabel => 'Difficulty';
  @override
  String get questionNeedPrompt => 'Write the question first.';
  @override
  String get questionNeedOptions => 'All four answers need text.';
  @override
  String get questionDuplicateOptions => 'Two answers are the same.';
  @override
  String get questionDeleteTitle => 'Remove this question?';
  @override
  String get questionDeleteBody =>
      'It stops appearing in new runs straight away.';
  @override
  String get questionMarkCorrect => 'Mark as the correct answer';
  @override
  String get questionCorrect => 'Correct';

  @override
  String get aiDraftTitle => 'Draft with AI';
  @override
  String get aiDraftBody =>
      'Say what the quiz is about and the AI writes a few starters. Everything is yours to edit before it is saved.';
  @override
  String get aiDraftHint => 'Bollywood films of the 2000s';
  @override
  String get aiDraftCount => 'How many';
  @override
  String get aiDraftGenerate => 'Draft questions';
  @override
  String get aiDraftWorking => 'Writing questions…';
  @override
  String aiDraftAddAll(int count) => 'Add all ${questionsCount(count)}';
  @override
  String aiDraftRemaining(int remaining) => remaining == 1
      ? '1 AI draft left today'
      : '$remaining AI drafts left today';
  @override
  String get aiDraftUnlimited => 'Unlimited AI drafts';
  @override
  String get aiDraftReviewNote => 'Check each one before you publish.';
  @override
  String get aiDraftNeedPrompt => 'Say what the quiz is about first.';

  @override
  String get quizPlaySolo => 'Play solo';
  @override
  String get quizChallengeFriend => 'Challenge a friend';
  @override
  String get quizOpenRoom => 'Open a room';
  @override
  String get quizShare => 'Share';
  @override
  String quizShareMessage(String title, String code) =>
      'Beat my score on “$title” — open SpeedQuiz and enter code $code';
  @override
  String get quizCodeCopied => 'Code copied';
  @override
  String get quizChooseMode => 'Choose a mode';
  @override
  String get quizLeaderboardTitle => 'This quiz’s board';
  @override
  String get quizLeaderboardSubtitle => 'Best run per player';
  @override
  String get quizLeaderboardEmpty => 'Nobody has played it yet. Go first.';
  @override
  String quizYourBest(String score) => 'Your best · $score';
  @override
  String get quizNotPlayedYet => 'You have not played this yet';
  @override
  String quizPlayersCount(int count) =>
      count == 1 ? '1 player' : '$count players';
  @override
  String get quizEdit => 'Edit';
  @override
  String get quizReport => 'Report';
  @override
  String get quizReportTitle => 'Report this quiz';
  @override
  String get quizReportOffensive => 'Offensive content';
  @override
  String get quizReportWrongAnswers => 'Wrong answers';
  @override
  String get quizReportSpam => 'Spam or nonsense';
  @override
  String get quizReportCopyright => 'Copied without permission';
  @override
  String get quizReportOther => 'Something else';
  @override
  String get quizReportSent => 'Thanks — we will take a look.';
  @override
  String get quizDraftNotice =>
      'This is a draft. Publish it to share or challenge with it.';

  @override
  String get resultsCustomQuiz => 'Custom quiz';
  @override
  String get resultsXpSuppressed =>
      'No XP — you already earned it from your own quiz today.';

  @override
  String quizError(String code) => switch (code) {
    'too_few_questions' => 'Add a few more questions before publishing.',
    'question_limit_exceeded' => editorQuestionLimit,
    'quiz_limit_reached' => editorQuizLimit,
    'duplicate_question' => 'This quiz already has that question.',
    'quiz_has_plays' =>
      'People have played this quiz — archive it instead of deleting it.',
    'quiz_not_found' => 'That quiz is no longer available.',
    'quiz_archived' => 'The author took this quiz down.',
    'quiz_archived_owner' => 'Restore this quiz before playing it again.',
    'quiz_not_published' => 'Publish this quiz before playing it.',
    'quiz_unavailable' => 'This quiz is unavailable while it is reviewed.',
    'quiz_under_review' => editorHiddenNote,
    'quiz_empty' => 'This quiz has no questions yet.',
    'quiz_too_short_to_challenge' =>
      'A challenge needs at least three questions.',
    'invalid_code' => studioCodeInvalid,
    'too_many_drafts' => 'Finish or delete one of your drafts first.',
    'ai_draft_limit' =>
      'You have used today’s AI drafts. Premium removes the limit.',
    'ai_draft_failed' => 'Could not draft questions. Try a clearer topic.',
    'cannot_report_own' => 'You cannot report your own quiz.',
    'custom_quizzes_disabled' => 'Quiz creation is unavailable right now.',
    'mode_unavailable' => 'That mode is no longer available.',
    _ => matchError(code),
  };
}
