"""Reference data seeding for topics, categories, and achievements."""

from sqlalchemy import select

from app.core.database import session_scope
from app.core.logging import get_logger
from app.models import Achievement, Topic, TopicCategory

logger = get_logger(__name__)

CATEGORIES = [
    ("science", "Science", "🔬", 10),
    ("technology", "Technology", "💻", 20),
    ("history", "History", "📜", 30),
    ("entertainment", "Entertainment", "🎬", 40),
    ("gaming", "Gaming", "🎮", 50),
    ("sports", "Sports", "🏆", 60),
    ("lifestyle", "Lifestyle", "🌱", 70),
    ("academic", "Academic", "📚", 80),
]

#: (slug, name, category, icon, trending)
#:
#: Kept roughly balanced across categories — a picker where Science has six
#: entries and Sports has one looks unfinished, and thin categories are the
#: first thing a player notices when browsing.
#:
#: New rows start with an empty bank and are therefore not offered until the
#: worker's inventory sweep fills them past the low watermark. Adding a topic
#: here schedules generation; it does not make it playable immediately.
TOPICS = [
    # --- Science ---
    ("science", "Science", "science", "🧠", True),
    ("physics", "Physics", "science", "⚛️", False),
    ("chemistry", "Chemistry", "science", "🧪", False),
    ("biology", "Biology", "science", "🧬", False),
    ("astronomy", "Astronomy", "science", "🌌", True),
    ("space-exploration", "Space Exploration", "science", "🚀", True),
    ("human-body", "Human Body", "science", "🫀", False),
    ("earth-and-climate", "Earth & Climate", "science", "🌋", False),
    # --- Technology ---
    ("artificial-intelligence", "Artificial Intelligence", "technology", "🤖", True),
    ("programming", "Programming", "technology", "💻", True),
    ("technology", "Technology", "technology", "🛠️", False),
    ("cybersecurity", "Cybersecurity", "technology", "🔐", False),
    ("internet-culture", "Internet Culture", "technology", "🌐", True),
    ("gadgets", "Gadgets", "technology", "📱", False),
    # --- History ---
    ("history", "History", "history", "🏛️", False),
    ("ancient-civilizations", "Ancient Civilizations", "history", "🏺", False),
    ("world-wars", "World Wars", "history", "⚔️", False),
    ("indian-history", "Indian History", "history", "🕌", True),
    ("inventions", "Inventions", "history", "💡", False),
    # --- Entertainment ---
    ("movies", "Movies", "entertainment", "🎥", False),
    ("literature", "Literature", "entertainment", "📖", False),
    ("music", "Music", "entertainment", "🎵", True),
    ("television", "Television", "entertainment", "📺", False),
    ("anime-and-manga", "Anime & Manga", "entertainment", "🌸", True),
    # --- Gaming ---
    ("gaming", "Gaming", "gaming", "🎮", True),
    ("esports", "Esports", "gaming", "🕹️", False),
    ("game-history", "Game History", "gaming", "👾", False),
    ("board-games", "Board Games", "gaming", "🎲", False),
    # --- Sports ---
    ("sports", "Sports", "sports", "⚽", False),
    ("cricket", "Cricket", "sports", "🏏", True),
    ("football", "Football", "sports", "🥅", False),
    ("olympics", "Olympics", "sports", "🥇", False),
    ("motorsport", "Motorsport", "sports", "🏎️", False),
    # --- Lifestyle ---
    ("finance", "Finance", "lifestyle", "💰", False),
    ("food-and-drink", "Food & Drink", "lifestyle", "🍜", True),
    ("travel", "Travel", "lifestyle", "✈️", False),
    ("health-and-fitness", "Health & Fitness", "lifestyle", "💪", False),
    # --- Academic ---
    ("mathematics", "Mathematics", "academic", "🔢", False),
    ("geography", "Geography", "academic", "🌍", True),
    ("psychology", "Psychology", "academic", "🧩", False),
    ("general-knowledge", "General Knowledge", "academic", "✨", True),
    ("philosophy", "Philosophy", "academic", "🤔", False),
    ("economics", "Economics", "academic", "📈", False),
    ("languages", "Languages", "academic", "🗣️", False),
    ("art-and-design", "Art & Design", "academic", "🎨", False),
]

#: Curated Hindi names, keyed by slug. Kept separate from the tuples above so
#: adding a language is a new dict, not a reshaped table — and so a slug with
#: no entry simply falls back to its English name instead of breaking the seed.
CATEGORY_NAMES_HI = {
    "science": "विज्ञान",
    "technology": "तकनीक",
    "history": "इतिहास",
    "entertainment": "मनोरंजन",
    "gaming": "गेमिंग",
    "sports": "खेल",
    "lifestyle": "जीवनशैली",
    "academic": "शैक्षणिक",
}

