import 'package:speedquiz/core/i18n/app_language.dart';

/// Every player-visible string in the app, as typed members.
///
/// Why an abstract class and not ARB + `gen_l10n`
/// ----------------------------------------------
/// A missing translation here is a **compile error**, not a silent fallback to
/// English at runtime. `flutter analyze` refuses to pass until every language
/// implements every string, which is the property that actually keeps a second
/// language from rotting three releases after it ships. It also keeps the build
/// free of a codegen step and generated files, and lets strings take real Dart
/// parameters (`int`, `Duration`) instead of stringly-typed placeholders.
///
/// The cost is that plural and gender rules are hand-written per language
/// rather than delegated to ICU. For two languages whose plural rules are the
/// same (one/other), that is a good trade. If a language with a richer plural
/// system is ever added, the affected members become methods that take the
/// count and each language decides — which is what [questionsCount] already
/// does.
///
/// Conventions
/// -----------
/// * Members are grouped by screen, in navigation order.
/// * Getters for fixed text, methods for anything interpolated.
/// * UPPERCASE in English is a *style* choice made by the widget, not baked
///   into the string — Devanagari has no case, so `toUpperCase()` on a Hindi
///   string is a no-op and button labels must read correctly without it.
abstract class SqStrings {
  const SqStrings();

  AppLanguage get language;

  // --- Common ------------------------------------------------------------
  String get appTagline;
  String get retry;
  String get cancel;
  String get close;
  String get ok;
  String get done;
  String get save;
  String get saving;
  String get loading;
  String get somethingWentWrong;
  String get tryAgain;
  String get all;
  String get search;
  String get comingSoon;
  String get today;
  String get points;
  String get level;
  String get levelShort;
  String get xp;
  String get coins;
  String get streak;
  String get bestStreak;
  String get accuracy;
  String get score;
  String get rank;
  String get you;
  String get player;

  /// "12 questions" — the noun agrees with [count].
  String questionsCount(int count);

  /// "3 topics".
  String topicsCount(int count);

  /// "1.2K questions" — the count is already formatted.
  String questionsCountCompact(String formatted);

  /// "5 days".
  String daysCount(int count);

  // --- Languages ---------------------------------------------------------
  String get appLanguageTitle;
  String get appLanguageSubtitle;
  String get quizLanguageTitle;
  String get quizLanguageSubtitle;
  String get quizLanguageHint;
  String languageChanged(String nativeName);

  /// "No Hindi questions for this topic yet" — the empty-bank case.
  String languageBankEmpty(String nativeName);
  String languageBankEmptyHint(String nativeName);

  // --- Errors ------------------------------------------------------------
  String get errorGeneric;
  String get errorTimeout;
  String get errorNoConnection;
  String get errorSessionExpired;
  String get errorTooManyRequests;
  String get errorNoQuestion;
  String get errorNoNextQuestion;
  String get errorUniqueCap;

  // --- Shell -------------------------------------------------------------
  String get tabHome;
  String get tabExplore;
  String get tabRanks;
  String get tabProfile;
  String get pressBackAgainToExit;

  // --- Home --------------------------------------------------------------
  String get greetingNight;
  String get greetingMorning;
  String get greetingAfternoon;
  String get greetingEvening;
  String greetingWithName(String greeting, String name);
  String get homeHeadline;
  String get homeReady;
  String get homeServerScored;
  String get homeStartARun;
  String get homeStartARunBody;
  String get homePlay;
  String get homeSurprise;
  String get homeOpenProfile;
  String get homeJumpBackIn;
  String get homeJumpBackInSubtitle;
  String get homeTopicsUnavailable;
  String get homeCouldNotLoadTopics;
  String get homeBankFilling;
  String get homeCustomTopic;
  String get homeCustomTopicBody;
  String get homeNoTopicReady;

  // --- Daily challenge ---------------------------------------------------
  String get dailyChallenge;
  String get dailyTapToRetry;
  String get dailyUnavailable;
  String get dailyTodayDone;
  String dailyTodayDoneWithScore(String score);
  String get dailyTodayDoneGeneric;
  String get dailyNice;
  String dailyCleared(String score);
  String get dailyClearedNoScore;
  String dailyResume(String topic);
  String dailySubtitle(String topic, int questions);

