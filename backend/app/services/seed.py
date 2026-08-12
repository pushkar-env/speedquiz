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
        existing = await db.scalar(select(TopicCategory.id).limit(1))
        if not existing:
            category_map: dict[str, TopicCategory] = {}
            for slug, name, icon, order in CATEGORIES:
                cat = TopicCategory(slug=slug, name=name, icon=icon, sort_order=order)
                db.add(cat)
                category_map[slug] = cat
            await db.flush()

            for slug, name, category_slug, icon, trending in TOPICS:
                db.add(
                    Topic(
                        slug=slug,
                        name=name,
                        category_id=category_map[category_slug].id,
                        icon=icon,
                        is_trending=trending,
                        popularity_score=100 if trending else 50,
                        description=f"Challenge yourself with {name} quizzes.",
                    )
                )

        created = await upsert_achievements(db)
        logger.info(
            "seed_complete",
            topics=len(TOPICS),
            achievements=len(ACHIEVEMENTS),
            achievements_created=created,
        )