TOPIC_NAMES_HI = {
    # Science
    "science": "विज्ञान",
    "physics": "भौतिकी",
    "chemistry": "रसायन विज्ञान",
    "biology": "जीव विज्ञान",
    "astronomy": "खगोल विज्ञान",
    "space-exploration": "अंतरिक्ष अन्वेषण",
    "human-body": "मानव शरीर",
    "earth-and-climate": "पृथ्वी और जलवायु",
    # Technology
    "artificial-intelligence": "आर्टिफिशियल इंटेलिजेंस",
    "programming": "प्रोग्रामिंग",
    "technology": "तकनीक",
    "cybersecurity": "साइबर सुरक्षा",
    "internet-culture": "इंटरनेट संस्कृति",
    "gadgets": "गैजेट्स",
    # History
    "history": "इतिहास",
    "ancient-civilizations": "प्राचीन सभ्यताएँ",
    "world-wars": "विश्व युद्ध",
    "indian-history": "भारतीय इतिहास",
    "inventions": "आविष्कार",
    # Entertainment
    "movies": "फ़िल्में",
    "literature": "साहित्य",
    "music": "संगीत",
    "television": "टेलीविज़न",
    "anime-and-manga": "एनिमे और मंगा",
    # Gaming
    "gaming": "गेमिंग",
    "esports": "ई-स्पोर्ट्स",
    "game-history": "गेम इतिहास",
    "board-games": "बोर्ड गेम्स",
    # Sports
    "sports": "खेल",
    "cricket": "क्रिकेट",
    "football": "फ़ुटबॉल",
    "olympics": "ओलंपिक",
    "motorsport": "मोटरस्पोर्ट",
    # Lifestyle
    "finance": "वित्त",
    "food-and-drink": "खान-पान",
    "travel": "यात्रा",
    "health-and-fitness": "स्वास्थ्य और फिटनेस",
    # Academic
    "mathematics": "गणित",
    "geography": "भूगोल",
    "psychology": "मनोविज्ञान",
    "general-knowledge": "सामान्य ज्ञान",
    "philosophy": "दर्शनशास्त्र",
    "economics": "अर्थशास्त्र",
    "languages": "भाषाएँ",
    "art-and-design": "कला और डिज़ाइन",
}


def _topic_name_i18n(slug: str) -> dict[str, str]:
    hindi = TOPIC_NAMES_HI.get(slug)
    return {"hi": hindi} if hindi else {}


def _topic_description_i18n(slug: str) -> dict[str, str]:
    hindi = TOPIC_NAMES_HI.get(slug)
    return {"hi": f"{hindi} के सवालों से खुद को परखें।"} if hindi else {}


def _category_name_i18n(slug: str) -> dict[str, str]:
    hindi = CATEGORY_NAMES_HI.get(slug)
    return {"hi": hindi} if hindi else {}


ACHIEVEMENTS = [
    ("first_quiz", "First Quiz", "Complete your first quiz", "flag", "progress", {"type": "quizzes_completed", "value": 1}, 50, 10),
    ("correct_10", "10 Correct", "Answer 10 questions correctly", "check", "progress", {"type": "correct_answers", "value": 10}, 75, 15),
    ("correct_50", "50 Correct", "Answer 50 questions correctly", "check", "progress", {"type": "correct_answers", "value": 50}, 150, 30),
    ("correct_100", "100 Correct", "Answer 100 questions correctly", "check", "progress", {"type": "correct_answers", "value": 100}, 300, 60),
    ("streak_10", "10 Question Streak", "Get a streak of 10", "fire", "streak", {"type": "best_streak", "value": 10}, 100, 20),
    ("streak_25", "25 Question Streak", "Get a streak of 25", "fire", "streak", {"type": "best_streak", "value": 25}, 250, 50),
    ("lightning_fast", "Lightning Fast", "Answer in under 2 seconds", "bolt", "speed", {"type": "fast_answer_ms", "value": 2000}, 100, 20),
    ("brainiac", "Brainiac", "Reach level 10", "brain", "progress", {"type": "level", "value": 10}, 200, 40),
    ("quiz_addict", "Quiz Addict", "Complete 50 quizzes", "infinity", "progress", {"type": "quizzes_completed", "value": 50}, 400, 80),
    ("perfect_run", "Perfect Run", "Finish a run with 100% accuracy (min 10 Qs)", "star", "skill", {"type": "perfect_run", "value": 1}, 200, 40),
    ("first_daily", "First Daily Challenge", "Complete a daily challenge", "calendar", "daily", {"type": "daily_completed", "value": 1}, 100, 20),
    ("daily_7", "7 Day Streak", "Play 7 days in a row", "calendar", "daily", {"type": "daily_streak", "value": 7}, 200, 40),
    ("daily_30", "30 Day Streak", "Play 30 days in a row", "calendar", "daily", {"type": "daily_streak", "value": 30}, 500, 100),
    ("astronomy_master", "Astronomy Master", "Reach 90% mastery in Astronomy", "planet", "mastery", {"type": "topic_mastery", "topic": "astronomy", "value": 90}, 300, 60),
    ("math_master", "Math Master", "Reach 90% mastery in Mathematics", "sigma", "mastery", {"type": "topic_mastery", "topic": "mathematics", "value": 90}, 300, 60),
    ("ai_master", "AI Master", "Reach 90% mastery in Artificial Intelligence", "robot", "mastery", {"type": "topic_mastery", "topic": "artificial-intelligence", "value": 90}, 300, 60),
]