  // --- Quiz setup --------------------------------------------------------
  String get setupTitle;
  String get setupClose;
  String get setupModeCasual;
  String get setupModeCasualHook;
  String get setupModeSpeedrun;
  String get setupModeSpeedrunHook;
  String get setupModeSurvival;
  String get setupModeSurvivalHook;
  String get difficultyEasy;
  String get difficultyMedium;
  String get difficultyHard;
  String get difficultyExpert;
  String get difficultyAdaptive;
  String get setupSurpriseMe;
  String get setupCustomTopic;
  String setupSearchTopics(int count);
  String get setupPickATopic;
  String startWithTopic(String topic);
  String get setupPickTopicToStart;
  String get setupNoTopicReady;
  String setupRandomPicked(String topic);
  String setupTopicStillWriting(String topic);
  String get setupBankFilling;
  String get setupBankFillingBody;
  String get setupCreateCustomTopic;
  String setupNoTopicMatches(String query);
  String get setupNoTopicMatchesBody;
  String get setupCouldNotLoadTopics;
  String get setupComingSoonBody;
  String get setupUnavailableInLanguage;

  // --- Quiz play ---------------------------------------------------------
  String get playPreparing;
  String get playPreparingHint;
  String get playScoringRun;
  String get playGo;
  String get playSpeedrunTitle;
  String get playRuleRight;
  String get playRuleWrong;
  String get playRuleTighter;
  String get playEndRunTitle;
  String get playEndRunBody;
  String get playEndRunConfirm;
  String get playKeepPlaying;
  String get playEndRun;
  String get playRunInterrupted;
  String get playFreeLimitReached;
  String get playGoPremium;
  String get playPaywallReason;
  String get playBackHome;
  String get playLanguageUnavailableTitle;
  String questionNumber(int number);
  String get playRunClock;
  String overdriveMultiplier(int streak);
  String get playCorrect;
  String get playNotQuite;
  String get playWhy;
  String get playNext;
  String get playSeeResults;
  String get playTeachMe;
  String get playTeachMeThis;
  String get playTeaching;
  String get playTeachError;
  String get teachWhyCorrect;
  String get teachWhyWrong;
  String get teachKeyConcept;
  String get teachRemember;
  String livesLeft(int lives);

  // --- Results -----------------------------------------------------------
  String get resultsNewPersonalBest;
  String get resultsRunComplete;
  String personalBestValue(String score);
  String get resultsAvgAnswer;
  String get resultsSurvived;
  String get resultsQuestions;
  String get resultsUnlocked;
  String get resultsOneAchievement;
  String achievementsUnlockedCount(int count);
  String get resultsPlayAgain;
  String get resultsNewRun;
  String get resultsShare;
  String get resultsHome;
  String get resultsShareFailed;
  String levelUpTo(int level);
  String levelBadge(int level);
  String get resultsLoading;
  String get resultsUnavailable;
  String get resultsCouldNotLoad;
  String get resultsGoHome;
  String get resultsOpenSharedCard;

  // --- Explore -----------------------------------------------------------
  String get exploreTitle;
  String get exploreSearchHint;
  String get exploreNothingHere;
  String get exploreCategoryEmpty;
  String exploreNoMatch(String query);
  String get exploreTrendingNow;
  String get exploreBankFilling;
  String get exploreRandom;
  String get explorePlayRandom;
  String get exploreCouldNotLoad;
  String get exploreCheckConnection;
  String exploreReadyToPlay(int count);

  // --- Leaderboard -------------------------------------------------------
  String get leaderboardTitle;
  String get leaderboardSubtitle;
  String get leaderboardWeekly;
  String get leaderboardDaily;
  String get leaderboardCouldNotLoad;
  String get leaderboardUnreachable;
  String get leaderboardEmpty;
  String get leaderboardEmptyDaily;
  String get leaderboardEmptyWeekly;
  String yourBestIn(String period);

  // --- Profile -----------------------------------------------------------
  String get profileTitle;
  String get profileDetails;
  String get profileDetailsSubtitle;
  String get profileAchievements;
  String get profileAchievementsSubtitle;
  String achievementsProgress(int unlocked, int total);
  String get profileStatistics;
  String get profileStatisticsSubtitle;
  String get profilePremium;
  String get profileGoPremium;
  String get profilePremiumThanks;
  String get profilePremiumPitch;
  String get profileSettingsSubtitle;
  String get profileGuest;
  String get profileFree;
  String get profilePremiumBadge;
  String get profileGuestBadge;
  String get profileBack;

