# Languages

SpeedQuiz ships in **English** and **Hindi**, across two settings that are
deliberately independent.

| | App language | Quiz language |
|---|---|---|
| What it changes | Buttons, headers, toasts, errors — all chrome | The language questions, options and explanations are **written in** |
| Where it is set | Profile → Settings → Language | On the quiz setup screen, per run (default also in Settings) |
| Stored on the device | `settings_app_language` | `settings_quiz_language` |
| Stored on the account | `user_profiles.app_language` | `user_profiles.quiz_language` |
| Authoritative for a run | — | `quiz_sessions.language`, fixed at creation |

They are separate because the combinations are real: exam prep in Hindi chrome
over English questions is common, and so is the reverse for someone practising
their Hindi reading. Forcing one to follow the other would make the app worse
for both.

---

## 1. App language (client)

Everything lives in `mobile/lib/core/i18n/`.

```text
app_language.dart        AppLanguage enum: code, endonym, script
sq_strings.dart          abstract SqStrings — every player-visible string
sq_strings_en.dart       English (source of truth)
sq_strings_hi.dart       Hindi (Devanagari)
l10n.dart                delegate + `context.l10n` + `context.scriptExtraHeight`
language_providers.dart  persisted app/quiz language, profile sync
game_labels.dart         server enums (`speedrun`, `expert`, …) → words
widgets/language_picker.dart
```

### Why typed strings and not ARB + `gen_l10n`

A missing translation is a **compile error**. `flutter analyze` fails until
every language implements every member of `SqStrings`, which is the property
that stops a second language rotting three releases after it ships. It also
avoids a codegen step and lets strings take real Dart parameters.

The trade: plural rules are hand-written per language rather than delegated to
ICU. English and Hindi share the same one/other rule, so members like
`questionsCount(int)` are a two-branch method. A language with a richer plural
system would implement that method differently — no call site changes.

### Adding a language

1. Add a value to `AppLanguage` (code, English name, endonym, script).
2. Add a `SqStrings` implementation. The analyzer lists every string you owe.
3. Add it to `stringsFor()` in `l10n.dart`.
4. Add it to `ContentLanguage` in `backend/app/core/languages.py`, with a
   generation directive.
5. Add its names to `CATEGORY_NAMES_HI`-style maps in
   `backend/app/services/seed.py`; `test_languages.py` asserts full coverage.

Nothing else switches on the language.

### Script handling

Space Grotesk and DM Sans are Latin-only, so **every Devanagari glyph** comes
from a fallback face. `AppTheme` therefore:

- lists system Devanagari fonts in `fontFamilyFallback` (Noto Sans Devanagari
  on Android, Kohinoor on iOS — no bundled asset, no APK cost);
- drops the negative letter-spacing display faces use, which otherwise pulls
  matras into their consonants;
- raises line height, because matras and conjuncts extend past the Latin
  ascender/descender box.

Anything with a **hard-coded height** containing text must add
`context.scriptExtraHeight`. `screens_smoke_test.dart` renders every major
screen in Hindi and fails on overflow — that is how the mode carousel, the
category rail and the Explore grid were caught.

---

## 2. Quiz language (content)

The bank is stored per language; nothing is translated at read time, because
gameplay never calls an LLM.

```text
questions.language          what a row is written in
quiz_sessions.language      fixed for the whole run
custom_topics.language      also part of the reuse cache key
generation_jobs.language    which bank a job fills
topics.name_i18n            curated catalog names (JSONB)
```

`ix_questions_topic_language_status` covers the dealing query's exact prefix:
topic → language → status → difficulty.

### Selection

`quiz_service._select_questions` filters on language at **every** phase,
including the pass that widens across difficulty. Widening difficulty makes a
run easier or harder; widening language would make it unreadable.

If a topic has nothing in the requested language the API returns
`409 {"code": "content_language_unavailable", "language": "hi"}`. The client
shows a localized message and routes back to setup — deliberately *not* the
generic "topic still filling" copy, which would be misleading for a topic that
is fully stocked in another language.

### Stock and generation

Inventory is per language throughout `bank_inventory.py`: counts, watermarks,
the in-flight-job check and the Redis lock key. A topic sitting on 900 English
questions and 4 Hindi ones is empty for a Hindi player, and the periodic sweep
queues work for it. `/topics` returns `question_counts` per language so the
client can grey out what it cannot deal.

Generation prompts carry an explicit directive (`app/core/languages.py`).
"Write in Hindi" alone gets romanised Hinglish back from most models, so the
directive names the script, forbids transliteration, and pins numerals to
Western Arabic digits.

### Two bugs this design had to fix

- **Unicode fingerprints.** Near-duplicate detection hashed `[a-z0-9]+`
  tokens. No Devanagari character matched, so every Hindi prompt hashed the
  empty string and the second Hindi question ever generated for a topic was
  rejected as a duplicate. `fingerprint()` now uses Unicode `\w`, and the
  check is scoped per (topic, language).
- **Cross-language hash collisions.** `content_hash` includes the language, so
  strings that are identical in both ("NATO?", a bare formula) can exist in
  both banks.

### Deliberate scope limits

- **Daily challenge** is pinned to the default language. It is one shared set
  feeding one shared leaderboard; a per-language daily would need a
  per-language board to stay a fair comparison.
- **Free unique-question caps** count per topic across languages, not per
  (topic, language) — switching language is not a way to reset the cap.
- **Custom topic names** are whatever the model returned, in the language it
  was asked for. They are not translated afterwards.
- **Avatar names** (Spark, Nova, …) are proper names and stay as-is, like
  character names in any game.
- **Store-authored text** — plan titles, decline reasons, product prices — is
  shown exactly as the store sent it. `BillingNotice` marks the copy the app
  owns so only that gets translated.

---

## 3. Seeded content

`seed.py` ships Hindi names for all 8 categories and all 45 topics, and
`refresh_catalog_translations()` re-applies them on every boot so a database
seeded before a language existed picks it up on the next deploy.

`question_bank.py` ships a small curated Hindi bank (30 questions across
General Knowledge, Indian History, Geography, Science and Cricket) so Hindi is
playable the moment the app ships rather than after the first generation
sweep. It then grows through the normal inventory path.

Re-seeding stays idempotent: the seed hash omits the default language, so
existing English rows keep the hashes they were written with.

---

## 4. Migration

`0005_content_languages` adds every column with `server_default 'en'`, so
existing rows backfill without a data migration and clients that never send a
language behave exactly as before. It replaces
`ix_questions_topic_difficulty_status` with the language-leading index rather
than adding a second one — after this migration every read of the bank is
language-scoped, so the old index would only cost write throughput.

```bash
cd backend && alembic upgrade head
```

---

## 5. Tests

| What | Where |
|---|---|
| Parsing, fallbacks, persistence, picker, locale switching | `mobile/test/i18n_test.dart` |
| Every major screen rendered in Hindi, overflow-checked | `mobile/test/screens_smoke_test.dart` |
| Normalization, Unicode dedupe, prompts, cache keys, share copy, catalog parity | `backend/tests/test_languages.py` |

Two guards worth keeping: `test_seeded_catalog_is_fully_translated` fails if a
topic is added without a Hindi name, and the Devanagari assertion in
`i18n_test.dart` fails if a Hindi string is left in English.