async def upsert_achievements(db) -> int:
    """Insert missing achievements / refresh criteria & rewards by code."""
    existing = {
        row.code: row
        for row in (
            await db.execute(select(Achievement))
        ).scalars().all()
    }
    created = 0
    for idx, row in enumerate(ACHIEVEMENTS):
        code, name, desc, icon, category, criteria, xp, coins = row
        ach = existing.get(code)
        if ach is None:
            db.add(
                Achievement(
                    code=code,
                    name=name,
                    description=desc,
                    icon=icon,
                    category=category,
                    criteria=criteria,
                    xp_reward=xp,
                    coins_reward=coins,
                    sort_order=idx * 10,
                )
            )
            created += 1
            continue
        ach.name = name
        ach.description = desc
        ach.icon = icon
        ach.category = category
        ach.criteria = criteria
        ach.xp_reward = xp
        ach.coins_reward = coins
        ach.sort_order = idx * 10
        ach.is_active = True
    return created


async def seed_reference_data() -> None:
    async with session_scope() as db:
        categories_added = await _upsert_categories(db)
        topics_added = await _upsert_topics(db)
        translated = await refresh_catalog_translations(db)
        created = await upsert_achievements(db)
        logger.info(
            "seed_complete",
            topics=len(TOPICS),
            categories_added=categories_added,
            topics_added=topics_added,
            achievements=len(ACHIEVEMENTS),
            achievements_created=created,
            translations_refreshed=translated,
        )


async def _upsert_categories(db) -> int:
    """Insert any category in [CATEGORIES] that the database does not have."""
    existing = {
        category.slug: category
        for category in (await db.execute(select(TopicCategory))).scalars().all()
    }
    added = 0
    for slug, name, icon, order in CATEGORIES:
        if slug in existing:
            continue
        db.add(
            TopicCategory(
                slug=slug,
                name=name,
                icon=icon,
                sort_order=order,
                name_i18n=_category_name_i18n(slug),
            )
        )
        added += 1
    if added:
        await db.flush()
    return added


async def _upsert_topics(db) -> int:
    """Insert any topic in [TOPICS] that the database does not have, by slug.

    Keyed on slug rather than "is the table empty?", which is what the first
    version of this checked. That version only ever seeded a brand-new
    database, so every topic added to [TOPICS] after the first boot was
    silently missing from any existing deployment — along with the curated
    questions that target it.

    Only *inserts*. Name, icon and trending on rows that already exist are left
    alone: those are live catalog state that an operator may have tuned, and
    overwriting them on every boot would undo that. Translations are the
    exception and are refreshed separately — see [refresh_catalog_translations].

    A new topic starts with an empty bank, so it is not offered for play until
    the inventory sweep fills it past the low watermark.
    """
    categories = {
        category.slug: category
        for category in (await db.execute(select(TopicCategory))).scalars().all()
    }
    existing = set(
        (await db.execute(select(Topic.slug))).scalars().all()
    )

    added = 0
    for slug, name, category_slug, icon, trending in TOPICS:
        if slug in existing:
            continue
        category = categories.get(category_slug)
        if category is None:
            # A topic pointing at a category that is not in CATEGORIES is a
            # typo in the seed table; skip it rather than orphan the row.
            logger.warning("seed_topic_unknown_category", topic=slug, category=category_slug)
            continue
        db.add(
            Topic(
                slug=slug,
                name=name,
                category_id=category.id,
                icon=icon,
                is_trending=trending,
                popularity_score=100 if trending else 50,
                description=f"Challenge yourself with {name} quizzes.",
                name_i18n=_topic_name_i18n(slug),
                description_i18n=_topic_description_i18n(slug),
            )
        )
        added += 1

    if added:
        await db.flush()
        logger.info("seed_topics_added", count=added)
    return added


async def refresh_catalog_translations(db) -> int:
    """Push curated translations onto existing rows, by slug.

    Runs on every boot, not just the first: translations are content that ships
    with a deploy, and a database seeded before a language existed would
    otherwise stay English forever. Only writes when the value actually
    changes, so a steady state costs one SELECT per table and no UPDATEs.
    """
    updated = 0

    for category in (await db.execute(select(TopicCategory))).scalars().all():
        names = _category_name_i18n(category.slug)
        if names and dict(category.name_i18n or {}) != names:
            category.name_i18n = names
            updated += 1

    for topic in (await db.execute(select(Topic))).scalars().all():
        if topic.is_custom:
            # A custom topic's name is already in the language it was
            # generated in; there is nothing curated to overwrite it with.
            continue
        names = _topic_name_i18n(topic.slug)
        descriptions = _topic_description_i18n(topic.slug)
        if names and dict(topic.name_i18n or {}) != names:
            topic.name_i18n = names
            updated += 1
        if descriptions and dict(topic.description_i18n or {}) != descriptions:
            topic.description_i18n = descriptions
            updated += 1

    return updated