  // --- Profile edit ------------------------------------------------------
  String get editTitle;
  String get editSubtitle;
  String get editDisplayName;
  String get editDisplayNameSubtitle;
  String get editDisplayNameHint;
  String get editAvatar;
  String get editAvatarSubtitle;
  String get editPremiumAvatarReason;
  String get editSaveChanges;
  String get editSaved;
  String get editSaveFailed;
  String editNameTooShort(int minimum);

  // --- Account card ------------------------------------------------------
  String get accountTitle;
  String get accountGoogle;
  String get accountGuest;
  String get accountUsername;
  String get accountEmail;
  String get accountNotLinked;
  String get accountPlayingSince;
  String get accountOnThisDevice;
  String get accountPlayerId;
  String get accountCopyPlayerId;
  String get accountPlayerIdCopied;
  String get accountGuestHint;

  // --- Stats -------------------------------------------------------------
  String get statsTitle;
  String get statsSubtitle;
  String get statsUnavailable;
  String get statsCouldNotLoad;
  String get statsNoRuns;
  String get statsNoRunsBody;
  String get statsLifetimeAccuracy;
  String get statsRunsPlayed;
  String get statsBestScore;
  String get statsQuestions;
  String get statsMissed;
  String get statsTopicMastery;
  String get statsTopicMasterySubtitle;

  // --- Achievements ------------------------------------------------------
  String get achievementsTitle;
  String get achievementsSubtitle;
  String get achievementsUnavailable;
  String get achievementsCouldNotLoad;
  String get achievementsNoneYet;
  String get achievementsAllUnlocked;
  String get achievementsNoneYetBody;
  String get achievementsAllUnlockedBody;
  String get achievementsCompletionist;
  String get achievementsFilterAll;
  String get achievementsFilterUnlocked;
  String get achievementsFilterLocked;

  // --- Custom topic ------------------------------------------------------
  String get customTitle;
  String get customHeadline;
  String get customBody;
  String get customPromptHint;
  List<String> get customSuggestions;
  String get customDifficulty;
  String get customMode;
  String get customStyle;
  String get customStyleSubtitle;
  String get customStyleHint;
  String get customCreate;
  String get customNeedPrompt;
  String get customNotEnoughQuestions;
  String get customFailed;
  String get customBuilding;
  String get customBuildingHint;
  String get customStageUnderstanding;
  String get customStageWriting;
  String get customStageChecking;
  String get customStageShuffling;
  String customLanguageNote(String nativeName);

  // --- Landing / onboarding ----------------------------------------------
  String get landingTagline;
  String get landingWarmingUp;
  String get landingFeatureModesTitle;
  String get landingFeatureModesBody;
  String get landingFeatureDailyTitle;
  String get landingFeatureDailyBody;
  String get landingFeatureExplainTitle;
  String get landingFeatureExplainBody;
  String get landingPlayAsGuest;
  String get landingNewGuestRun;
  String get landingGuestNote;
  String get landingGoogleUnavailable;
  String get landingGoogleUnavailableBody;
  String get landingGoogleFailed;
  String get landingContinueWithGoogle;

  /// Replaces the tagline once a first-run player has given their name.
  String landingReadyName(String name);

  // --- First run ---------------------------------------------------------
  /// Semantics only — the progress bar itself carries no visible label.
  String onboardingStepOf(int step, int total);
  String get onboardingBack;
  String get onboardingLanguageTitle;
  String get onboardingLanguageBody;
  String get onboardingLanguageQuizNote;
  String get onboardingNameTitle;
  String get onboardingNameBody;
  String get onboardingNameHint;
  String get onboardingContinue;
  String get onboardingLetsGo;
  String get onboardingSkip;

  // --- Welcome sheet -----------------------------------------------------
  String get welcomeNewPlayer;
  String welcomeNewPlayerNamed(String name);
  String welcomeSignedIn(String name);
  String welcomeBack(String name);
  String get welcomeWaitingToday;
  String get welcomeStartPlaying;
  String get welcomeJumpBackIn;
  String get welcomeLookAround;
  String get welcomeGuestBody;
  String get welcomeAccountBody;
  String welcomeGuestHandle(String username);
  String get welcomeCuePickTopic;
  String get welcomeCueDailyDone;
  String welcomeCueResumeDaily(String topic);
  String welcomeCueDaily(String topic);

  // --- Shared result -----------------------------------------------------
  String get sharedRunBadge;
  String get sharedCardUnavailable;
  String get sharedCardExpired;
  String get sharedOpenSpeedQuiz;
  String get sharedBeatThat;
  String get sharedBeatThisScore;

  // --- Premium -----------------------------------------------------------
  String get premiumUnlockEverything;
  String get premiumYourePremium;
  String get premiumBenefitQuestionsTitle;
  String get premiumBenefitQuestionsBody;
  String get premiumBenefitCustomTitle;
  String get premiumBenefitCustomBody;
  String get premiumBenefitCosmeticsTitle;
  String get premiumBenefitCosmeticsBody;
  String get premiumUnlocked;
  String get premiumUnlockedTest;
  String get premiumVerifyReturnedFree;
  String get premiumEnabledStub;
  String get premiumEnabledDev;
  String get premiumNotAvailableHere;
  String get premiumRestored;
  String get premiumNoSubscription;
  String get premiumRestoredStub;
  String get premiumNothingToRestore;
  String get premiumRestoreUnavailable;
  String get premiumRestorePurchases;
  String get premiumSubscribe;
  String premiumSubscribeWithPrice(String price);
  String premiumSwitchTo(String plan);
  String get premiumTestPurchase;
  String premiumTestPurchaseWith(String plan);
  String get premiumEnableDev;
  String get premiumUnavailable;
  String get premiumTestModeNote;
  String get premiumSignInNote;
  String get premiumCurrent;
  String get premiumNotOnThisDevice;
  String premiumSavePercent(int percent);
  String get premiumRenewsAutomatically;
  String premiumRenewsAt(String price, String period);
  String premiumCancelAnytime(String store);

  // --- Subscription status -----------------------------------------------
  String get subPaymentFailed;
  String get subOnHold;
  String get subPaused;
  String get subPaymentProcessing;
  String get subCancelled;
  String get subEnded;
  String get subRefunded;
  String subActivePlan(String plan);
  String get subFixPaymentMethod;
  String get subManageSubscription;
  String get subCouldNotOpenStore;
  String get subUpdatePaymentNow;
  String subUpdatePaymentBy(String date);
  String get subOnHoldBody;
  String get subPausedBody;
  String subProcessingBody(String date);
  String get subCancelledBodyNoDate;
  String subCancelledBody(String date);
  String get subEndedBody;
  String get subRefundedBody;
  String get subThanks;
  String subIntroPriceUntil(String date);
  String subRenewsOn(String date);

  // --- Misc widgets ------------------------------------------------------
  String get hotBadge;
  String get confirm;
  String get gotIt;
  String get periodMonth;
  String get periodYear;
  String get streakActive;
  String get streakInactive;

  // --- Speed tiers (speedrun verdict flash) ------------------------------
  String get speedTierBlitz;
  String get speedTierFast;
  String get speedTierClean;
  String get speedTierClutch;

  // --- Billing progress --------------------------------------------------
  String get billingOpeningStore;
  String get billingRestoring;
  String get billingVerifying;
  String get billingCouldNotStart;
  String get billingPurchaseFailed;
  String get billingWaitingForPayment;
  String get billingStoreUnavailable;
  String get billingNoPlans;

  // --- Settings ----------------------------------------------------------
  String get settingsTitle;
  String get settingsAppearance;
  String get settingsAppearanceSubtitle;
  String get settingsThemeDark;
  String get settingsThemeLight;
  String get settingsThemeSystem;
  String get settingsLanguageSection;
  String get settingsLanguageSubtitle;
  String get settingsFeel;
  String get settingsFeelSubtitle;
  String get settingsSound;
  String get settingsSoundSubtitle;
  String get settingsMusic;
  String get settingsMusicSubtitle;
  String get settingsReminders;
  String get settingsRemindersSubtitle;
  String get settingsHaptics;
  String get settingsHapticsSubtitle;
  String get settingsAccount;
  String get settingsSaveProgress;
  String get settingsSaveProgressBody;
  String get settingsLinkGoogle;
  String get settingsGoogleUnavailable;
  String get settingsGoogleUnavailableBody;
  String get settingsAccountLinked;
  String get settingsAccountLinkFailed;
  String get settingsSignedInWithGoogle;
  String get settingsSignOut;
  String get settingsSigningOut;
  String get settingsSignOutTitle;
  String get settingsSignOutGuestBody;
  String get settingsSignOutBody;
  String get settingsSignOutConfirm;
  String get settingsStay;
  String get settingsDevEntitlements;
  String get settingsPremiumEnabled;
  String get settingsEnablePremium;
  String get settingsPremiumEnabledDev;
  String get settingsBackToFreeDev;
  String settingsVersion(String version);

  // --- Battle: hub -------------------------------------------------------
  String get battleTitle;
  String get battleTab;
  String get battleQuickMatch;
  String get battleQuickMatchSubtitle;
  String get battleChallengeFriend;
  String get battleChallengeFriendSubtitle;
  String get battlePrivateRoom;
  String get battlePrivateRoomSubtitle;
  String get battleJoinRoom;
  String get battleCopy;
  String get battleYourTurn;
  String get battleWaitingOnThem;
  String get battleActiveMatches;
  String get battleRecentMatches;
  String get battleNoMatches;
  String get battleNoMatchesBody;
  String get battleContinue;
  String get battlePlay;
  String get battleView;

  // --- Battle: lobby -----------------------------------------------------
  String get lobbyTitle;
  String get lobbyWaitingForOpponent;
  String get lobbyReady;
  String get lobbyNotReady;
  String get lobbyStartNow;
  String get lobbyWaitingForReady;
  String get lobbyRoomCode;
  String get lobbyShareCode;
  String get lobbyCodeCopied;
  String get lobbyEnterCode;
  String get lobbyJoin;
  String get lobbyInviteAccepted;
  String get lobbyChallengedYou;

  /// Title of the popup raised when a challenge lands while the app is open.
  String get lobbyChallengeTitle;
  String get lobbyAccept;
  String get lobbyDecline;
  String get lobbyDeclined;
  String lobbyPlayersReady(int ready, int total);
  String lobbySeats(int filled, int total);

  // --- Battle: play ------------------------------------------------------
  String battleRoundOf(int current, int total);
  String get battleYou;
  String get battleOpponent;
  String get battleWaitingForOthers;
  String get battleOpponentAnswered;
  String get battleOpponentThinking;
  String get battleOpponentFinishing;
  String get battleTimeUp;
  String get battleCorrect;
  String get battleWrong;
  String get battleReconnecting;

  // --- Match rules -------------------------------------------------------
  /// Combo tiers, by run length. Shouted on the verdict card.
  String get battleCombo;
  String get battleOnFire;
  String get battleUnstoppable;

  /// Banner over the last question of the board.
  String get battleFinalRound;
  String get battleDoublePoints;

  /// Awarded for answering a round correctly before the opponent.
  String get battleFirstBonus;

  /// Shown to the trailing player while the catch-up bonus is in play.
  String get battleCatchUp;

  /// Multiplier chip, e.g. "x2".
  String battleMultiplier(String value);
  String get battleOffline;

  /// The in-round abandon control, and the confirmation behind it.
  String get battleAbandonAction;
  String get battleAbandonTitle;
  String get battleAbandonBody;
  String get battleAbandonConfirm;
  String get battleAsyncNotice;

  // --- Battle: result ----------------------------------------------------
  String get resultWin;
  String get resultYou;
  String get resultVersus;
  String get battleHistoryTitle;
  String get battleHistorySeeAll;
  String get battleHistoryEmpty;
  String get battleHistoryEmptyBody;

  /// "7 / 10 correct" — the accuracy line under a match score.
  String battleCorrectOf(int correct, int total);
  String get resultLoss;
  String get resultDraw;
  String get resultWinBody;
  String get resultLossBody;
  String get resultDrawBody;

  /// Why the match ended, when it ended because somebody walked out. The
  /// scoreline alone cannot say it — a win by abandonment can look like a
  /// narrow win, or like a loss the winner was heading for.
  String get resultWinByAbandonBody;
  String get resultLossByAbandonBody;

  /// Badge on the standings row of whoever left.
  String get resultAbandoned;
  String get resultAwaitingOpponent;
  String get resultAwaitingOpponentBody;
  String get resultRematch;
  String get resultBackToBattle;
  String get resultNewTopic;
  String get resultHome;
  String get resultStandings;
  String resultRatingGained(int points);
  String resultRatingLost(int points);
  String resultPlacement(int place);

  // --- Ranked ------------------------------------------------------------
  String get rankedTitle;
  String get rankedSearching;
  String get rankedSearchingBody;
  String get rankedCancelSearch;
  String get rankedNoOpponent;
  String get rankedNoOpponentBody;
  String get rankedTryAgain;
  String get rankedPlacements;
  String get rankedUnranked;
  String get rankedSeason;
  String get rankedLadder;
  String get rankedYourRank;
  String get rankedNoRankYet;
  String rankedPlacementsRemaining(int count);
  String rankedNextTier(String tier, int points);
  String rankedSearchingFor(int seconds);
  String rankedPlayersSearching(int count);
  String rankedRecord(int wins, int losses, int draws);

  // --- Friends -----------------------------------------------------------
  String get friendsTitle;
  String get friendsTab;
  String get friendsRequestsTab;
  String get friendsAdd;
  String get friendsSearchHint;
  String get friendsSearchEmpty;
  String get friendsNoFriends;
  String get friendsNoFriendsBody;
  String get friendsNoRequests;
  String get friendsIncoming;
  String get friendsOutgoing;
  String get friendsAccept;
  String get friendsDecline;
  String get friendsCancelRequest;
  String get friendsRequestSent;
  String get friendsRequestPending;
  String get friendsAlreadyFriends;
  String get friendsChallenge;
  String get friendsRemove;
  String get friendsRemoveTitle;
  String get friendsRemoveConfirm;
  String get friendsBlock;
  String get friendsBlockTitle;
  String get friendsBlockBody;
  String get friendsBlocked;
  String get friendsUnblock;
  String get friendsBlockedList;
  String get friendsOnline;
  String get friendsYourCode;
  String get friendsShareCode;
  String get friendsCodeCopied;
  String get friendsCodeHint;
  String friendsRemoveBody(String name);
  String friendsHeadToHead(int wins, int losses);
  String friendsCount(int count);

  // --- Username ----------------------------------------------------------
  String get usernameTitle;
  String get usernameLabel;
  String get usernameHint;
  String get usernameAvailable;
  String get usernameChecking;
  String get usernameSave;
  String get usernameSaved;
  String get usernameSuggestions;
  String get usernameRules;
  String usernameLockedUntil(String date);

  /// Localized reason a username was refused, keyed by the server's
  /// `detail.code`. A method rather than a getter per code so an unknown code
  /// from a newer server degrades to generic advice instead of crashing.
  String usernameError(String code);

  // --- Notifications -----------------------------------------------------
  String get notificationsTitle;
  String get notificationsEmpty;
  String get notificationsEmptyBody;
  String get notificationsMarkRead;
  String get notificationsClear;
  String get notificationsClearTitle;
  String get notificationsClearBody;
  String get notificationsCleared;
  String get notificationsSettings;
  String get notificationsPushDisabled;
  String notificationFriendRequest(String name);
  String notificationFriendAccepted(String name);
  String notificationMatchInvite(String name, String topic);
  String notificationYourTurn(String name);
  String notificationMatchResult(String name);

  /// Bell semantics on Home, so a screen reader announces the count rather
  /// than "notifications, button" with a number drawn beside it.
  String notificationsUnread(int count);

  /// Headlines for the in-app banner. A challenge reuses `lobbyChallengeTitle`.
  String get notificationTitleFriendRequest;
  String get notificationTitleFriendAccepted;
  String get notificationTitleYourTurn;
  String get notificationTitleMatchResult;
  String get notificationTitleExpiring;
  String get notificationIgnore;

  // --- On-device reminders -----------------------------------------------
  //
  // Rendered by the OS, often with the app closed, so these are baked at
  // schedule time in whatever language the app was last set to.
  String get reminderDailyTitle;
  String get reminderDailyBody;
  String get reminderStreakTitle;
  String reminderStreakBody(int days);
  String get reminderComebackTitle;
  String get reminderComebackBody;
  String reminderComebackBodyTopic(String topic);

  // --- Shared errors -----------------------------------------------------
  String get errorNotFriends;
  String get errorMatchFull;
  String get errorMatchClosed;
  String get errorBankTooThin;
  String get errorAlreadyAnswered;
  String get errorRoundClosed;
  String get errorMultiplayerDisabled;
  String get errorNetwork;

  /// Maps a server `detail.code` to a sentence in the player's language.
  String matchError(String code);

  // --- Quiz studio (player-authored quizzes) -----------------------------
  String get studioTitle;
  String get studioHeadline;
  String get studioBody;
  String get studioMine;
  String get studioShared;
  String get studioSharedSubtitle;
  String get studioEmptyTitle;
  String get studioEmptyBody;
  String get studioCreate;
  String get studioNewQuiz;
  String get studioOpenWithCode;
  String get studioCodeHint;
  String get studioCodeInvalid;
  String get studioOpen;
  String get studioCouldNotLoad;

  /// "2 of 3 quiz slots left" — the free-tier allowance.
  String studioSlotsLeft(int remaining, int total);
  String get studioSlotsUnlimited;
  String get studioSlotsNone;
  String get studioSlotsNoneBody;

  // Home entry point
  String get homeMakeQuiz;
  String get homeMakeQuizBody;

  // Status and visibility
  String get quizStatusDraft;
  String get quizStatusPublished;
  String get quizStatusArchived;
  String get quizStatusHidden;
  String get quizVisibilityPrivate;
  String get quizVisibilityPrivateBody;
  String get quizVisibilityFriends;
  String get quizVisibilityFriendsBody;
  String get quizVisibilityLink;
  String get quizVisibilityLinkBody;

  /// "12 questions · 40 plays".
  String quizStatLine(int questions, int plays);
  String quizByAuthor(String name);
  String get quizNoPlaysYet;

  // Editor
  String get editorNewTitle;
  String get editorEditTitle;
  String get editorTitleLabel;
  String get editorTitleHint;
  String get editorDescriptionLabel;
  String get editorDescriptionHint;
  String get editorIconLabel;
  String get editorVisibilityLabel;
  String get editorDefaultsLabel;
  String get editorDefaultsSubtitle;
  String get editorQuestionsLabel;
  String editorQuestionsCounter(int used, int max);
  String get editorAddQuestion;
  String get editorAiDraft;
  String get editorNoQuestionsTitle;
  String get editorNoQuestionsBody;
  String get editorPublish;
  String get editorPublished;
  String get editorUnpublish;
  String get editorUnpublished;
  String get editorArchive;
  String get editorArchived;
  String get editorRestore;
  String get editorDelete;
  String get editorDeleteTitle;
  String get editorDeleteBody;
  String get editorSaveChanges;
  String get editorSaved;
  String get editorNeedTitle;
  String editorNeedQuestions(int minimum);
  String get editorQuestionLimit;
  String get editorQuizLimit;
  String get editorDiscardTitle;
  String get editorDiscardBody;
  String get editorKeepEditing;
  String get editorDiscard;
  String get editorReorderHint;
  String get editorRetiredNote;
  String get editorHiddenNote;
  String get editorLanguageLocked;

  // One question
  String get questionEditorNew;
  String get questionEditorEdit;
  String get questionPromptLabel;
  String get questionPromptHint;
  String get questionOptionsLabel;
  String get questionOptionsHint;
  String questionOptionHint(int index);
  String get questionExplanationLabel;
  String get questionExplanationHint;
  String get questionDifficultyLabel;
  String get questionNeedPrompt;
  String get questionNeedOptions;
  String get questionDuplicateOptions;
  String get questionDeleteTitle;
  String get questionDeleteBody;
  String get questionMarkCorrect;
  String get questionCorrect;

  // AI drafting
  String get aiDraftTitle;
  String get aiDraftBody;
  String get aiDraftHint;
  String get aiDraftCount;
  String get aiDraftGenerate;
  String get aiDraftWorking;
  String aiDraftAddAll(int count);
  String aiDraftRemaining(int remaining);
  String get aiDraftUnlimited;
  String get aiDraftReviewNote;
  String get aiDraftNeedPrompt;

  // Playing and sharing
  String get quizPlaySolo;
  String get quizChallengeFriend;
  String get quizOpenRoom;
  String get quizShare;
  String quizShareMessage(String title, String code);
  String get quizCodeCopied;
  String get quizChooseMode;
  String get quizLeaderboardTitle;
  String get quizLeaderboardSubtitle;
  String get quizLeaderboardEmpty;
  String quizYourBest(String score);
  String get quizNotPlayedYet;
  String quizPlayersCount(int count);
  String get quizEdit;
  String get quizReport;
  String get quizReportTitle;
  String get quizReportOffensive;
  String get quizReportWrongAnswers;
  String get quizReportSpam;
  String get quizReportCopyright;
  String get quizReportOther;
  String get quizReportSent;
  String get quizDraftNotice;

  // Results
  String get resultsCustomQuiz;
  String get resultsXpSuppressed;

  /// Maps a `custom-quizzes` error code to a sentence. Falls back to
  /// [matchError] so one table covers both features.
  String quizError(String code);
}
